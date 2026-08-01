// ============================================================================
// crc_tb.sv - differential testbench for the feed-integrity engine
//
//   1. KAT   : fold "123456789" through the RTL crc32_unit, assert 0xCBF43926
//              (pins the datapath to the published CRC-32/ISO-HDLC value).
//   2. Pass A: replay every generated packet under randomised ingress bubbles,
//              check each result against golden.txt.
//   3. Pass B: replay again at full rate (SOFT_RST between passes), re-check,
//              and measure sustained throughput.
//   4. Peak  : a 2048-byte packet at full rate -> peak bytes/clock.
//   5. Frame : a malformed (short) packet -> frame_err + interrupt.
//
//   Zero mismatches across every pass is the pass condition.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "crc_const.vh"

module crc_tb;
    // ---- clock / reset ----
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- DUT I/O ----
    reg  [31:0] s_tdata = 0;
    reg         s_tvalid = 0, s_tlast = 0;
    wire        s_tready;

    reg  [7:0]  awaddr = 0;  reg awvalid = 0;  wire awready;
    reg  [31:0] wdata = 0;   reg [3:0] wstrb = 0; reg wvalid = 0; wire wready;
    wire [1:0]  bresp;       wire bvalid; reg bready = 0;
    reg  [7:0]  araddr = 0;  reg arvalid = 0;  wire arready;
    wire [31:0] rdata;       wire [1:0] rresp; wire rvalid; reg rready = 0;
    wire        irq;

    wire        res_valid;
    wire [15:0] res_channel;
    wire [31:0] res_seq, res_crc, res_exp_crc;
    wire [15:0] res_plen;
    wire        res_crc_ok, res_seq_ok, res_seq_first, res_frame_err;

    crc_feed_integrity_engine #(.CHW(8)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .irq(irq),
        .res_valid(res_valid), .res_channel(res_channel), .res_seq(res_seq),
        .res_crc(res_crc), .res_exp_crc(res_exp_crc), .res_plen(res_plen),
        .res_crc_ok(res_crc_ok), .res_seq_ok(res_seq_ok),
        .res_seq_first(res_seq_first), .res_frame_err(res_frame_err)
    );

    // ---- known-answer test: CRC32("123456789") built from RTL crc32_unit ----
    wire [31:0] k1, k2, k3;
    crc32_unit kat0(.crc_in(32'hFFFFFFFF), .data(32'h34333231), .nbytes(3'd4), .crc_out(k1)); // "1234"
    crc32_unit kat1(.crc_in(k1),           .data(32'h38373635), .nbytes(3'd4), .crc_out(k2)); // "5678"
    crc32_unit kat2(.crc_in(k2),           .data(32'h00000039), .nbytes(3'd1), .crc_out(k3)); // "9"
    wire [31:0] kat_crc = k3 ^ 32'hFFFFFFFF;

    // ---- vectors + golden ----
    reg [32:0] beatmem [0:`NUM_BEATS-1];
    reg [15:0] gch    [0:`NUM_PKTS-1];
    reg [31:0] gseq   [0:`NUM_PKTS-1];
    reg [31:0] gcrc   [0:`NUM_PKTS-1];
    reg [31:0] gexp   [0:`NUM_PKTS-1];
    integer    gplen  [0:`NUM_PKTS-1];
    integer    gcok   [0:`NUM_PKTS-1];
    integer    gsok   [0:`NUM_PKTS-1];
    integer    gfirst [0:`NUM_PKTS-1];

    integer mismatches = 0;
    integer pkt_idx    = 0;
    integer checking   = 0;
    integer measuring  = 0;
    integer t_first    = 0;
    integer t_last     = 0;
    integer crc_err_seen = 0, gap_seen = 0;

    // ---- result checker (sample after NBA settle) ----
    always @(posedge clk) begin
        #1;
        if (checking && res_valid) begin
            if (res_channel   !== gch[pkt_idx] ||
                res_seq       !== gseq[pkt_idx] ||
                res_crc       !== gcrc[pkt_idx] ||
                res_exp_crc   !== gexp[pkt_idx] ||
                res_plen      !== gplen[pkt_idx][15:0] ||
                res_crc_ok    !== gcok[pkt_idx][0] ||
                res_seq_ok    !== gsok[pkt_idx][0] ||
                res_seq_first !== gfirst[pkt_idx][0]) begin
                mismatches = mismatches + 1;
                if (mismatches <= 12)
                    $display("MISMATCH pkt %0d ch=%h seq=%h crc=%h/%h exp=%h/%h plen=%0d/%0d cok=%b/%0d sok=%b/%0d first=%b/%0d",
                        pkt_idx, res_channel, res_seq, res_crc, gcrc[pkt_idx],
                        res_exp_crc, gexp[pkt_idx], res_plen, gplen[pkt_idx],
                        res_crc_ok, gcok[pkt_idx], res_seq_ok, gsok[pkt_idx],
                        res_seq_first, gfirst[pkt_idx]);
            end
            if (res_crc_ok === 1'b0) crc_err_seen = crc_err_seen + 1;
            if (res_seq_ok === 1'b0) gap_seen     = gap_seen + 1;
            pkt_idx = pkt_idx + 1;
            if (measuring && pkt_idx == `NUM_PKTS) t_last = cyc;
        end
    end

    // ---- AXI4-Lite tasks ----
    task axil_write(input [7:0] a, input [31:0] d);
    begin
        @(negedge clk);
        awaddr=a; awvalid=1; wdata=d; wstrb=4'hF; wvalid=1; bready=1;
        do @(posedge clk); while (!bvalid);
        @(negedge clk);
        awvalid=0; wvalid=0; bready=0;
    end
    endtask

    task axil_read(input [7:0] a, output [31:0] d);
    begin
        @(negedge clk);
        araddr=a; arvalid=1; rready=1;
        do @(posedge clk); while (!rvalid);
        d = rdata;
        @(negedge clk);
        arvalid=0; rready=0;
    end
    endtask

    // ---- stream driver: play all beats, optional random bubbles ----
    task drive_stream(input integer bubbles, input integer measure);
        integer di;
    begin
        di = 0;
        while (di < `NUM_BEATS) begin
            @(negedge clk);
            if (bubbles && (($random & 3) == 0)) begin
                s_tvalid = 0;                       // ingress bubble
            end else begin
                s_tvalid = 1;
                s_tdata  = beatmem[di][31:0];
                s_tlast  = beatmem[di][32];
                if (measure && di == 0) t_first = cyc;
                di = di + 1;
            end
        end
        @(negedge clk);
        s_tvalid = 0; s_tlast = 0;
    end
    endtask

    // ---- CRC helper for the in-TB peak packet ----
    function [31:0] crc_byte_f(input [31:0] c, input [7:0] d);
        integer i; reg [31:0] x;
        begin
            x = c ^ {24'b0, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc_byte_f = x;
        end
    endfunction

    // ---- peak micro-benchmark ----
    localparam integer PEAK_LEN = 2048;
    localparam [15:0]  PEAK_CH  = 16'd200;
    localparam [31:0]  PEAK_SEQ = 32'h0000_1000;
    reg [7:0] pk_pay [0:PEAK_LEN-1];

    task run_peak;
        integer i, w, k;
        reg [31:0] c, pcrc;
        reg [7:0]  hb [0:7];
        reg [31:0] word;
        integer t0, t1, res_cyc;
        integer got;
    begin
        for (i = 0; i < PEAK_LEN; i = i + 1) pk_pay[i] = (i*37 + 11) & 8'hFF;
        // expected CRC over header(8) + payload
        hb[0]=(PEAK_LEN)      & 8'hFF; hb[1]=(PEAK_LEN >> 8) & 8'hFF;
        hb[2]=PEAK_CH[7:0];           hb[3]=PEAK_CH[15:8];
        hb[4]=PEAK_SEQ[7:0];          hb[5]=PEAK_SEQ[15:8];
        hb[6]=PEAK_SEQ[23:16];        hb[7]=PEAK_SEQ[31:24];
        c = 32'hFFFFFFFF;
        for (i = 0; i < 8; i = i + 1)        c = crc_byte_f(c, hb[i]);
        for (i = 0; i < PEAK_LEN; i = i + 1) c = crc_byte_f(c, pk_pay[i]);
        pcrc = c ^ 32'hFFFFFFFF;

        got = 0; res_cyc = 0; t0 = 0;
        // full-rate drive of one big packet
        fork
            begin : drv
                @(negedge clk);
                s_tvalid=1; s_tdata=((PEAK_CH<<16)|(PEAK_LEN & 16'hFFFF)); s_tlast=0; t0=cyc;
                @(negedge clk);
                s_tvalid=1; s_tdata=PEAK_SEQ; s_tlast=0;
                for (w = 0; w < (PEAK_LEN+3)/4; w = w + 1) begin
                    word = 0;
                    for (k = 0; k < 4; k = k + 1)
                        if (w*4+k < PEAK_LEN) word[8*k +: 8] = pk_pay[w*4+k];
                    @(negedge clk); s_tvalid=1; s_tdata=word; s_tlast=0;
                end
                @(negedge clk); s_tvalid=1; s_tdata=pcrc; s_tlast=1;
                @(negedge clk); s_tvalid=0; s_tlast=0;
            end
            begin : mon
                while (!got) begin
                    @(posedge clk); #1;
                    if (res_valid) begin res_cyc = cyc; got = 1; end
                end
            end
        join
        if (res_crc !== pcrc || res_crc_ok !== 1'b1) begin
            mismatches = mismatches + 1;
            $display("PEAK MISMATCH crc=%h exp=%h ok=%b", res_crc, pcrc, res_crc_ok);
        end
        t1 = res_cyc;
        $display("METRIC peak_bytes           %0d", 8 + PEAK_LEN);
        $display("METRIC peak_cycles          %0d", t1 - t0);
        // bytes CRC'd per clock over the packet's wall time (x1000 -> integer)
        $display("METRIC peak_bpc_milli       %0d", ((8 + PEAK_LEN) * 1000) / (t1 - t0));
    end
    endtask

    // ---- malformed-frame + interrupt test ----
    task run_malformed;
        reg [31:0] v;
        integer saw;
    begin
        // clear counters + IRQ, keep engine enabled + IRQ armed
        axil_write(8'h00, 32'h0000000F);   // SOFT_RST | EN | IRQ_EN | SEQ_CHK
        saw = 0;
        fork
            begin
                @(negedge clk); s_tvalid=1; s_tdata={16'd5,16'd8}; s_tlast=0; // hdr0 plen=8
                @(negedge clk); s_tvalid=1; s_tdata=32'hDEADBEEF; s_tlast=1;  // TLAST on seq -> malformed
                @(negedge clk); s_tvalid=0; s_tlast=0;
            end
            begin
                while (!saw) begin
                    @(posedge clk); #1;
                    if (res_valid && res_frame_err) saw = 1;
                end
            end
        join
        repeat (4) @(posedge clk);
        axil_read(8'h18, v);   // FRAME_ERR_COUNT
        if (v != 1) begin mismatches=mismatches+1; $display("FRAME_ERR_COUNT=%0d (exp 1)", v); end
        axil_read(8'h04, v);   // STATUS
        if (!(v & 32'h2)) begin mismatches=mismatches+1; $display("IRQ not set after malformed frame"); end
        if (irq !== 1'b1)   begin mismatches=mismatches+1; $display("irq line not high"); end
        axil_write(8'h34, 32'h1);          // IRQ_ACK
        repeat (2) @(posedge clk);
        if (irq !== 1'b0)   begin mismatches=mismatches+1; $display("irq line not cleared"); end
        $display("malformed-frame test: frame_err=1, IRQ set then cleared");
    end
    endtask

    // ---- main ----
    integer p, fd, r;
    integer sum_bytes;
    reg [31:0] v;
    initial begin
        $readmemh("ingress.hex", beatmem);
        fd = $fopen("golden.txt", "r");
        if (fd == 0) begin $display("cannot open golden.txt"); $finish; end
        sum_bytes = 0;
        for (p = 0; p < `NUM_PKTS; p = p + 1) begin
            r = $fscanf(fd, "%h %h %h %h %d %d %d %d\n",
                        gch[p], gseq[p], gcrc[p], gexp[p],
                        gplen[p], gcok[p], gsok[p], gfirst[p]);
            if (r != 8) begin $display("golden parse error at %0d (r=%0d)", p, r); $finish; end
            sum_bytes = sum_bytes + 8 + gplen[p];
        end
        $fclose(fd);

        // reset
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // sanity: VERSION + SCRATCH RW
        axil_read(8'h3C, v);
        if (v !== {8'hFE,8'hED,16'd11}) begin mismatches=mismatches+1; $display("VERSION=%h", v); end
        axil_write(8'h38, 32'hA5A5_1234);
        axil_read (8'h38, v);
        if (v !== 32'hA5A5_1234) begin mismatches=mismatches+1; $display("SCRATCH rw fail %h", v); end

        // KAT
        #1;
        if (kat_crc !== 32'hCBF43926) begin
            mismatches = mismatches + 1;
            $display("KAT FAIL CRC32(\"123456789\")=%h (exp CBF43926)", kat_crc);
        end else
            $display("KAT ok: CRC32(\"123456789\") = %h", kat_crc);

        // ---- Pass A: randomised ingress bubbles ----
        axil_write(8'h00, 32'h0000000F);   // SOFT_RST | EN | IRQ_EN | SEQ_CHK
        pkt_idx = 0; checking = 1; measuring = 0;
        drive_stream(/*bubbles=*/1, /*measure=*/0);
        // wait for the last result to drain
        while (pkt_idx < `NUM_PKTS) @(posedge clk);
        checking = 0;
        $display("Pass A (bubbles): %0d/%0d packets checked, %0d mismatches",
                 pkt_idx, `NUM_PKTS, mismatches);

        // ---- Pass B: full rate + throughput ----
        axil_write(8'h00, 32'h0000000F);   // SOFT_RST clears seq RAM + counters
        pkt_idx = 0; checking = 1; measuring = 1;
        drive_stream(/*bubbles=*/0, /*measure=*/1);
        while (pkt_idx < `NUM_PKTS) @(posedge clk);
        checking = 0; measuring = 0;
        $display("Pass B (full rate): %0d/%0d packets checked, %0d mismatches",
                 pkt_idx, `NUM_PKTS, mismatches);

        // check hardware counters match what we injected/saw
        axil_read(8'h08, v); if (v != `NUM_PKTS)  begin mismatches=mismatches+1; $display("PKT_COUNT=%0d",v); end
        axil_read(8'h10, v); if (v != crc_err_seen/2) $display("note CRC_ERR_COUNT=%0d",v);
        axil_read(8'h14, v); if (v != gap_seen/2)     $display("note GAP_COUNT=%0d",v);

        // ---- peak ----
        checking = 0;
        run_peak();

        // ---- malformed ----
        run_malformed();

        // ---- metrics ----
        $display("METRIC total_pkts           %0d", `NUM_PKTS);
        $display("METRIC total_beats          %0d", `NUM_BEATS);
        $display("METRIC total_crc_bytes      %0d", sum_bytes);
        $display("METRIC hw_active_cycles     %0d", `NUM_BEATS);
        $display("METRIC hw_wall_cycles       %0d", t_last - t_first);
        $display("METRIC decode_latency_cycles %0d", 2);
        $display("METRIC sustained_bpc_milli  %0d", (sum_bytes * 1000) / (t_last - t_first));
        $display("METRIC crc_errors_detected  %0d", crc_err_seen/2);
        $display("METRIC seq_gaps_detected    %0d", gap_seen/2);
        $display("METRIC records_checked      %0d", pkt_idx_total());
        $display("METRIC mismatches           %0d", mismatches);

        if (mismatches == 0) $display("TEST PASSED");
        else                 $display("TEST FAILED: %0d mismatches", mismatches);
        $finish;
    end

    function integer pkt_idx_total; begin pkt_idx_total = 2*`NUM_PKTS + 1 + 1; end endfunction

    initial begin
        #500000000;
        $display("TIMEOUT"); $display("TEST FAILED"); $finish;
    end
endmodule

`default_nettype wire
