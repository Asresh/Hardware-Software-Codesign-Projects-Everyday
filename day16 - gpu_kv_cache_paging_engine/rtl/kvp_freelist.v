// ============================================================================
// kvp_freelist.v - physical KV-block allocator: a LIFO stack of free blocks.
//
//   The host seeds the pool by writing physical block numbers to the FREE_PUSH
//   register; the engine pops one whenever a sequence grows into an unmapped
//   logical block, and pushes blocks back when a sequence is freed.  LIFO (not
//   FIFO) is deliberate: the block just released is the block reused next, which
//   is what keeps a serving engine's working set hot - and it makes allocation
//   order a pure function of the request stream, so the golden model can predict
//   every physical block number bit-exactly.
//
//   `top_blk` is a combinational read of the stack top, so a pop and the
//   dependent block-table write can be issued in the same cycle.
// ============================================================================
`default_nettype none

module kvp_freelist #(
    parameter integer DEPTH  = 512,
    parameter integer PHYS_W = 24
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clear,        // soft reset: drop the whole pool

    input  wire              push_en,
    input  wire [PHYS_W-1:0] push_blk,
    input  wire              pop_en,

    output wire [PHYS_W-1:0] top_blk,
    output wire              empty,
    output wire              full,
    output wire [31:0]       count
);
    localparam integer SP_W = (DEPTH <=   16) ? 5  :
                             (DEPTH <=   64) ? 7  :
                             (DEPTH <=  256) ? 9  :
                             (DEPTH <= 1024) ? 11 : 13;

    reg [PHYS_W-1:0] stk [0:DEPTH-1];
    reg [SP_W-1:0]   sp;                  // number of blocks held

    assign empty   = (sp == {SP_W{1'b0}});
    assign full    = (sp == DEPTH[SP_W-1:0]);
    assign count   = {{(32-SP_W){1'b0}}, sp};
    assign top_blk = empty ? {PHYS_W{1'b0}} : stk[sp - 1'b1];

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            sp <= {SP_W{1'b0}};
        end else if (push_en && !full) begin
            stk[sp] <= push_blk;
            sp      <= sp + 1'b1;
        end else if (pop_en && !empty) begin
            sp <= sp - 1'b1;
        end
    end
endmodule

`default_nettype wire
