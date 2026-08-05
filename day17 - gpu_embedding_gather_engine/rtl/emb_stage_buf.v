// ============================================================================
// emb_stage_buf - the ping-pong row-staging store.
//
// Two independent buffers, each holding one whole embedding row as CHUNKS beats
// of LANES*32 bits.  One buffer is being filled by the memory gather while the
// other is being folded into the accumulator, so the fetch latency of row i+1 is
// hidden behind the reduction of row i.  That overlap is the whole point of the
// architecture, and it is why the engine sustains close to LANES words/clock
// instead of half that.
//
// Distributed-RAM style: the write port is synchronous, the read port is
// asynchronous, so the reduce lanes see a chunk in the same cycle they address
// it and one row-chunk folds per clock with no read-latency bubble.
// ============================================================================
module emb_stage_buf #(
    parameter LANES  = 4,
    parameter CHUNKS = 16,
    parameter CW     = 4        // bits needed to index a chunk
) (
    input  wire                  clk,

    // fill port (memory side)
    input  wire                  wr_en,
    input  wire                  wr_buf,
    input  wire [CW-1:0]         wr_chunk,
    input  wire [LANES*32-1:0]   wr_data,

    // drain port (reduce side)
    input  wire                  rd_buf,
    input  wire [CW-1:0]         rd_chunk,
    output wire [LANES*32-1:0]   rd_data
);
    reg [LANES*32-1:0] mem0 [0:CHUNKS-1];
    reg [LANES*32-1:0] mem1 [0:CHUNKS-1];

    always @(posedge clk) begin
        if (wr_en) begin
            if (wr_buf) mem1[wr_chunk] <= wr_data;
            else        mem0[wr_chunk] <= wr_data;
        end
    end

    assign rd_data = rd_buf ? mem1[rd_chunk] : mem0[rd_chunk];
endmodule
