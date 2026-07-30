// -----------------------------------------------------------------------------
// sync_fifo.v
// Parameterized synchronous FIFO with first-word-fall-through (FWFT) read and a
// valid/ready handshake on both ports. Used for the input and output stream
// buffers of the FIR accelerator; it is the element that turns a momentary
// downstream stall into clean end-to-end backpressure.
//
//   Write side : wr_valid / wr_ready / wr_data   (wr_ready == !full)
//   Read  side : rd_valid / rd_ready / rd_data   (rd_valid == !empty)
//
// A transfer occurs on a port in any cycle where its valid & ready are both 1.
// A synchronous `flush` empties the FIFO in one cycle (used at job boundaries).
//
// DEPTH must be a power of two; the pointers are (ADDR_W+1) bits so that a full
// and an empty FIFO are distinguished by the MSB rather than an extra counter.
// -----------------------------------------------------------------------------
`default_nettype none

module sync_fifo #(
    parameter integer WIDTH = 16,
    parameter integer DEPTH = 16          // must be a power of two, >= 2
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 flush,

    // write (producer) side
    input  wire                 wr_valid,
    output wire                 wr_ready,
    input  wire [WIDTH-1:0]     wr_data,

    // read (consumer) side, first-word-fall-through
    output wire                 rd_valid,
    input  wire                 rd_ready,
    output wire [WIDTH-1:0]     rd_data,

    // occupancy, for status/telemetry (zero-extended into a fixed field)
    output wire [31:0]          level
);
    localparam integer ADDR_W = $clog2(DEPTH);

    reg  [WIDTH-1:0] mem [0:DEPTH-1];
    reg  [ADDR_W:0]  wr_ptr;   // one extra MSB to disambiguate full vs empty
    reg  [ADDR_W:0]  rd_ptr;

    wire full  = (wr_ptr[ADDR_W]     != rd_ptr[ADDR_W]) &&
                 (wr_ptr[ADDR_W-1:0] == rd_ptr[ADDR_W-1:0]);
    wire empty = (wr_ptr == rd_ptr);

    assign wr_ready = !full;
    assign rd_valid = !empty;

    wire do_wr = wr_valid & wr_ready;
    wire do_rd = rd_valid & rd_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {(ADDR_W+1){1'b0}};
        end else if (flush) begin
            wr_ptr <= {(ADDR_W+1){1'b0}};
        end else if (do_wr) begin
            mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr <= {(ADDR_W+1){1'b0}};
        end else if (flush) begin
            rd_ptr <= {(ADDR_W+1){1'b0}};
        end else if (do_rd) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    assign rd_data = mem[rd_ptr[ADDR_W-1:0]];
    assign level   = wr_ptr - rd_ptr;

`ifdef FORMAL_OR_SIM_ASSERT
    // sanity: level never exceeds DEPTH
    always @(posedge clk) if (rst_n) begin
        if (level > DEPTH) $error("sync_fifo: level %0d exceeds DEPTH %0d", level, DEPTH);
    end
`endif
endmodule

`default_nettype wire
