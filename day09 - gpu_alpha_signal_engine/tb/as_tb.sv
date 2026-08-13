// ============================================================================
// as_tb.sv - differential testbench for the alpha-signal engine.
//
// For every stream in the generated corpus: soft-reset the engine, program the
// config over AXI4-Lite, replay the ticks into the AXI4-Stream ingress, and
// compare every emitted signal record against the software golden record for
// that tick.  Two passes:
//   A) correctness - randomised ingress gaps and egress backpressure
//   B) performance - full rate both sides, measuring sustained/peak throughput
// Also checks the control plane: per-stream TICKCNT/RECCNT counters, the alert
// count, and the interrupt (assert + acknowledge).  Any mismatch fails the run.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module as_tb;
`include "asig_const.vh"

    // ---- clock / reset ----
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- DUT I/O ----
    reg          s_tvalid; wire s_tready; reg [63:0] s_tdata; reg s_tlast;
    wire         m_tvalid; reg  m_tready; wire [255:0] m_tdata; wire m_tlast;
    reg  [7:0]   awaddr;  reg awvalid; wire awready;
    reg  [31:0]  wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]   bresp;   wire bvalid; reg bready;
    reg  [7:0]   araddr;  reg arvalid; wire arready;
    wire [31:0]  rdata;   wire [1:0] rresp; wire rvalid; reg rready;
    wire         irq;

    alpha_signal_engine #(
        .N_SYM(N_SYM), .SYMW(SYMW), .FRAC(FRAC)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tdata(s_tdata), .s_tlast(s_tlast),
        .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tdata(m_tdata), .m_tlast(m_tlast),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .irq(irq)
    );

    // ---- corpus ----
    reg [63:0]  tick_mem [0:TOTAL_TICKS-1];
    reg [255:0] gold_mem [0:TOTAL_TICKS-1];
    reg [31:0]  len_mem  [0:N_STREAMS-1];
    reg [159:0] cfg_mem  [0:N_STREAMS-1];

    // register map
    localparam [7:0] R_CTRL=8'h00, R_ALPHA=8'h04, R_BETA=8'h08, R_GAMMA=8'h0C,
                     R_ZTH=8'h10, R_WARM=8'h14, R_STATUS=8'h18, R_TICK=8'h1C,
                     R_REC=8'h20, R_ALERT=8'h24, R_IRQACK=8'h28;

    // ---- checker state (sole writer: the monitor) ----
    integer rec_idx, mismatches, total_checks;
    reg [63:0] cyc;
    reg        egress_bp;

    // free-running cycle counter + egress checker
    always @(posedge clk) begin
        cyc <= cyc + 64'd1;
        if (m_tvalid && m_tready) begin
            total_checks <= total_checks + 1;
            if (m_tdata !== gold_mem[rec_idx]) begin
                mismatches <= mismatches + 1;
                if (mismatches < 12)
                    $display("  MISMATCH rec %0d:\n    dut =%064x\n    gold=%064x",
                             rec_idx, m_tdata, gold_mem[rec_idx]);
            end
            rec_idx <= rec_idx + 1;
        end
    end

    // egress backpressure generator
    reg [31:0] lfsr;
    always @(posedge clk) begin
        lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        m_tready <= egress_bp ? (lfsr[3:2] != 2'b00) : 1'b1;
    end

    // ---- AXI4-Lite helpers ----
    task axil_write(input [7:0] a, input [31:0] d);
        begin
            @(posedge clk);
            awaddr <= a; wdata <= d; wstrb <= 4'hF;
            awvalid <= 1'b1; wvalid <= 1'b1; bready <= 1'b1;
            @(posedge clk);
            awvalid <= 1'b0; wvalid <= 1'b0;
            @(posedge clk);
            while (bvalid !== 1'b0) @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task axil_read(input [7:0] a, output [31:0] d);
        begin
            @(posedge clk);
            araddr <= a; arvalid <= 1'b1; rready <= 1'b1;
            @(posedge clk);
            arvalid <= 1'b0;
            while (!rvalid) @(posedge clk);
            d = rdata;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    task program_cfg(input integer s);
        begin
            axil_write(R_ALPHA, cfg_mem[s][159:128]);
            axil_write(R_BETA,  cfg_mem[s][127:96]);
            axil_write(R_GAMMA, cfg_mem[s][95:64]);
            axil_write(R_ZTH,   cfg_mem[s][63:32]);
            axil_write(R_WARM,  cfg_mem[s][31:0]);
            // enable | soft_reset | irq_enable
            axil_write(R_CTRL,  32'h0000_0007);
            repeat (N_SYM + 8) @(posedge clk);   // wait clear FSM
        end
    endtask

    // feed one stream; report the first/last accept cycles
    reg [63:0] first_acc_cyc, last_acc_cyc;
    reg        ingress_bp;
    task feed_stream(input integer off, input integer len);
        integer idx; reg gap; reg started;
        begin
            idx = 0; started = 1'b0;
            s_tvalid = 1'b0; s_tlast = 1'b0;
            while (idx < len) begin
                gap = ingress_bp ? (lfsr[5:4] == 2'b00) : 1'b0;
                if (!gap) begin
                    s_tvalid = 1'b1; s_tdata = tick_mem[off+idx];
                    s_tlast  = (idx == len-1);
                end else s_tvalid = 1'b0;
                @(posedge clk);
                if (s_tvalid && s_tready) begin
                    if (!started) begin first_acc_cyc = cyc; started = 1'b1; end
                    last_acc_cyc = cyc;
                    idx = idx + 1;
                end
            end
            s_tvalid = 1'b0; s_tlast = 1'b0;
        end
    endtask

    task wait_records(input integer target);
        begin while (rec_idx < target) @(posedge clk); end
    endtask

    // ---- performance / control-plane accumulators ----
    reg [63:0] hw_cycles_total, accept_span_total, latency_min;
    integer    cp_errors;

    integer s, base, i;
    reg [31:0] rd_tick, rd_rec, rd_alert, rd_status;
    integer    exp_alerts;
    reg [63:0] t_first_rec;

    initial begin
        s_tvalid=0; s_tdata=0; s_tlast=0; m_tready=1;
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        cyc=0; rec_idx=0; mismatches=0; total_checks=0;
        hw_cycles_total=0; accept_span_total=0; latency_min=64'hFFFF_FFFF_FFFF_FFFF;
        cp_errors=0; lfsr=32'hACE1_2345; egress_bp=0; ingress_bp=0;

        $readmemh("tb/vectors/ticks.hex", tick_mem);
        $readmemh("tb/vectors/gold.hex",  gold_mem);
        $readmemh("tb/vectors/lens.hex",  len_mem);
        $readmemh("tb/vectors/cfg.hex",   cfg_mem);

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);

        // =============== PASS A: correctness w/ backpressure ===============
        rec_idx = 0;
        base = 0;
        ingress_bp = 1'b1; egress_bp = 1'b1;
        for (s = 0; s < N_STREAMS; s = s + 1) begin
            program_cfg(s);
            feed_stream(base, len_mem[s]);
            wait_records(base + len_mem[s]);
            base = base + len_mem[s];
        end
        $display("PASS A done: checks=%0d mismatches=%0d", total_checks, mismatches);

        // =============== PASS B: performance + control plane ===============
        // full drain, then restart the golden index for a clean re-run
        repeat (128) @(posedge clk);
        rec_idx = 0; base = 0;
        ingress_bp = 1'b0; egress_bp = 1'b0;
        for (s = 0; s < N_STREAMS; s = s + 1) begin
            program_cfg(s);
            fork
                feed_stream(base, len_mem[s]);
                begin : cap_first
                    // latency: first record of this stream vs first accept
                    while (rec_idx < base + 1) @(posedge clk);
                    t_first_rec = cyc;
                end
            join
            wait_records(base + len_mem[s]);
            hw_cycles_total   = hw_cycles_total + (cyc - first_acc_cyc + 1);
            accept_span_total = accept_span_total + (last_acc_cyc - first_acc_cyc + 1);
            if ((t_first_rec - first_acc_cyc) < latency_min)
                latency_min = t_first_rec - first_acc_cyc;

            // control-plane checks
            exp_alerts = 0;
            for (i = 0; i < len_mem[s]; i = i + 1)
                if (gold_mem[base+i][0]) exp_alerts = exp_alerts + 1;  // F_ALERT
            axil_read(R_TICK,  rd_tick);
            axil_read(R_REC,   rd_rec);
            axil_read(R_ALERT, rd_alert);
            axil_read(R_STATUS,rd_status);
            if (rd_tick  !== len_mem[s]) begin cp_errors=cp_errors+1;
                if (cp_errors<8) $display("  CP tick mismatch s=%0d got=%0d exp=%0d",s,rd_tick,len_mem[s]); end
            if (rd_rec   !== len_mem[s]) begin cp_errors=cp_errors+1;
                if (cp_errors<8) $display("  CP rec mismatch s=%0d got=%0d exp=%0d",s,rd_rec,len_mem[s]); end
            if (rd_alert !== exp_alerts) begin cp_errors=cp_errors+1;
                if (cp_errors<8) $display("  CP alert mismatch s=%0d got=%0d exp=%0d",s,rd_alert,exp_alerts); end
            if (rd_status[1] !== (exp_alerts>0)) begin cp_errors=cp_errors+1;
                if (cp_errors<8) $display("  CP irq status mismatch s=%0d got=%0b exp=%0b",s,rd_status[1],(exp_alerts>0)); end
            if (irq !== (exp_alerts>0)) begin cp_errors=cp_errors+1;
                if (cp_errors<8) $display("  CP irq pin mismatch s=%0d got=%0b exp=%0b",s,irq,(exp_alerts>0)); end
            if (exp_alerts > 0) begin
                axil_write(R_IRQACK, 32'd1);
                @(posedge clk);
                if (irq !== 1'b0) begin cp_errors=cp_errors+1;
                    if (cp_errors<8) $display("  CP irq not cleared s=%0d",s); end
            end
            base = base + len_mem[s];
        end

        // ---- summary ----
        $display("");
        $display("STREAMS %0d", N_STREAMS);
        $display("CHECKS %0d", total_checks);
        $display("MISMATCHES %0d", mismatches);
        $display("CP_ERRORS %0d", cp_errors);
        $display("HW_CYCLES_TOTAL %0d", hw_cycles_total);
        $display("ACCEPT_SPAN_TOTAL %0d", accept_span_total);
        $display("TOTAL_TICKS %0d", TOTAL_TICKS);
        $display("LATENCY_CYCLES %0d", latency_min);
        $display("");
        if (mismatches == 0 && cp_errors == 0 && total_checks == 2*TOTAL_TICKS)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

    // watchdog
    initial begin
        #500_000_000;
        $display("TIMEOUT"); $display("TEST FAILED"); $finish;
    end
endmodule
`default_nettype wire
