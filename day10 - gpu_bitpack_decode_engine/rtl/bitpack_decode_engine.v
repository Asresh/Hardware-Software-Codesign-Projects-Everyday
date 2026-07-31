// ============================================================================
// bitpack_decode_engine.v  -  top level
//
// GPU/FPGA-style line-rate columnar decompression engine. Ingests a
// self-describing compressed market-data column (frame-of-reference + delta +
// zig-zag + bit-packing, "PFOR"-style) on a 32-bit AXI4-Stream and emits the
// reconstructed 32-bit values, up to LANES per clock, on a wide AXI4-Stream.
//
// Block wire format (all little-endian, LSB-first bit packing):
//   word0            : base           (v[-1], the frame-of-reference value)
//   word1            : {width[31:26], reserved[25:16], count[15:0]}
//   ceil(count*width/32) payload words : count zig-zag residuals @ width bits
//
// Datapath:  reader (bit FIFO)  ->  extract (barrel-shift LANES fields)
//            ->  decode (zig-zag + delta prefix + base)  ->  egress register.
// The running per-block value carry updates combinationally so one group of
// LANES values retires every clock with no feedback bubble.
// ============================================================================
`default_nettype none

module bitpack_decode_engine #(
    parameter integer LANES  = 4,
    parameter integer DATA_W = 32,
    parameter integer WINW   = 128,
    parameter integer BUFW   = 192
) (
    input  wire                    clk,
    input  wire                    rst,      // sync, active high

    // ---- AXI4-Lite control/status ----
    input  wire [7:0]              s_axil_awaddr,
    input  wire                    s_axil_awvalid,
    output wire                    s_axil_awready,
    input  wire [31:0]             s_axil_wdata,
    input  wire [3:0]              s_axil_wstrb,
    input  wire                    s_axil_wvalid,
    output wire                    s_axil_wready,
    output wire [1:0]              s_axil_bresp,
    output wire                    s_axil_bvalid,
    input  wire                    s_axil_bready,
    input  wire [7:0]              s_axil_araddr,
    input  wire                    s_axil_arvalid,
    output wire                    s_axil_arready,
    output wire [31:0]             s_axil_rdata,
    output wire [1:0]              s_axil_rresp,
    output wire                    s_axil_rvalid,
    input  wire                    s_axil_rready,

    // ---- AXI4-Stream compressed ingress (32-bit) ----
    input  wire [31:0]             s_axis_tdata,
    input  wire                    s_axis_tvalid,
    output wire                    s_axis_tready,
    input  wire                    s_axis_tlast,

    // ---- AXI4-Stream decoded egress (LANES*32-bit) ----
    output wire [LANES*DATA_W-1:0] m_axis_tdata,
    output wire [2:0]              m_axis_tcnt,   // valid lanes in this beat 1..LANES
    output wire                    m_axis_tlast,  // last beat of a block
    output wire                    m_axis_tvalid,
    input  wire                    m_axis_tready,

    output wire                    irq
);
    // ---------------- control plane ----------------
    wire        en, irq_en, soft_rst;
    wire        busy;
    reg         done_pulse, err_pulse;
    reg  [31:0] errcode;
    reg  [31:0] blocks_q, values_q, cycles_q;

    bpd_regfile u_reg (
        .clk(clk), .rst(rst),
        .awaddr(s_axil_awaddr), .awvalid(s_axil_awvalid), .awready(s_axil_awready),
        .wdata(s_axil_wdata), .wstrb(s_axil_wstrb), .wvalid(s_axil_wvalid), .wready(s_axil_wready),
        .bresp(s_axil_bresp), .bvalid(s_axil_bvalid), .bready(s_axil_bready),
        .araddr(s_axil_araddr), .arvalid(s_axil_arvalid), .arready(s_axil_arready),
        .rdata(s_axil_rdata), .rresp(s_axil_rresp), .rvalid(s_axil_rvalid), .rready(s_axil_rready),
        .en(en), .irq_en(irq_en), .soft_rst(soft_rst),
        .busy(busy), .done_pulse(done_pulse), .err_pulse(err_pulse), .errcode_in(errcode),
        .blocks_in(blocks_q), .values_in(values_q), .cycles_in(cycles_q),
        .irq(irq)
    );

    wire core_rst = rst | soft_rst;

    // ---------------- bitstream reader ----------------
    // pop is COMBINATIONAL from the current state, so the reader advances in
    // the same cycle the FSM samples `window` (the window then shows the next
    // field/header on the following clock).
    reg          pop_en;
    reg  [8:0]   pop_bits;
    wire [WINW-1:0] window;
    wire [8:0]      vbits;
    wire         rd_flush;

    bpd_bitreader #(.IN_W(32), .BUFW(BUFW), .WINW(WINW)) u_reader (
        .clk(clk), .rst(core_rst), .flush(rd_flush),
        .s_tdata(s_axis_tdata), .s_tvalid(s_axis_tvalid),
        .s_tready(s_axis_tready), .s_tlast(s_axis_tlast),
        .pop_en(pop_en), .pop_bits(pop_bits),
        .window(window), .valid_bits(vbits), .last_seen()
    );

    // ---------------- extract + decode datapath ----------------
    reg  [5:0]                width_q;
    reg  [15:0]               remaining_q;
    reg  [DATA_W-1:0]         carry_q;
    reg  [20:0]               paybits_q;   // Sum of take*width; low 5 bits size the pad
    wire [LANES*DATA_W-1:0]   res_flat, val_flat;
    wire [DATA_W-1:0]         carry_out;

    // how many fields the current window can supply
    wire [8:0] w1 = {3'b0, width_q};
    wire [8:0] w2 = {2'b0, width_q, 1'b0};
    wire [8:0] w3 = w1 + w2;
    wire [8:0] w4 = {1'b0, width_q, 2'b0};
    wire [2:0] fit = (vbits >= w4) ? 3'd4 :
                     (vbits >= w3) ? 3'd3 :
                     (vbits >= w2) ? 3'd2 :
                     (vbits >= w1) ? 3'd1 : 3'd0;
    wire [2:0] rem_cap = (remaining_q >= 16'd4) ? 3'd4 : remaining_q[2:0];
    wire [2:0] take    = (fit < rem_cap) ? fit : rem_cap;   // min(fit, min(remaining,4))
    wire [8:0] pop_run = {6'b0, take} * {3'b0, width_q};
    wire       last_grp = (remaining_q <= {13'b0, take});

    bpd_extract #(.LANES(LANES), .DATA_W(DATA_W), .WINW(WINW)) u_extract (
        .window(window), .width(width_q), .res_flat(res_flat)
    );
    bpd_decode #(.LANES(LANES), .DATA_W(DATA_W)) u_decode (
        .res_flat(res_flat), .take(take), .carry_in(carry_q),
        .val_flat(val_flat), .carry_out(carry_out)
    );

    // pad (bits to next 32-bit boundary after the payload)
    wire [5:0] pad_full = 6'd32 - {1'b0, paybits_q[4:0]};
    wire [4:0] pad_bits = pad_full[4:0];

    // ---------------- egress register ----------------
    reg  [LANES*DATA_W-1:0] e_data;
    reg  [2:0]              e_cnt;
    reg                     e_last, e_valid;
    wire slot_free = ~e_valid | m_axis_tready;

    assign m_axis_tdata  = e_data;
    assign m_axis_tcnt   = e_cnt;
    assign m_axis_tlast  = e_last;
    assign m_axis_tvalid = e_valid;

    // ---------------- FSM ----------------
    localparam [2:0] S_IDLE=3'd0, S_HDR0=3'd1, S_HDR1=3'd2,
                     S_RUN=3'd3,  S_PAD=3'd4,  S_DONE=3'd5, S_ERR=3'd6;
    reg [2:0] state;
    assign busy = (state != S_IDLE);

    wire [31:0] hdr1     = window[31:0];
    wire [5:0]  hdr_w    = hdr1[31:26];
    wire [15:0] hdr_cnt  = hdr1[15:0];

    // group commit fires when there is an egress slot and at least one field
    wire run_commit = (state == S_RUN) & slot_free & (take != 3'd0);

    assign rd_flush = (state == S_ERR);

    // ---- combinational bit-consume (aligned with the sampling cycle) ----
    always @(*) begin
        pop_en   = 1'b0;
        pop_bits = 9'd0;
        case (state)
            S_HDR0: if (vbits >= 9'd32) begin pop_en = 1'b1; pop_bits = 9'd32; end
            S_HDR1: if (vbits >= 9'd32) begin pop_en = 1'b1; pop_bits = 9'd32; end
            S_RUN:  if (run_commit & (pop_run != 9'd0)) begin pop_en = 1'b1; pop_bits = pop_run; end
            S_PAD:  if (pad_bits != 5'd0) begin pop_en = 1'b1; pop_bits = {4'b0, pad_bits}; end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        if (core_rst) begin
            state       <= S_IDLE;
            width_q     <= 6'd0;  remaining_q <= 16'd0; carry_q <= 32'd0;
            paybits_q   <= 21'd0;
            e_valid     <= 1'b0;  e_data <= {LANES*DATA_W{1'b0}}; e_cnt <= 3'd0; e_last <= 1'b0;
            blocks_q    <= 32'd0; values_q <= 32'd0; cycles_q <= 32'd0;
            done_pulse  <= 1'b0;  err_pulse <= 1'b0; errcode <= 32'd0;
        end else begin
            // defaults (single-cycle strobes)
            done_pulse <= 1'b0;
            err_pulse  <= 1'b0;

            // egress advance: clear when accepted and not reloaded below
            if (e_valid & m_axis_tready)
                e_valid <= 1'b0;

            if (busy) cycles_q <= cycles_q + 32'd1;

            case (state)
                // --------------------------------------------------------
                S_IDLE: begin
                    if (en & (vbits >= 9'd32))
                        state <= S_HDR0;
                end
                // --------------------------------------------------------
                S_HDR0: begin                       // read base
                    if (vbits >= 9'd32) begin
                        carry_q  <= window[31:0];   // v[-1] = base
                        state    <= S_HDR1;
                    end
                end
                // --------------------------------------------------------
                S_HDR1: begin                       // read {width,count}
                    if (vbits >= 9'd32) begin
                        width_q     <= hdr_w;
                        remaining_q <= hdr_cnt;
                        paybits_q   <= 21'd0;
                        if (hdr_cnt == 16'd0) begin
                            errcode <= 32'd1;        // empty block
                            state   <= S_ERR;
                        end else if (hdr_w > 6'd32) begin
                            errcode <= 32'd2;        // illegal width
                            state   <= S_ERR;
                        end else begin
                            state   <= S_RUN;
                        end
                    end
                end
                // --------------------------------------------------------
                S_RUN: begin
                    // emit one group when we have fields and an egress slot
                    if (slot_free & (take != 3'd0)) begin
                        e_valid <= 1'b1;
                        e_data  <= val_flat;
                        e_cnt   <= take;
                        e_last  <= last_grp;
                        carry_q <= carry_out;
                        values_q <= values_q + {29'b0, take};
                        // packed bits are consumed combinationally (pop_run);
                        // paybits tracks total payload bits for the pad calc
                        paybits_q   <= paybits_q + {12'b0, pop_run};
                        remaining_q <= remaining_q - {13'b0, take};
                        if (last_grp)
                            state <= S_PAD;
                    end
                end
                // --------------------------------------------------------
                S_PAD: begin                        // realign to word boundary
                    // pad bits consumed combinationally (pop_bits = pad_bits)
                    state <= S_DONE;
                end
                // --------------------------------------------------------
                S_DONE: begin
                    blocks_q   <= blocks_q + 32'd1;
                    done_pulse <= 1'b1;
                    state      <= S_IDLE;
                end
                // --------------------------------------------------------
                S_ERR: begin                        // rd_flush asserted combinationally
                    err_pulse <= 1'b1;
                    state     <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
