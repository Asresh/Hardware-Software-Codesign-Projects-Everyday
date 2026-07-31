// -----------------------------------------------------------------------------
// sfu_top.v
// GPU-style CORDIC Special Function Unit (top level).
//
//   host --MMIO--> sfu_regfile --descriptor--> sfu_ring_seq
//                                                  |  walks the request ring
//                          rd_master <--gather-----|  in waves of LANES
//                             |  (op,a,b) per lane  |
//                             v                     v
//                   LANES x {sfu_decode + cordic_core}  (iterative SFU lanes)
//                             |  (op,r0,r1) per lane
//                             v
//                          wr_master --scatter--> result ring in device memory
//                                                  |
//                                                  v  completion interrupt
//
// The sequencer consumes function requests from a shared submission ring and
// posts results to a completion ring (GPU pushbuffer style), dispatching each
// wave of LANES requests to a SIMD array of iterative CORDIC lanes. One unified
// shift-and-add datapath evaluates sin/cos, exp, cosh/sinh, atan2/hypot, ln and
// sqrt. Everything is parameterized by LANES / ADDR_WIDTH so the same source
// scales from one lane to a wide SFU pool.
// -----------------------------------------------------------------------------
`default_nettype none

module sfu_top #(
    parameter integer LANES       = 4,
    parameter integer ADDR_WIDTH  = 20,
    parameter integer ENTRY_WORDS = 4,
    parameter         ROMFILE     = "tb/vectors/cordic_rom.hex"
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // MMIO mailbox (slave)
    input  wire                        mmio_sel,
    input  wire                        mmio_write,
    input  wire [7:0]                  mmio_addr,
    input  wire [31:0]                 mmio_wdata,
    output wire [31:0]                 mmio_rdata,

    // request-ring read master (gather)
    output wire                        mem_rd_en,
    output wire [LANES*ADDR_WIDTH-1:0] mem_rd_addr,
    output wire [LANES-1:0]            mem_rd_mask,
    input  wire [LANES*128-1:0]        mem_rd_data,

    // result-ring write master (scatter)
    output wire                        mem_wr_en,
    output wire [LANES*ADDR_WIDTH-1:0] mem_wr_addr,
    output wire [LANES-1:0]            mem_wr_mask,
    output wire [LANES*128-1:0]        mem_wr_data,

    output wire                        irq
);
    // ---- regfile <-> sequencer ----
    wire [31:0] req_base, res_base, ring_cap, req_head, res_head, count;
    wire        start, seq_busy, seq_done_pulse;
    wire [31:0] seq_cycles;

    sfu_regfile #(.LANES(LANES)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .mmio_sel(mmio_sel), .mmio_write(mmio_write), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .req_base(req_base), .res_base(res_base), .ring_cap(ring_cap),
        .req_head(req_head), .res_head(res_head), .count(count), .start(start),
        .seq_busy(seq_busy), .seq_done_pulse(seq_done_pulse),
        .seq_cycles(seq_cycles), .irq(irq)
    );

    // ---- sequencer <-> masters ----
    wire                        rd_beat, wr_beat;
    wire [LANES*ADDR_WIDTH-1:0] rd_addr, wr_addr;
    wire [LANES-1:0]            rd_mask, wr_mask;
    wire [LANES*32-1:0]         req_op, req_a, req_b;
    wire [LANES*32-1:0]         res_op, res_r0, res_r1;

    sfu_ring_seq #(
        .LANES(LANES), .ADDR_WIDTH(ADDR_WIDTH),
        .ENTRY_WORDS(ENTRY_WORDS), .ROMFILE(ROMFILE)
    ) u_seq (
        .clk(clk), .rst_n(rst_n),
        .start(start), .req_base(req_base), .res_base(res_base),
        .ring_cap(ring_cap), .req_head(req_head), .res_head(res_head),
        .count(count),
        .rd_beat(rd_beat), .rd_addr(rd_addr), .rd_mask(rd_mask),
        .req_op(req_op), .req_a(req_a), .req_b(req_b),
        .wr_beat(wr_beat), .wr_addr(wr_addr), .wr_mask(wr_mask),
        .res_op(res_op), .res_r0(res_r0), .res_r1(res_r1),
        .busy(seq_busy), .done_pulse(seq_done_pulse), .cycles(seq_cycles)
    );

    // ---- request-ring read master ----
    rd_master #(.LANES(LANES), .ADDR_WIDTH(ADDR_WIDTH)) u_rd (
        .beat_valid(rd_beat), .lane_addr(rd_addr), .lane_mask(rd_mask),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_mask(mem_rd_mask),
        .mem_rd_data(mem_rd_data),
        .req_op(req_op), .req_a(req_a), .req_b(req_b)
    );

    // ---- result-ring write master ----
    wr_master #(.LANES(LANES), .ADDR_WIDTH(ADDR_WIDTH)) u_wr (
        .beat_valid(wr_beat), .lane_addr(wr_addr), .lane_mask(wr_mask),
        .res_op(res_op), .res_r0(res_r0), .res_r1(res_r1),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr),
        .mem_wr_mask(mem_wr_mask), .mem_wr_data(mem_wr_data)
    );
endmodule

`default_nettype wire
