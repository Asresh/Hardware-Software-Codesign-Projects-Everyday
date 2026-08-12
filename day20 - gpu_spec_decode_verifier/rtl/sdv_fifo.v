// ===========================================================================
// sdv_fifo.v - small synchronous FIFO between the walk and the egress stream.
//
// Depth is chosen so a whole job's result (MAX_DEPTH accepted tokens plus one
// trailer) fits, and the walk only starts once the FIFO has drained.  That is
// what lets egress backpressure be absorbed without ever stalling the walk:
// once a job starts stepping it runs to completion at one token per clock no
// matter what the downstream link is doing, so the measured walk cycles are a
// property of the tree and not of the consumer.
//
// `ovf` is sticky and is checked in simulation: by construction it can never
// assert, so if it ever does the capacity argument above is wrong.
// ===========================================================================
`default_nettype none

module sdv_fifo #(
    parameter integer W     = 129,
    parameter integer DEPTH = 32,       // power of two
    parameter integer AW    = 5         // clog2(DEPTH)
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          push,
    input  wire [W-1:0]  din,
    input  wire          pop,
    output wire [W-1:0]  dout,
    output wire          empty,
    output wire          full,
    output reg           ovf
);
    reg [W-1:0]  mem [0:DEPTH-1];
    reg [AW:0]   wptr, rptr;

    wire [AW:0] cnt = wptr - rptr;
    assign empty = (wptr == rptr);
    assign full  = (cnt == DEPTH[AW:0]);
    assign dout  = mem[rptr[AW-1:0]];

    always @(posedge clk) begin
        if (!rst_n) begin
            wptr <= 0;
            rptr <= 0;
            ovf  <= 1'b0;
        end else begin
            if (push && !full) begin
                mem[wptr[AW-1:0]] <= din;
                wptr <= wptr + 1'b1;
            end
            if (push && full) ovf <= 1'b1;
            if (pop && !empty) rptr <= rptr + 1'b1;
        end
    end
endmodule
`default_nettype wire
