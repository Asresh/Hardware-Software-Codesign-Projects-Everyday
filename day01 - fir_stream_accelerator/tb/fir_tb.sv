// -----------------------------------------------------------------------------
// fir_tb.sv
// Self-checking differential testbench for the streaming FIR accelerator.
//   * Drives the AXI4-Lite control plane (an in-testbench AXI4-Lite master).
//   * Feeds AXI4-Stream input and drains AXI4-Stream output as two concurrent
//     processes, so producer gaps and consumer stalls exercise real end-to-end
//     backpressure.
//   * Compares every result against the software golden vectors ($readmemh)
//     produced by sw/fir_host, counting mismatches (must be zero).
//   * Measures per-job cycle counts, steady-state throughput, and fill latency.
//
// Parameters come from tb/vectors/params.vh (written by the Makefile) so the
// DUT elaboration matches the vectors. The job list + per-job length/stall mode
// come from tb/vectors/jobs.txt at run time.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module fir_tb;
`include "params.vh"
    localparam integer ACC_WIDTH = DATA_WIDTH + COEF_WIDTH + $clog2(TAPS);
    localparam integer MAX_VEC   = 4096;
    localparam integer MAX_JOBS  = 256;

    // stall-mode encoding (matches sw/fir_host.c)
    localparam integer STALL_NONE = 0, STALL_IN = 1, STALL_OUT = 2, STALL_BOTH = 3, STALL_LONGOUT = 4;

    // CSR offsets (matches sw/fir_accel.h)
    localparam [7:0] REG_CTRL=8'h00, REG_STATUS=8'h04, REG_LENGTH=8'h08,
                     REG_TAPCNT=8'h0C, REG_DWIDTH=8'h10, REG_SAMPOUT=8'h14,
                     REG_INLVL=8'h18, REG_OUTLVL=8'h1C, REG_COEF=8'h40;
    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_SOFT_CLR=32'h4;
    localparam [31:0] STATUS_DONE=32'h1, STATUS_BUSY=32'h2;

    // ---------------- clock / reset ----------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;              // 100 MHz

    integer cyc = 0;
    always @(posedge clk) cyc <= (!rst_n) ? 0 : cyc + 1;

    // ---------------- DUT signals ----------------
    reg  [ADDR_WIDTH-1:0] awaddr;  reg awvalid;  wire awready;
    reg  [31:0]           wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]            bresp;   wire bvalid;  reg bready;
    reg  [ADDR_WIDTH-1:0] araddr;  reg arvalid;  wire arready;
    wire [31:0]           rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    reg  [DATA_WIDTH-1:0] s_tdata;  reg s_tvalid; wire s_tready; reg s_tlast;
    wire [ACC_WIDTH-1:0]  m_tdata;  wire m_tvalid; reg m_tready; wire m_tlast;
    wire irq;

    fir_accel_top #(
        .DATA_WIDTH(DATA_WIDTH), .COEF_WIDTH(COEF_WIDTH), .TAPS(TAPS),
        .FIFO_DEPTH(FIFO_DEPTH), .LEN_WIDTH(LEN_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .irq(irq)
    );

    // ---------------- vector memories ----------------
    reg [COEF_WIDTH-1:0] coef_mem [0:MAX_VEC-1];
    reg [DATA_WIDTH-1:0] in_mem   [0:MAX_VEC-1];
    reg [ACC_WIDTH-1:0]  gold_mem [0:MAX_VEC-1];

    integer len_arr   [0:MAX_JOBS-1];
    integer stall_arr [0:MAX_JOBS-1];

    // ---------------- protocol monitors (immediate checks) ----------------
    integer proto_errors = 0;
    integer tlast_errors = 0;
    integer bp_in = 0;          // cycles input backpressure was actually observed

    // The stream must never accept a sample while the core is not armed (BUSY=0),
    // and we track how often s_axis_tready is held low against an offered sample
    // (end-to-end backpressure coverage).
    always @(posedge clk) if (rst_n) begin
        if (!dut.busy && s_tvalid && s_tready) begin
            $display("[%0t] PROTO: s_axis accepted while not BUSY", $time);
            proto_errors = proto_errors + 1;
        end
        if (s_tvalid && !s_tready) bp_in = bp_in + 1;
    end
    // Output data must be stable while stalled (tvalid held, tready low).
    reg [ACC_WIDTH-1:0] m_prev; reg m_prev_v;
    always @(posedge clk) begin
        if (!rst_n) begin m_prev_v <= 1'b0; end
        else begin
            if (m_tvalid && !m_tready && m_prev_v && (m_tdata !== m_prev)) begin
                $display("[%0t] PROTO: m_axis_tdata changed while stalled", $time);
                proto_errors = proto_errors + 1;
            end
            m_prev   <= m_tdata;
            m_prev_v <= m_tvalid && !m_tready;
        end
    end

    integer first_in_cyc, first_out_cyc;

    // ================= AXI4-Lite master tasks =================
    task axil_write(input [ADDR_WIDTH-1:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            awaddr <= addr; awvalid <= 1'b1;
            wdata  <= data; wstrb <= 4'hF; wvalid <= 1'b1;
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);   // both accepted this edge
            awvalid <= 1'b0; wvalid <= 1'b0;
            while (!bvalid) @(posedge clk);                // bready is tied high
            @(posedge clk);
        end
    endtask

    task axil_read(input [ADDR_WIDTH-1:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            araddr <= addr; arvalid <= 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            arvalid <= 1'b0;
            while (!rvalid) @(posedge clk);                // rready tied high
            data = rdata;
            @(posedge clk);
        end
    endtask

    // ================= stream feed / drain =================
    task feed_job(input integer len, input integer smode);
        integer i; reg do_gap; integer last_gap;
        begin
            i = 0; last_gap = -1;
            while (i < len) begin
                // one bounded starvation bubble at every third sample index
                do_gap = ((smode==STALL_IN)||(smode==STALL_BOTH)) &&
                         (((i+1)%3)==0) && (last_gap != i);
                if (do_gap) begin
                    s_tvalid <= 1'b0;
                    repeat (2) @(posedge clk);
                    last_gap = i;
                end else begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= in_mem[i];
                    s_tlast  <= (i==len-1);
                    @(posedge clk);
                    if (s_tready) begin
                        if (first_in_cyc < 0) first_in_cyc = cyc;
                        i = i + 1;
                    end
                end
            end
            s_tvalid <= 1'b0;
            s_tlast  <= 1'b0;
        end
    endtask

    task drain_job(input integer len, input integer smode, output integer mism);
        integer i; reg do_stall, do_long; integer last_stall; reg [ACC_WIDTH-1:0] got;
        begin
            i = 0; mism = 0; last_stall = -1;
            while (i < len) begin
                // one bounded consumer stall (3 cycles) at every fourth index;
                // long enough to fill the output FIFO and back-pressure upstream
                do_stall = ((smode==STALL_OUT)||(smode==STALL_BOTH)) &&
                           (((i+1)%4)==0) && (last_stall != i);
                // STALL_LONGOUT: one long stall early on so both FIFOs fill and
                // s_axis_tready is forced low while the producer keeps offering.
                do_long  = (smode==STALL_LONGOUT) && (i==2) && (last_stall != i);
                if (do_long) begin
                    m_tready <= 1'b0;
                    repeat (2*FIFO_DEPTH + 8) @(posedge clk);
                    last_stall = i;
                end else if (do_stall) begin
                    m_tready <= 1'b0;
                    repeat (3) @(posedge clk);
                    last_stall = i;
                end else begin
                    m_tready <= 1'b1;
                    @(posedge clk);
                    if (m_tvalid) begin
                        got = m_tdata;
                        if (first_out_cyc < 0) first_out_cyc = cyc;
                        if (got !== gold_mem[i]) begin
                            mism = mism + 1;
                            if (mism <= 4)
                                $display("  MISMATCH idx %0d: got %h exp %h", i, got, gold_mem[i]);
                        end
                        if (i==len-1) begin
                            if (m_tlast !== 1'b1) begin
                                $display("  TLAST missing on last beat (idx %0d)", i);
                                tlast_errors = tlast_errors + 1;
                            end
                        end else if (m_tlast !== 1'b0) begin
                            $display("  TLAST asserted early (idx %0d)", i);
                            tlast_errors = tlast_errors + 1;
                        end
                        i = i + 1;
                    end
                end
            end
            m_tready <= 1'b0;
        end
    endtask

    // ================= main sequence =================
    integer fd, r, j, k;
    integer njobs_f, taps_f, dw_f, cw_f, aw_f, fifo_f, idx;
    integer len, smode, job_mism;
    reg [31:0] rdv;
    integer total_mism, total_samples;
    integer bb_cycles, bb_samples, c0, c1;
    integer rep_len, rep_cyc, rep_lat;

    initial begin
        awvalid=0; wvalid=0; bready=1; arvalid=0; rready=1;
        s_tvalid=0; s_tlast=0; m_tready=0;
        awaddr=0; wdata=0; wstrb=0; araddr=0; s_tdata=0;

        $dumpfile("results/fir_tb.vcd");
        $dumpvars(0, fir_tb);

        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        fd = $fopen("tb/vectors/jobs.txt", "r");
        if (fd == 0) begin $display("FATAL: cannot open tb/vectors/jobs.txt"); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d %d\n", njobs_f, taps_f, dw_f, cw_f, aw_f, fifo_f);
        if (r != 6) begin $display("FATAL: bad jobs.txt header (r=%0d)", r); $finish; end
        if (taps_f!==TAPS || dw_f!==DATA_WIDTH || cw_f!==COEF_WIDTH ||
            aw_f!==ACC_WIDTH || fifo_f!==FIFO_DEPTH) begin
            $display("FATAL: vector params (T=%0d D=%0d C=%0d A=%0d F=%0d) != DUT (T=%0d D=%0d C=%0d A=%0d F=%0d)",
                     taps_f, dw_f, cw_f, aw_f, fifo_f, TAPS, DATA_WIDTH, COEF_WIDTH, ACC_WIDTH, FIFO_DEPTH);
            $finish;
        end
        for (j = 0; j < njobs_f; j = j + 1)
            r = $fscanf(fd, "%d %d %d\n", idx, len_arr[j], stall_arr[j]);
        $fclose(fd);

        // CSR sanity: read back the compile-time identity registers.
        axil_read(REG_TAPCNT, rdv);
        if (rdv !== TAPS) begin $display("PROTO: TAP_COUNT CSR=%0d != %0d", rdv, TAPS); proto_errors=proto_errors+1; end
        axil_read(REG_DWIDTH, rdv);
        if (rdv !== DATA_WIDTH) begin $display("PROTO: DATA_WIDTH CSR=%0d != %0d", rdv, DATA_WIDTH); proto_errors=proto_errors+1; end

        // Arming check: actively offer a sample before any START. The core must
        // refuse it (no admission) -- this exercises the BUSY gate for real.
        s_tdata  <= {DATA_WIDTH{1'b1}};
        s_tvalid <= 1'b1;
        repeat (6) @(posedge clk);
        axil_read(REG_INLVL, rdv);
        if (rdv !== 0) begin
            $display("PROTO: %0d samples admitted before START", rdv);
            proto_errors = proto_errors + 1;
        end
        axil_read(REG_SAMPOUT, rdv);
        if (rdv !== 0) begin
            $display("PROTO: SAMPLES_OUT nonzero before any job");
            proto_errors = proto_errors + 1;
        end
        s_tvalid <= 1'b0;
        @(posedge clk);

        total_mism=0; total_samples=0; bb_cycles=0; bb_samples=0;
        rep_len=0; rep_cyc=0; rep_lat=0;

        for (j = 0; j < njobs_f; j = j + 1) begin
            len   = len_arr[j];
            smode = stall_arr[j];
            $readmemh($sformatf("tb/vectors/coef_%03d.hex", j), coef_mem, 0, TAPS-1);
            $readmemh($sformatf("tb/vectors/in_%03d.hex",   j), in_mem,   0, len-1);
            $readmemh($sformatf("tb/vectors/gold_%03d.hex", j), gold_mem, 0, len-1);

            axil_write(REG_CTRL, CTRL_SOFT_CLR);
            for (k = 0; k < TAPS; k = k + 1)
                axil_write(REG_COEF + 8'(4*k), {{(32-COEF_WIDTH){1'b0}}, coef_mem[k]});
            axil_write(REG_LENGTH, len);

            first_in_cyc = -1; first_out_cyc = -1;
            axil_write(REG_CTRL, CTRL_START | CTRL_IRQ_EN);
            c0 = cyc;

            fork
                feed_job(len, smode);
                drain_job(len, smode, job_mism);
            join

            rdv = 0;
            while (!(rdv & STATUS_DONE)) axil_read(REG_STATUS, rdv);
            c1 = cyc;

            axil_read(REG_SAMPOUT, rdv);
            if (rdv !== len) begin
                $display("  SAMPLES_OUT=%0d != len=%0d (job %0d)", rdv, len, j);
                total_mism = total_mism + 1;
            end
            if (irq !== 1'b1) begin
                $display("  irq not asserted at DONE (job %0d)", j);
                proto_errors = proto_errors + 1;
            end

            total_mism    = total_mism + job_mism;
            total_samples = total_samples + len;
            if (smode == STALL_NONE) begin
                bb_cycles  = bb_cycles + (c1 - c0);
                bb_samples = bb_samples + len;
                if (len > rep_len) begin
                    rep_len = len; rep_cyc = (c1 - c0);
                    rep_lat = (first_out_cyc - first_in_cyc);
                end
            end
            $display("job %0d: len=%0d stall=%0d cyc=%0d mism=%0d", j, len, smode, (c1-c0), job_mism);
        end

        // ---------------- summary (parsed by scripts/extract_metrics.py) ----------------
        $display("==== SUMMARY ====");
        $display("RESULT total_jobs %0d", njobs_f);
        $display("RESULT total_samples %0d", total_samples);
        $display("RESULT total_mismatches %0d", total_mism);
        $display("RESULT proto_errors %0d", proto_errors);
        $display("RESULT tlast_errors %0d", tlast_errors);
        $display("RESULT input_backpressure_cycles %0d", bp_in);
        $display("RESULT bb_samples %0d", bb_samples);
        $display("RESULT bb_cycles %0d", bb_cycles);
        $display("RESULT rep_len %0d", rep_len);
        $display("RESULT rep_cycles %0d", rep_cyc);
        $display("RESULT rep_latency %0d", rep_lat);
        $display("RESULT taps %0d", TAPS);
        $display("RESULT data_width %0d", DATA_WIDTH);
        $display("RESULT coef_width %0d", COEF_WIDTH);
        $display("RESULT acc_width %0d", ACC_WIDTH);
        $display("RESULT fifo_depth %0d", FIFO_DEPTH);

        if (total_mism==0 && proto_errors==0 && tlast_errors==0 && bp_in>0)
            $display("TEST PASSED: %0d jobs, %0d samples, 0 mismatches, backpressure exercised (%0d cyc)",
                     njobs_f, total_samples, bp_in);
        else
            $display("TEST FAILED: mism=%0d proto=%0d tlast=%0d bp_in=%0d",
                     total_mism, proto_errors, tlast_errors, bp_in);

        $finish;
    end

    // global watchdog
    initial begin
        #5_000_000;
        $display("FATAL: global timeout");
        $finish;
    end
endmodule

`default_nettype wire
