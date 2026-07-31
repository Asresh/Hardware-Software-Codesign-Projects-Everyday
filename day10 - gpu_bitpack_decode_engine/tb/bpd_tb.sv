// ============================================================================
// bpd_tb.sv  -  differential testbench for the bit-pack decode engine
//
// Drives the AXI4-Lite control plane and streams the compressed ingress vectors
// through fully-clocked, race-free AXI-Stream master/slave engines: once under
// randomised ingress bubbles + egress backpressure, once at full rate. The wide
// decoded egress is unpacked and every value checked against the C golden model.
// A peak micro-benchmark then measures sustained decode throughput, and a
// malformed block confirms the error/IRQ path. Zero mismatches required.
//
// The stream handshake is evaluated at the clock edge (registered m_tready,
// continuous s_tvalid/s_tdata off registered indices), so the testbench and the
// DUT always agree on exactly which beats transfer.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module bpd_tb;
    localparam integer LANES  = 4;
    localparam integer DATA_W = 32;
`include "bpd_const.vh"

    // ---- clock / reset ----
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg [63:0] cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- AXI4-Lite ----
    reg  [7:0]  awaddr, araddr;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    // ---- AXI4-Stream ----
    wire [31:0] s_tdata;
    wire        s_tvalid, s_tlast;
    wire        s_tready;
    wire [LANES*DATA_W-1:0] m_tdata;
    wire [2:0]  m_tcnt;
    wire        m_tlast, m_tvalid;
    reg         m_tready = 0;
    wire        irq;

    bitpack_decode_engine #(.LANES(LANES), .DATA_W(DATA_W)) dut (
        .clk(clk), .rst(rst),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tcnt(m_tcnt), .m_axis_tlast(m_tlast),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .irq(irq)
    );

    // ---- vectors ----
    reg [31:0] ingress   [0:TB_NWORDS-1];
    reg [31:0] gold      [0:TB_NVALS-1];
    reg [31:0] blk_nwords[0:TB_NBLK-1];
    reg [31:0] blk_nvals [0:TB_NBLK-1];

    // peak micro-benchmark block (4096 values @ width 8, delta +1)
    localparam integer PK_N = 4096;
    localparam integer PK_W = 8;
    localparam integer PK_NW = 2 + (PK_N*PK_W)/32;
    reg [31:0] pk_words [0:PK_NW-1];
    reg [31:0] err_words[0:1];

    localparam [7:0] R_CTRL=8'h00, R_STAT=8'h04, R_BLOCKS=8'h08, R_VALUES=8'h0C,
                     R_CYCLES=8'h10, R_ERRCODE=8'h14, R_IRQACK=8'h18, R_ID=8'h1C;

    integer    errors = 0;
    reg [63:0] first_cyc, last_cyc;

    // ==================================================================
    // Ingress AXI-Stream master (clocked, race-free)
    //   mode 1 = main vectors, 2 = peak block, 3 = error block
    // ==================================================================
    reg        ig_en=0, ig_done=0, ig_gate=1, ig_rnd=0;
    reg  [1:0] ig_mode=0;
    integer    ib, ik, iwi;
    reg        in_started;
    reg [63:0] in_first_cyc;

    wire [31:0] cur_word = (ig_mode==2'd2) ? pk_words[iwi] :
                           (ig_mode==2'd3) ? err_words[iwi] : ingress[iwi];
    wire        cur_last = (ig_mode==2'd1) ? (ik == blk_nwords[ib]-1) :
                           (ig_mode==2'd2) ? (iwi == PK_NW-1) : (iwi == 1);
    wire        ig_active = ig_en & ~ig_done;

    assign s_tdata  = cur_word;
    assign s_tvalid = ig_active & ig_gate;
    assign s_tlast  = s_tvalid & cur_last;

    always @(posedge clk) begin
        if (rst | ~ig_en) begin
            ib<=0; ik<=0; iwi<=0; ig_done<=0; ig_gate<=1; in_started<=0;
        end else if (~ig_done) begin
            ig_gate <= ig_rnd ? (($urandom % 5) != 0) : 1'b1;
            if (s_tvalid & s_tready) begin
                if (!in_started) begin in_started<=1; in_first_cyc<=cyc; end
                iwi <= iwi + 1;
                if (cur_last) begin
                    if (ig_mode==2'd1 && ib < TB_NBLK-1) begin ib<=ib+1; ik<=0; end
                    else ig_done <= 1;
                end else if (ig_mode==2'd1) begin
                    ik <= ik + 1;
                end
            end
        end
    end

    // ==================================================================
    // Egress AXI-Stream slave (clocked, race-free)
    //   mode 1 = compare vs gold[], 2 = compare vs (index+1)
    // ==================================================================
    reg        eg_en=0, eg_done=0, eg_rnd=0;
    reg  [1:0] eg_mode=0;
    integer    gidx, got_beats, eg_nvals;

    always @(posedge clk) begin
        if (rst | ~eg_en) begin
            m_tready<=0; gidx<=0; eg_done<=0; got_beats<=0;
        end else if (~eg_done) begin
            if (m_tvalid & m_tready) begin : ACCEPT
                integer g, j; reg [31:0] v, exp;
                g = gidx;
                for (j=0; j<m_tcnt; j=j+1) begin
                    v   = m_tdata[j*DATA_W +: DATA_W];
                    exp = (eg_mode==2'd2) ? (g+1) : gold[g];
                    if (v !== exp) begin
                        errors = errors + 1;
                        if (errors <= 12)
                            $display("  MISMATCH val[%0d]: got %08x exp %08x", g, v, exp);
                    end
                    g = g + 1;
                end
                if (got_beats==0) first_cyc <= cyc;
                last_cyc  <= cyc;
                got_beats <= got_beats + 1;
                gidx <= g;
                if (g >= eg_nvals) eg_done <= 1;
            end
            m_tready <= eg_rnd ? (($urandom % 4) != 0) : 1'b1;
        end
    end

    // ==================================================================
    // AXI4-Lite tasks
    // ==================================================================
    task axil_write(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk);
            awaddr=a; awvalid=1; wdata=d; wstrb=4'hF; wvalid=1; bready=1;
            @(negedge clk);
            while (!bvalid) @(negedge clk);
            awvalid=0; wvalid=0;
            @(negedge clk);
            bready=0;
        end
    endtask

    task axil_read(input [7:0] a, output [31:0] d);
        begin
            @(negedge clk);
            araddr=a; arvalid=1; rready=1;
            @(negedge clk);
            arvalid=0;
            while (!rvalid) @(negedge clk);
            d = rdata;
            @(negedge clk);
        end
    endtask

    // ==================================================================
    // one full pass over the vector set
    // ==================================================================
    reg [31:0] hw_cycles, wall_cycles;
    task run_pass(input integer rnd);
        reg [31:0] blocks_r, values_r, cyc_r;
        begin
            axil_write(R_CTRL, 32'h4);      // SOFT_RST
            axil_write(R_CTRL, 32'h3);      // EN | IRQ_EN
            ig_mode=2'd1; eg_mode=2'd1; ig_rnd=rnd; eg_rnd=rnd; eg_nvals=TB_NVALS;
            @(negedge clk); eg_en=1; ig_en=1;
            wait (eg_done && ig_done);
            @(negedge clk); ig_en=0; eg_en=0;
            repeat (8) @(negedge clk);
            axil_read(R_BLOCKS, blocks_r);
            axil_read(R_VALUES, values_r);
            axil_read(R_CYCLES, cyc_r);
            $display("  pass %s: blocks=%0d values=%0d active_cycles=%0d  wall=%0d",
                     rnd ? "RANDOM" : "FULLRT", blocks_r, values_r, cyc_r,
                     (last_cyc-first_cyc+1));
            if (blocks_r !== TB_NBLK)  begin errors=errors+1; $display("  BLOCKS reg wrong"); end
            if (values_r !== TB_NVALS) begin errors=errors+1; $display("  VALUES reg wrong"); end
            hw_cycles   = cyc_r;
            wall_cycles = last_cyc - first_cyc + 1;
        end
    endtask

    task build_peak;
        integer i;
        begin
            pk_words[0] = 32'h0;                            // base = 0
            pk_words[1] = (PK_W << 26) | PK_N;             // {width,count}
            for (i=0;i<(PK_N*PK_W)/32;i=i+1)
                pk_words[2+i] = 32'h02020202;              // every residual = 2 (zz of +1)
        end
    endtask

    integer pk_latency;
    task run_peak(output integer pk_wall, output integer pk_hw);
        reg [31:0] c;
        begin
            axil_write(R_CTRL, 32'h4);
            axil_write(R_CTRL, 32'h3);
            ig_mode=2'd2; eg_mode=2'd2; ig_rnd=0; eg_rnd=0; eg_nvals=PK_N;
            @(negedge clk); eg_en=1; ig_en=1;
            wait (eg_done && ig_done);
            @(negedge clk); ig_en=0; eg_en=0;
            repeat (6) @(negedge clk);
            axil_read(R_CYCLES, c);         // isolated: CYCLES was soft-reset above
            pk_hw   = c;
            pk_wall = last_cyc - first_cyc + 1;
            pk_latency = first_cyc - in_first_cyc;  // first word in -> first beat out
        end
    endtask

    task run_errtest;
        reg [31:0] st, ec;
        begin
            axil_write(R_CTRL, 32'h4);
            axil_write(R_CTRL, 32'h3);
            err_words[0] = 32'hDEADBEEF;             // base
            err_words[1] = (32'd5 << 26) | 32'd0;    // width=5, count=0 -> error
            ig_mode=2'd3; eg_mode=2'd0; ig_rnd=0; eg_en=0;
            @(negedge clk); ig_en=1;
            wait (ig_done);
            @(negedge clk); ig_en=0;
            repeat (12) @(negedge clk);
            axil_read(R_STAT, st);
            axil_read(R_ERRCODE, ec);
            if (!(st & 32'h4)) begin errors=errors+1; $display("  ERR flag not set on malformed block"); end
            else $display("  error-injection: STATUS.ERR set, errcode=%0d (ok)", ec);
            axil_write(R_IRQACK, 32'h1);
            axil_write(R_CTRL, 32'h4);
        end
    endtask

    // ==================================================================
    integer pk_wall, pk_hw;
    real thr_full, thr_peak, spd_agg, spd_peak;
    integer base_full, base_peak;
    reg [31:0] idr;
    initial begin
        $readmemh("ingress.hex",    ingress);
        $readmemh("gold.hex",       gold);
        $readmemh("blk_nwords.hex", blk_nwords);
        $readmemh("blk_nvals.hex",  blk_nvals);
        build_peak;
        base_full = TB_BASELINE;

        repeat (4) @(negedge clk);
        rst = 0;
        repeat (2) @(negedge clk);

        axil_read(R_ID, idr);
        if (idr !== 32'hB17DEC10) begin errors=errors+1; $display("  ID mismatch: %08x", idr); end
        else $display("  ID = %08x (ok)", idr);

        $display("[bpd] pass 1: randomised ingress bubbles + egress backpressure");
        run_pass(1);
        $display("  errors after pass 1 = %0d", errors);
        $display("[bpd] pass 2: full rate");
        run_pass(0);
        $display("  errors after pass 2 = %0d", errors);

        $display("[bpd] peak micro-benchmark: %0d values @ width %0d", PK_N, PK_W);
        run_peak(pk_wall, pk_hw);
        $display("[bpd] error-injection test");
        run_errtest;

        base_peak = 6 + PK_N*10;   // C_HDR + count*(offset+load+shiftmask+zz+add+store+loop), no crossings @ w=8
        thr_full  = TB_NVALS * 1.0 / wall_cycles;
        thr_peak  = PK_N     * 1.0 / pk_wall;
        spd_agg   = base_full * 1.0 / hw_cycles;
        spd_peak  = base_peak * 1.0 / pk_hw;

        $display("==================================================");
        $display("METRIC total_blocks %0d", TB_NBLK);
        $display("METRIC total_values %0d", TB_NVALS);
        $display("METRIC total_words %0d", TB_NWORDS);
        $display("METRIC hw_active_cycles %0d", hw_cycles);
        $display("METRIC hw_wall_cycles %0d", wall_cycles);
        $display("METRIC baseline_cycles %0d", base_full);
        $display("METRIC sustained_values_per_clock %0.4f", thr_full);
        $display("METRIC peak_values_per_clock %0.4f", thr_peak);
        $display("METRIC decode_latency_cycles %0d", pk_latency);
        $display("METRIC peak_hw_cycles %0d", pk_hw);
        $display("METRIC peak_baseline_cycles %0d", base_peak);
        $display("METRIC speedup_aggregate %0.2f", spd_agg);
        $display("METRIC speedup_peak %0.2f", spd_peak);
        $display("METRIC mismatches %0d", errors);
        $display("==================================================");

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

    // watchdog
    initial begin
        #120000000;
        $display("TIMEOUT"); $display("TEST FAILED (timeout)");
        $finish;
    end
endmodule

`default_nettype wire
