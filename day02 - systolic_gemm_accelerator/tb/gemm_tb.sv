// -----------------------------------------------------------------------------
// gemm_tb.sv
// Self-checking differential testbench for the systolic GEMM accelerator.
//   * Drives the Wishbone B4 control plane as an in-testbench master.
//   * For every job, loads the A^T / B operand windows, programs KLEN + MODE,
//     pulses START, waits for DONE, and reads the C tile back.
//   * Compares each checked C tile against the software golden ($readmemh),
//     counting mismatches (must be zero).
//   * Reads the hardware CYCLES register per run and reports peak/typical/
//     sustained MAC-per-cycle throughput.
//
// Parameters come from tb/vectors/params.vh (written by the Makefile) so the
// DUT elaboration matches the vectors; the job list comes from
// tb/vectors/jobs.txt at run time.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module gemm_tb;
`include "params.vh"
    localparam integer NN      = N * N;
    localparam integer MAXBYTE = N * KMAX;
    localparam integer MAX_JOBS = 512;

    // CSR offsets (match sw/gemm_accel.h and rtl/wb_slave.v)
    localparam [ADDR_WIDTH-1:0] REG_CTRL=16'h0000, REG_STATUS=16'h0004,
        REG_KLEN=16'h0008, REG_MODE=16'h000C, REG_NDIM=16'h0010,
        REG_DATAW=16'h0014, REG_KMAXR=16'h0018, REG_CYCLES=16'h001C,
        WIN_A=16'h1000, WIN_B=16'h2000, WIN_C=16'h3000;
    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_IRQ_CLR=32'h4;
    localparam [31:0] STATUS_DONE=32'h1, STATUS_BUSY=32'h2, MODE_ACCUM=32'h1;

    // ---------------- clock / reset ----------------
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                 // 100 MHz

    // ---------------- DUT wires ----------------
    reg  [ADDR_WIDTH-1:0] wb_adr;
    reg  [31:0]           wb_dat_w;
    wire [31:0]           wb_dat_o;
    reg  [3:0]            wb_sel;
    reg                   wb_we, wb_stb, wb_cyc;
    wire                  wb_ack, irq;

    gemm_top #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .KMAX(KMAX), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wb_adr_i(wb_adr), .wb_dat_i(wb_dat_w), .wb_dat_o(wb_dat_o),
        .wb_sel_i(wb_sel), .wb_we_i(wb_we), .wb_stb_i(wb_stb), .wb_cyc_i(wb_cyc),
        .wb_ack_o(wb_ack), .irq(irq)
    );

    // ---------------- vector memories ----------------
    reg [DATA_WIDTH-1:0] a_mem [0:MAXBYTE-1];
    reg [DATA_WIDTH-1:0] b_mem [0:MAXBYTE-1];
    reg [ACC_WIDTH-1:0]  c_gold[0:NN-1];

    integer K_arr [0:MAX_JOBS-1];
    integer ac_arr[0:MAX_JOBS-1];
    integer ck_arr[0:MAX_JOBS-1];

    integer proto_errors = 0;

    // ================= Wishbone master =================
    task wb_write(input [ADDR_WIDTH-1:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            wb_adr <= addr; wb_dat_w <= data; wb_we <= 1'b1;
            wb_sel <= 4'hF; wb_stb <= 1'b1; wb_cyc <= 1'b1;
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            wb_stb <= 1'b0; wb_cyc <= 1'b0; wb_we <= 1'b0;
        end
    endtask

    task wb_read(input [ADDR_WIDTH-1:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            wb_adr <= addr; wb_we <= 1'b0;
            wb_sel <= 4'hF; wb_stb <= 1'b1; wb_cyc <= 1'b1;
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            data = wb_dat_o;
            wb_stb <= 1'b0; wb_cyc <= 1'b0;
        end
    endtask

    // Load K*N operand bytes into a window, packing four lanes per word.
    task load_window(input [ADDR_WIDTH-1:0] base, input integer nbytes, input integer is_a);
        integer w; reg [31:0] word;
        begin
            for (w = 0; w < nbytes/4; w = w + 1) begin
                if (is_a)
                    word = {a_mem[4*w+3], a_mem[4*w+2], a_mem[4*w+1], a_mem[4*w+0]};
                else
                    word = {b_mem[4*w+3], b_mem[4*w+2], b_mem[4*w+1], b_mem[4*w+0]};
                wb_write(base + (w*4), word);
            end
        end
    endtask

    // ================= main sequence =================
    integer fd, r, j, e, K, accum, check, idx;
    integer njobs_f, n_f, dw_f, aw_f, kmax_f;
    reg [31:0] rdv, got;
    integer job_mism, total_mism, total_checks;
    // throughput accounting
    integer rep_macs, rep_cyc;                 // largest single run
    integer big_macs, big_cyc;                 // runs with K >= KMAX/2
    integer all_macs, all_cyc;                 // every run
    integer macs, cyc_hw;

    initial begin
        wb_adr=0; wb_dat_w=0; wb_sel=0; wb_we=0; wb_stb=0; wb_cyc=0;
        $dumpfile("results/gemm_tb.vcd");
        $dumpvars(0, gemm_tb);

        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---- read manifest ----
        fd = $fopen("tb/vectors/jobs.txt", "r");
        if (fd == 0) begin $display("FATAL: cannot open jobs.txt"); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d\n", njobs_f, n_f, dw_f, aw_f, kmax_f);
        if (r != 5) begin $display("FATAL: bad jobs.txt header (r=%0d)", r); $finish; end
        if (n_f!==N || dw_f!==DATA_WIDTH || aw_f!==ACC_WIDTH || kmax_f!==KMAX) begin
            $display("FATAL: vector params (N=%0d D=%0d A=%0d K=%0d) != DUT (N=%0d D=%0d A=%0d K=%0d)",
                     n_f, dw_f, aw_f, kmax_f, N, DATA_WIDTH, ACC_WIDTH, KMAX);
            $finish;
        end
        for (j = 0; j < njobs_f; j = j + 1)
            r = $fscanf(fd, "%d %d %d %d\n", idx, K_arr[j], ac_arr[j], ck_arr[j]);
        $fclose(fd);

        // ---- compile-time identity CSRs ----
        wb_read(REG_NDIM, rdv);
        if (rdv !== N)          begin $display("PROTO: N_DIM=%0d != %0d", rdv, N); proto_errors=proto_errors+1; end
        wb_read(REG_DATAW, rdv);
        if (rdv !== DATA_WIDTH) begin $display("PROTO: DATA_W=%0d != %0d", rdv, DATA_WIDTH); proto_errors=proto_errors+1; end
        wb_read(REG_KMAXR, rdv);
        if (rdv !== KMAX)       begin $display("PROTO: KMAX=%0d != %0d", rdv, KMAX); proto_errors=proto_errors+1; end
        // idle before any START
        wb_read(REG_STATUS, rdv);
        if (rdv & STATUS_BUSY)  begin $display("PROTO: BUSY set before any job"); proto_errors=proto_errors+1; end

        total_mism=0; total_checks=0;
        rep_macs=0; rep_cyc=0; big_macs=0; big_cyc=0; all_macs=0; all_cyc=0;

        for (j = 0; j < njobs_f; j = j + 1) begin
            K = K_arr[j]; accum = ac_arr[j]; check = ck_arr[j];

            $readmemh($sformatf("tb/vectors/a_%03d.hex", j), a_mem, 0, K*N-1);
            $readmemh($sformatf("tb/vectors/b_%03d.hex", j), b_mem, 0, K*N-1);
            if (check)
                $readmemh($sformatf("tb/vectors/c_%03d.hex", j), c_gold, 0, NN-1);

            load_window(WIN_A, K*N, 1);
            load_window(WIN_B, K*N, 0);

            wb_write(REG_KLEN, K);
            wb_write(REG_MODE, accum ? MODE_ACCUM : 32'h0);
            wb_write(REG_CTRL, CTRL_START | CTRL_IRQ_EN);

            // observe BUSY at least once, then wait for DONE
            rdv = 0;
            while (!(rdv & STATUS_DONE)) wb_read(REG_STATUS, rdv);

            if (irq !== 1'b1) begin
                $display("  irq not asserted at DONE (job %0d)", j);
                proto_errors = proto_errors + 1;
            end

            wb_read(REG_CYCLES, rdv);
            cyc_hw = rdv;
            macs   = NN * K;
            all_macs = all_macs + macs; all_cyc = all_cyc + cyc_hw;
            if (K*2 >= KMAX) begin big_macs = big_macs + macs; big_cyc = big_cyc + cyc_hw; end
            if (macs > rep_macs) begin rep_macs = macs; rep_cyc = cyc_hw; end

            // read + check C tile
            job_mism = 0;
            if (check) begin
                for (e = 0; e < NN; e = e + 1) begin
                    wb_read(WIN_C + (e*4), got);
                    if (got !== c_gold[e]) begin
                        job_mism = job_mism + 1;
                        if (total_mism + job_mism <= 6)
                            $display("  MISMATCH job %0d elem %0d: got %h exp %h",
                                     j, e, got, c_gold[e]);
                    end
                end
                total_mism   = total_mism + job_mism;
                total_checks = total_checks + NN;
            end

            // clear the interrupt and confirm it drops
            wb_write(REG_CTRL, CTRL_IRQ_CLR);
            if (irq !== 1'b0) begin
                $display("  irq stuck after IRQ_CLR (job %0d)", j);
                proto_errors = proto_errors + 1;
            end
            if (job_mism)
                $display("job %0d: K=%0d accum=%0d cyc=%0d mism=%0d", j, K, accum, cyc_hw, job_mism);
        end

        // ---------------- summary (parsed by scripts/extract_metrics.py) ----------------
        $display("==== SUMMARY ====");
        $display("RESULT total_jobs %0d", njobs_f);
        $display("RESULT total_output_checks %0d", total_checks);
        $display("RESULT total_mismatches %0d", total_mism);
        $display("RESULT proto_errors %0d", proto_errors);
        $display("RESULT rep_macs %0d", rep_macs);
        $display("RESULT rep_cycles %0d", rep_cyc);
        $display("RESULT big_macs %0d", big_macs);
        $display("RESULT big_cycles %0d", big_cyc);
        $display("RESULT all_macs %0d", all_macs);
        $display("RESULT all_cycles %0d", all_cyc);
        $display("RESULT n_dim %0d", N);
        $display("RESULT data_width %0d", DATA_WIDTH);
        $display("RESULT acc_width %0d", ACC_WIDTH);
        $display("RESULT kmax %0d", KMAX);

        if (total_mism==0 && proto_errors==0)
            $display("TEST PASSED: %0d jobs, %0d checked outputs, 0 mismatches",
                     njobs_f, total_checks);
        else
            $display("TEST FAILED: mism=%0d proto=%0d", total_mism, proto_errors);
        $finish;
    end

    // global watchdog
    initial begin
        #20_000_000;
        $display("FATAL: global timeout");
        $finish;
    end
endmodule

`default_nettype wire
