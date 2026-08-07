// ============================================================================
// p2p_tb.sv - differential testbench for the GPU-to-GPU transport engine.
//
// The host program (sw/p2p_host.c) writes the whole experiment out: the shared
// memory image the simulation starts from, the image it must end at after
// every launch, and a line per launch holding every timing-independent value
// the CSRs have to report. This replays that and compares.
//
//   pass 0  randomised wait states on all five AXI4-Lite memory channels,
//           randomised link backpressure, randomised credit-return delay
//   pass 1  full rate: no wait states, no gaps
//   pass 2  full rate but every launch forced to a single credit, so the
//           transmitter can never have more than one packet in flight
//
// All three passes must produce identical memory and identical counters. That
// is the actual claim being tested: what the link delivers is a function of
// the descriptor ring, not of how the bus, the wire or the flow-control loop
// happened to be scheduled. After each pass the *entire* memory image is
// compared word by word against the golden image, so a stray write anywhere -
// outside a destination region, past the end of a message, into the wrong
// completion slot - fails the run.
//
// The link is closed on itself: this engine's egress drives its own ingress
// and its credit returns drive its own transmitter, both through a registered
// stage with randomised delay. One instance therefore exercises segmentation,
// the wire, reassembly, commit, completion posting and flow control together.
//
// Afterwards come the directed tests: CAPS, the register-map checksum, an
// unmapped register, interrupt masking, write-1-to-clear, a read SLVERR on a
// work-queue fetch, a write SLVERR on a payload commit, and recovery.
// ============================================================================
`timescale 1ns/1ps
`include "p2p_defs.vh"
`include "p2p_const.vh"

module p2p_tb;

    localparam MTU     = `P2P_TB_MTU;
    localparam NQP     = `P2P_TB_QP;
    localparam BUFS    = `P2P_TB_BUFS;
    localparam NR      = `P2P_TB_NRUNS;
    localparam MEMW    = `P2P_TB_MEMW;
    localparam PEAK    = `P2P_TB_PEAK;
    localparam PEAKACC = `P2P_TB_PEAKACC;

    integer checks = 0, fails = 0;

    // ------------------------------------------------------------- clock
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    reg [63:0] cyc = 64'd0;
    always @(posedge clk) cyc <= cyc + 64'd1;

    // ------------------------------------------------------- control port
    reg  [11:0] cs_awaddr;  reg cs_awvalid;  wire cs_awready;
    reg  [31:0] cs_wdata;   reg [3:0] cs_wstrb; reg cs_wvalid; wire cs_wready;
    wire [1:0]  cs_bresp;   wire cs_bvalid;  reg cs_bready;
    reg  [11:0] cs_araddr;  reg cs_arvalid;  wire cs_arready;
    wire [31:0] cs_rdata;   wire [1:0] cs_rresp; wire cs_rvalid; reg cs_rready;

    // ------------------------------------------------------- memory port
    wire [31:0] m_araddr, m_awaddr, m_wdata;
    wire [3:0]  m_wstrb;
    wire        m_arvalid, m_rready, m_awvalid, m_wvalid, m_bready;
    reg         m_arready, m_rvalid, m_awready, m_wready, m_bvalid;
    reg  [31:0] m_rdata;
    reg  [1:0]  m_rresp, m_bresp;

    // ------------------------------------------------------------- link
    wire        tx_tvalid, tx_tlast, tx_tuser;
    wire [31:0] tx_tdata;
    wire        tx_tready;
    wire        rx_tvalid, rx_tlast, rx_tuser;
    wire [31:0] rx_tdata;
    wire        rx_tready;
    wire        cro_valid, cro_ready;
    wire [3:0]  cro_qp;
    wire        cri_valid;
    wire [3:0]  cri_qp;
    wire        irq;

    p2p_top #(.MTU_WORDS(MTU), .NUM_QP(NQP), .RX_BUFS(BUFS),
              .MAX_MSG_WORDS(`P2P_TB_MAXMSG)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(cs_awaddr), .s_awvalid(cs_awvalid), .s_awready(cs_awready),
        .s_wdata(cs_wdata), .s_wstrb(cs_wstrb), .s_wvalid(cs_wvalid),
        .s_wready(cs_wready), .s_bresp(cs_bresp), .s_bvalid(cs_bvalid),
        .s_bready(cs_bready),
        .s_araddr(cs_araddr), .s_arvalid(cs_arvalid), .s_arready(cs_arready),
        .s_rdata(cs_rdata), .s_rresp(cs_rresp), .s_rvalid(cs_rvalid),
        .s_rready(cs_rready),
        .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid),
        .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready),
        .tx_tvalid(tx_tvalid), .tx_tdata(tx_tdata), .tx_tlast(tx_tlast),
        .tx_tuser(tx_tuser), .tx_tready(tx_tready),
        .rx_tvalid(rx_tvalid), .rx_tdata(rx_tdata), .rx_tlast(rx_tlast),
        .rx_tuser(rx_tuser), .rx_tready(rx_tready),
        .cro_valid(cro_valid), .cro_qp(cro_qp), .cro_ready(cro_ready),
        .cri_valid(cri_valid), .cri_qp(cri_qp),
        .irq(irq)
    );

    // ==================================================== link loopback
    // One registered stage, so a beat costs a cycle on the wire, plus an
    // optional randomised gap that models a slower peer.
    reg        lk_v;
    reg [31:0] lk_d;
    reg        lk_l, lk_u;
    reg        lk_gap = 1'b0;
    reg        rnd_en = 1'b1;

    integer link_beats = 0;

    assign rx_tvalid = lk_v && !lk_gap;
    assign rx_tdata  = lk_d;
    assign rx_tlast  = lk_l;
    assign rx_tuser  = lk_u;
    assign tx_tready = !lk_v || (rx_tvalid && rx_tready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lk_v <= 1'b0; lk_gap <= 1'b0;
        end else begin
            lk_gap <= rnd_en ? (($random & 32'h3) == 32'h0) : 1'b0;
            if (rx_tvalid && rx_tready) lk_v <= 1'b0;
            if (tx_tvalid && tx_tready) begin
                lk_v <= 1'b1;
                lk_d <= tx_tdata;
                lk_l <= tx_tlast;
                lk_u <= tx_tuser;
                link_beats = link_beats + 1;
            end
        end
    end

    // ================================================= credit loopback
    reg       cq_v;
    reg [3:0] cq_qp;
    reg [3:0] cq_wait;

    assign cro_ready = !cq_v;
    assign cri_valid = cq_v && (cq_wait == 4'd0);
    assign cri_qp    = cq_qp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cq_v <= 1'b0; cq_wait <= 4'd0; cq_qp <= 4'd0;
        end else begin
            if (cri_valid)              cq_v    <= 1'b0;
            else if (cq_wait != 4'd0)   cq_wait <= cq_wait - 4'd1;
            if (cro_valid && cro_ready) begin
                cq_v    <= 1'b1;
                cq_qp   <= cro_qp;
                cq_wait <= rnd_en ? ($random & 4'h3) : 4'h0;
            end
        end
    end

    // ================================================ AXI4-Lite memory
    localparam SQ = 8, SQ_MAX = 4;

    reg [31:0] mem  [0:MEMW-1];
    reg [31:0] gold [0:MEMW-1];

    reg        ws_en  = 1'b1;
    reg        err_en = 1'b0;
    reg [31:0] err_lo = 32'hFFFF_FFFF, err_hi = 32'h0;
    integer    rd_beats = 0, wr_beats = 0, stall_cycles = 0, oob = 0;

    function [3:0] wsr;
        input dummy;
        begin wsr = ws_en ? ($random & 4'h7) : 4'h0; end
    endfunction

    function slverr_hit;
        input [31:0] a;
        begin slverr_hit = err_en && (a >= err_lo) && (a <= err_hi); end
    endfunction

    reg [31:0] rq_addr  [0:SQ-1];
    reg [31:0] awq_addr [0:SQ-1];
    reg [31:0] wq_data  [0:SQ-1];
    reg [2:0]  rq_wr, rq_rd, awq_wr, awq_rd, wq_wr, wq_rd;
    reg [3:0]  rq_cnt, awq_cnt, wq_cnt;
    reg [3:0]  arc, rc, awc, wc, bc;

    always @* begin
        m_arready = (rq_cnt  < SQ_MAX) && (arc == 4'd0);
        m_awready = (awq_cnt < SQ_MAX) && (awc == 4'd0);
        m_wready  = (wq_cnt  < SQ_MAX) && (wc  == 4'd0);
    end

    wire push_r  = m_arvalid && m_arready;
    wire pop_r   = (rq_cnt != 4'd0) && (!m_rvalid || m_rready) && (rc == 4'd0);
    wire push_aw = m_awvalid && m_awready;
    wire push_w  = m_wvalid  && m_wready;
    wire do_wr   = (awq_cnt != 4'd0) && (wq_cnt != 4'd0) &&
                   (!m_bvalid || m_bready) && (bc == 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_rvalid <= 1'b0; m_bvalid <= 1'b0;
            m_rresp <= 2'b00; m_bresp <= 2'b00; m_rdata <= 32'd0;
            rq_wr <= 0; rq_rd <= 0; rq_cnt <= 0;
            awq_wr <= 0; awq_rd <= 0; awq_cnt <= 0;
            wq_wr <= 0; wq_rd <= 0; wq_cnt <= 0;
            arc <= 0; rc <= 0; awc <= 0; wc <= 0; bc <= 0;
        end else begin
            // ---- AR ------------------------------------------------------
            if (push_r) begin
                rq_addr[rq_wr] <= m_araddr;
                rq_wr <= rq_wr + 3'd1;
                if (m_araddr[31:2] >= MEMW) oob = oob + 1;
                arc <= wsr(0);
            end else if (m_arvalid && arc != 4'd0) begin
                arc <= arc - 4'd1;
                stall_cycles = stall_cycles + 1;
            end

            // ---- R -------------------------------------------------------
            if (pop_r) begin
                m_rvalid <= 1'b1;
                m_rdata  <= (rq_addr[rq_rd][31:2] < MEMW)
                              ? mem[rq_addr[rq_rd][31:2]] : 32'hDEAD_BEEF;
                m_rresp  <= slverr_hit(rq_addr[rq_rd]) ? 2'b10 : 2'b00;
                rq_rd    <= rq_rd + 3'd1;
                rc       <= wsr(1);
                rd_beats  = rd_beats + 1;
            end else if (m_rvalid && m_rready) begin
                m_rvalid <= 1'b0;
            end else if (rq_cnt != 4'd0 && rc != 4'd0) begin
                rc <= rc - 4'd1;
                stall_cycles = stall_cycles + 1;
            end

            // ---- AW / W --------------------------------------------------
            if (push_aw) begin
                awq_addr[awq_wr] <= m_awaddr;
                awq_wr <= awq_wr + 3'd1;
                if (m_awaddr[31:2] >= MEMW) oob = oob + 1;
                awc <= wsr(2);
            end else if (m_awvalid && awc != 4'd0) begin
                awc <= awc - 4'd1;
                stall_cycles = stall_cycles + 1;
            end

            if (push_w) begin
                wq_data[wq_wr] <= m_wdata;
                wq_wr <= wq_wr + 3'd1;
                wc <= wsr(3);
            end else if (m_wvalid && wc != 4'd0) begin
                wc <= wc - 4'd1;
                stall_cycles = stall_cycles + 1;
            end

            // ---- commit + B ----------------------------------------------
            if (do_wr) begin
                if (!slverr_hit(awq_addr[awq_rd]) &&
                    (awq_addr[awq_rd][31:2] < MEMW))
                    mem[awq_addr[awq_rd][31:2]] <= wq_data[wq_rd];
                m_bvalid <= 1'b1;
                m_bresp  <= slverr_hit(awq_addr[awq_rd]) ? 2'b10 : 2'b00;
                awq_rd   <= awq_rd + 3'd1;
                wq_rd    <= wq_rd + 3'd1;
                bc       <= wsr(4);
                wr_beats  = wr_beats + 1;
            end else if (m_bvalid && m_bready) begin
                m_bvalid <= 1'b0;
            end else if (awq_cnt != 4'd0 && wq_cnt != 4'd0 && bc != 4'd0) begin
                bc <= bc - 4'd1;
                stall_cycles = stall_cycles + 1;
            end

            // ---- occupancy ------------------------------------------------
            case ({push_r, pop_r})
                2'b10: rq_cnt <= rq_cnt + 4'd1;
                2'b01: rq_cnt <= rq_cnt - 4'd1;
                default: ;
            endcase
            case ({push_aw, do_wr})
                2'b10: awq_cnt <= awq_cnt + 4'd1;
                2'b01: awq_cnt <= awq_cnt - 4'd1;
                default: ;
            endcase
            case ({push_w, do_wr})
                2'b10: wq_cnt <= wq_cnt + 4'd1;
                2'b01: wq_cnt <= wq_cnt - 4'd1;
                default: ;
            endcase
        end
    end

    // ==================================================== CSR master tasks
    // AW and W are accepted on the same clock by construction (the slave gates
    // both on the same "no write in flight" condition), so one wait covers it.
    task csr_write(input [11:0] a, input [31:0] d);
        begin
            @(posedge clk);
            cs_awaddr <= a; cs_awvalid <= 1'b1;
            cs_wdata  <= d; cs_wvalid  <= 1'b1; cs_wstrb <= 4'hF;
            cs_bready <= 1'b1;
            @(posedge clk);
            while (!(cs_awready && cs_wready)) @(posedge clk);
            cs_awvalid <= 1'b0;
            cs_wvalid  <= 1'b0;
            while (!cs_bvalid) @(posedge clk);
            @(posedge clk);
            cs_bready <= 1'b0;
        end
    endtask

    task csr_read(input [11:0] a, output [31:0] d);
        begin
            @(posedge clk);
            cs_araddr <= a; cs_arvalid <= 1'b1; cs_rready <= 1'b1;
            @(posedge clk);
            while (!cs_arready) @(posedge clk);
            cs_arvalid <= 1'b0;
            while (!cs_rvalid) @(posedge clk);
            d = cs_rdata;
            @(posedge clk);
            cs_rready <= 1'b0;
        end
    endtask

    task expect_eq(input [8*48-1:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                if (fails < 40)
                    $display("MISMATCH %0s: got %0d (0x%08x) want %0d (0x%08x)",
                             what, got, got, want, want);
            end
        end
    endtask

    // ======================================================= run vectors
    reg [8*20-1:0] rname [0:NR-1];
    integer wqb [0:NR-1], wqc [0:NR-1], cqb [0:NR-1], mlim [0:NR-1];
    integer clim [0:NR-1], inj [0:NR-1];
    integer g_wqe[0:NR-1], g_pkt[0:NR-1], g_txw[0:NR-1], g_rxw[0:NR-1];
    integer g_cqe[0:NR-1], g_err[0:NR-1], g_seq[0:NR-1];
    integer g_ecode[0:NR-1], g_eidx[0:NR-1], g_serr[0:NR-1];

    integer fd, i, r, p, sc;
    reg [31:0] v, st;
    integer eng_cycles, peak_cycles, peakacc_cycles, lat_cycles;
    integer sum_cr, sum_lk, sum_mem;
    integer p0_cycles, p1_cycles, p2_cycles, p0_stall;
    integer t0, tpass;
    integer force_credit;
    integer cur_pass;
    integer p1_rd, p1_wr, p1_link;

    task load_runs;
        begin
            fd = $fopen("runs.txt", "r");
            if (fd == 0) begin $display("TEST FAILED: no runs.txt"); $finish; end
            for (i = 0; i < NR; i = i + 1) begin
                sc = $fscanf(fd,
                    "%s %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                    rname[i], wqb[i], wqc[i], cqb[i], mlim[i], clim[i], inj[i],
                    g_wqe[i], g_pkt[i], g_txw[i], g_rxw[i], g_cqe[i],
                    g_err[i], g_seq[i], g_ecode[i], g_eidx[i], g_serr[i]);
                if (sc != 17) begin
                    $display("TEST FAILED: runs.txt line %0d parsed %0d", i, sc);
                    $finish;
                end
            end
            $fclose(fd);
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            cs_awvalid = 0; cs_wvalid = 0; cs_bready = 0;
            cs_arvalid = 0; cs_rready = 0; cs_wstrb = 4'hF;
            cs_awaddr = 0; cs_araddr = 0; cs_wdata = 0;
            repeat (6) @(posedge clk);
            rst_n = 1'b1;
            repeat (3) @(posedge clk);
        end
    endtask

    // one launch: program the ring, ring the doorbell, wait, compare
    task do_run(input integer idx, input integer check_ctr);
        begin
            csr_write(`P2P_IRQ_STAT,  32'h3);
            csr_write(`P2P_WQ_BASE,   wqb[idx]);
            csr_write(`P2P_WQ_COUNT,  wqc[idx]);
            csr_write(`P2P_CQ_BASE,   cqb[idx]);
            csr_write(`P2P_MEM_LIMIT, mlim[idx]);
            csr_write(`P2P_CREDIT_LIM,
                      (force_credit != 0) ? force_credit : clim[idx]);
            csr_write(`P2P_INJECT,    inj[idx]);
            csr_write(`P2P_IRQ_EN,    32'h3);
            csr_write(`P2P_CTRL,      32'h1);

            t0 = 0;
            while (!irq) begin
                @(posedge clk);
                t0 = t0 + 1;
                if (t0 > 400000) begin
                    $display("TEST FAILED: run %0d (%0s) timed out",
                             idx, rname[idx]);
                    $finish;
                end
            end

            csr_read(`P2P_ST_CYCLES, v);
            if (cur_pass == 1) begin
                eng_cycles = eng_cycles + v;
                if (idx == PEAK)    peak_cycles    = v;
                if (idx == PEAKACC) peakacc_cycles = v;
                if (idx == 0)       lat_cycles     = v;
            end

            if (check_ctr) begin
                csr_read(`P2P_ST_WQE, v); expect_eq({rname[idx]," st_wqe"}, v, g_wqe[idx]);
                csr_read(`P2P_ST_PKT, v); expect_eq({rname[idx]," st_pkt"}, v, g_pkt[idx]);
                csr_read(`P2P_ST_TXW, v); expect_eq({rname[idx]," st_txw"}, v, g_txw[idx]);
                csr_read(`P2P_ST_RXW, v); expect_eq({rname[idx]," st_rxw"}, v, g_rxw[idx]);
                csr_read(`P2P_ST_CQE, v); expect_eq({rname[idx]," st_cqe"}, v, g_cqe[idx]);
                csr_read(`P2P_ST_ERR, v); expect_eq({rname[idx]," st_err"}, v, g_err[idx]);
                csr_read(`P2P_ST_SEQ, v); expect_eq({rname[idx]," st_seq"}, v, g_seq[idx]);
                csr_read(`P2P_ERR_CODE, v);
                expect_eq({rname[idx]," err_code"}, v, g_ecode[idx]);
                if (g_ecode[idx] != 0) begin
                    csr_read(`P2P_ERR_INFO, v);
                    expect_eq({rname[idx]," err_info"}, v, g_eidx[idx]);
                end
                csr_read(`P2P_STATUS, st);
                expect_eq({rname[idx]," status_err"},
                          {31'd0, st[2]}, g_serr[idx]);
                expect_eq({rname[idx]," status_busy"}, {31'd0, st[0]}, 32'd0);
            end

            csr_read(`P2P_ST_CRSTALL,  v);
            if (cur_pass == 1) sum_cr  = sum_cr  + v;
            csr_read(`P2P_ST_LKSTALL,  v);
            if (cur_pass == 1) sum_lk  = sum_lk  + v;
            csr_read(`P2P_ST_MEMSTALL, v);
            if (cur_pass == 1) sum_mem = sum_mem + v;

            csr_write(`P2P_IRQ_STAT, 32'h3);
            if (irq) begin
                checks = checks + 1;
                fails = fails + 1;
                $display("MISMATCH %0s: irq still asserted after W1C",
                         rname[idx]);
            end
        end
    endtask

    task sweep_memory(input integer pass);
        integer w, bad;
        begin
            bad = 0;
            for (w = 0; w < MEMW; w = w + 1) begin
                checks = checks + 1;
                if (mem[w] !== gold[w]) begin
                    fails = fails + 1;
                    bad = bad + 1;
                    if (bad < 10)
                        $display("MISMATCH pass %0d mem[%0d]: got %08x want %08x",
                                 pass, w, mem[w], gold[w]);
                end
            end
            $display("pass %0d memory sweep: %0d words, %0d wrong",
                     pass, MEMW, bad);
        end
    endtask

    // ============================================================== main
    integer regsum;
    integer dst0, src0;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("../../results/p2p.vcd");
            $dumpvars(0, p2p_tb);
        end

        load_runs();
        $readmemh("golden_mem.hex", gold);

        eng_cycles = 0; peak_cycles = 0; peakacc_cycles = 0; lat_cycles = 0;
        sum_cr = 0; sum_lk = 0; sum_mem = 0;

        for (p = 0; p < 3; p = p + 1) begin
            ws_en  = (p == 0);
            rnd_en = (p == 0);
            cur_pass = p;
            force_credit = (p == 2) ? 1 : 0;
            $readmemh("mem_init.hex", mem);
            do_reset();
            tpass = cyc;
            if (p == 0) p0_stall  = stall_cycles;
            if (p == 1) begin
                p1_rd = rd_beats; p1_wr = wr_beats; p1_link = link_beats;
            end
            for (r = 0; r < NR; r = r + 1) do_run(r, 1);
            if (p == 0) p0_cycles = cyc - tpass;
            if (p == 1) p1_cycles = cyc - tpass;
            if (p == 2) p2_cycles = cyc - tpass;
            if (p == 0) p0_stall  = stall_cycles - p0_stall;
            if (p == 1) begin
                p1_rd = rd_beats - p1_rd;
                p1_wr = wr_beats - p1_wr;
                p1_link = link_beats - p1_link;
            end
            sweep_memory(p);
        end
        cur_pass = 3;

        // ------------------------------------------------- directed tests
        ws_en = 1'b0; rnd_en = 1'b0; force_credit = 0;

        // CAPS
        csr_read(`P2P_CAPS, v);
        expect_eq("caps_mtu",  {24'd0, v[7:0]},   MTU);
        expect_eq("caps_qp",   {24'd0, v[15:8]},  NQP);
        expect_eq("caps_bufs", {24'd0, v[23:16]}, BUFS);

        // the register map the firmware header declares must be the one the
        // RTL implements
        regsum = `P2P_CTRL + `P2P_STATUS + `P2P_WQ_BASE + `P2P_WQ_COUNT +
                 `P2P_CQ_BASE + `P2P_MEM_LIMIT + `P2P_CREDIT_LIM +
                 `P2P_INJECT + `P2P_IRQ_EN + `P2P_IRQ_STAT + `P2P_ERR_CODE +
                 `P2P_ERR_INFO + `P2P_ST_WQE + `P2P_ST_PKT + `P2P_ST_TXW +
                 `P2P_ST_RXW + `P2P_ST_CQE + `P2P_ST_ERR + `P2P_ST_SEQ +
                 `P2P_ST_CYCLES + `P2P_ST_CRSTALL + `P2P_ST_LKSTALL +
                 `P2P_ST_MEMSTALL + `P2P_CAPS;
        expect_eq("regmap_checksum", regsum, `P2P_TB_REGSUM);

        // unmapped register reads as zero, and does not error
        csr_read(12'h0F0, v);
        expect_eq("unmapped_read", v, 32'd0);

        // CREDIT_LIM clamps zero to one
        csr_write(`P2P_CREDIT_LIM, 32'd0);
        csr_read(`P2P_CREDIT_LIM, v);
        expect_eq("credit_clamp", v, 32'd1);

        // write-1-to-clear, one bit at a time
        $readmemh("mem_init.hex", mem);
        do_reset();
        csr_write(`P2P_IRQ_EN, 32'h0);          // masked: irq must stay low
        csr_write(`P2P_WQ_BASE,   wqb[0]);
        csr_write(`P2P_WQ_COUNT,  wqc[0]);
        csr_write(`P2P_CQ_BASE,   cqb[0]);
        csr_write(`P2P_MEM_LIMIT, mlim[0]);
        csr_write(`P2P_CREDIT_LIM, clim[0]);
        csr_write(`P2P_INJECT, 32'd0);
        csr_write(`P2P_CTRL, 32'h1);
        repeat (400) @(posedge clk);
        expect_eq("irq_masked", {31'd0, irq}, 32'd0);
        csr_read(`P2P_IRQ_STAT, v);
        expect_eq("irq_stat_set_while_masked", v & 32'h1, 32'h1);
        csr_write(`P2P_IRQ_EN, 32'h1);
        repeat (2) @(posedge clk);
        expect_eq("irq_unmasked", {31'd0, irq}, 32'd1);
        csr_write(`P2P_IRQ_STAT, 32'h2);        // clear the wrong bit
        csr_read(`P2P_IRQ_STAT, v);
        expect_eq("w1c_wrong_bit", v & 32'h1, 32'h1);
        csr_write(`P2P_IRQ_STAT, 32'h1);
        csr_read(`P2P_IRQ_STAT, v);
        expect_eq("w1c_right_bit", v & 32'h1, 32'h0);

        // read SLVERR on a work-queue fetch
        $readmemh("mem_init.hex", mem);
        do_reset();
        err_en = 1'b1;
        err_lo = wqb[0];
        err_hi = wqb[0] + 31;
        csr_write(`P2P_IRQ_EN, 32'h3);
        csr_write(`P2P_WQ_BASE,   wqb[0]);
        csr_write(`P2P_WQ_COUNT,  wqc[0]);
        csr_write(`P2P_CQ_BASE,   cqb[0]);
        csr_write(`P2P_MEM_LIMIT, mlim[0]);
        csr_write(`P2P_CREDIT_LIM, clim[0]);
        csr_write(`P2P_CTRL, 32'h1);
        t0 = 0;
        while (!irq && t0 < 20000) begin @(posedge clk); t0 = t0 + 1; end
        expect_eq("rd_slverr_irq", {31'd0, irq}, 32'd1);
        csr_read(`P2P_ERR_CODE, v);
        expect_eq("rd_slverr_code", v, `P2P_ERR_BUS);
        csr_read(`P2P_STATUS, st);
        expect_eq("rd_slverr_status", {31'd0, st[2]}, 32'd1);
        csr_write(`P2P_IRQ_STAT, 32'h3);
        err_en = 1'b0;

        // write SLVERR on a payload commit
        $readmemh("mem_init.hex", mem);
        do_reset();
        src0 = mem[(wqb[0] >> 2) + 1];
        dst0 = mem[(wqb[0] >> 2) + 2];
        err_en = 1'b1;
        err_lo = dst0;
        err_hi = dst0 + 3;
        csr_write(`P2P_IRQ_EN, 32'h3);
        csr_write(`P2P_WQ_BASE,   wqb[0]);
        csr_write(`P2P_WQ_COUNT,  wqc[0]);
        csr_write(`P2P_CQ_BASE,   cqb[0]);
        csr_write(`P2P_MEM_LIMIT, mlim[0]);
        csr_write(`P2P_CREDIT_LIM, clim[0]);
        csr_write(`P2P_CTRL, 32'h1);
        t0 = 0;
        while (!irq && t0 < 20000) begin @(posedge clk); t0 = t0 + 1; end
        expect_eq("wr_slverr_irq", {31'd0, irq}, 32'd1);
        csr_read(`P2P_STATUS, st);
        expect_eq("wr_slverr_status", {31'd0, st[2]}, 32'd1);
        csr_write(`P2P_IRQ_STAT, 32'h3);
        err_en = 1'b0;

        // recovery: soft reset, rerun the same launch cleanly
        csr_write(`P2P_CTRL, 32'h2);
        repeat (4) @(posedge clk);
        $readmemh("mem_init.hex", mem);
        do_reset();
        do_run(0, 1);
        expect_eq("recovery_mem",
                  mem[dst0 >> 2], mem[src0 >> 2]);

        // ------------------------------------------------------- report
        $display("");
        $display("RESULT runs=%0d passes=3 checks=%0d fails=%0d",
                 NR, checks, fails);
        $display("METRIC mem_words %0d", MEMW);
        $display("METRIC engine_cycles_total %0d", eng_cycles);
        $display("METRIC pass0_cycles %0d", p0_cycles);
        $display("METRIC pass1_cycles %0d", p1_cycles);
        $display("METRIC pass2_cycles %0d", p2_cycles);
        $display("METRIC pass0_injected_stall %0d", p0_stall);
        $display("METRIC peak_cycles %0d", peak_cycles);
        $display("METRIC peak_words %0d", `P2P_TB_PEAKLEN);
        $display("METRIC peakacc_cycles %0d", peakacc_cycles);
        $display("METRIC peakacc_words %0d", `P2P_TB_PKACLEN);
        $display("METRIC latency_cycles %0d", lat_cycles);
        $display("METRIC link_beats %0d", p1_link);
        $display("METRIC rd_beats %0d", p1_rd);
        $display("METRIC wr_beats %0d", p1_wr);
        $display("METRIC credit_stall %0d", sum_cr);
        $display("METRIC link_stall %0d", sum_lk);
        $display("METRIC mem_stall %0d", sum_mem);
        $display("METRIC oob_accesses %0d", oob);
        $display("");
        if (fails == 0 && oob == 0) $display("TEST PASSED");
        else                        $display("TEST FAILED");
        $finish;
    end

endmodule
