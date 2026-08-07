// ============================================================================
// p2p_fifo - synchronous show-ahead FIFO.
//
// Used for the transmitter's payload staging buffer, where the point is that
// the read master runs ahead of the link: words fetched from memory land here
// and are drained onto the wire whenever the peer has room. `count` is
// exported because the transmitter reserves space before it issues a read -
// a read whose data has nowhere to go would have to stall the shared memory
// port, and that would let one direction throttle the other.
// ============================================================================
`timescale 1ns/1ps

module p2p_fifo #(
    parameter W     = 32,
    parameter DEPTH = 8         // must be a power of two
) (
    input  wire           clk,
    input  wire           rst_n,
    input  wire           flush,

    input  wire           wr_en,
    input  wire [W-1:0]   wr_data,

    input  wire           rd_en,
    output wire [W-1:0]   rd_data,

    output wire           empty,
    output wire           full,
    output reg  [$clog2(DEPTH):0] count
);

    localparam AW = $clog2(DEPTH);

    reg [W-1:0]  mem [0:DEPTH-1];
    reg [AW-1:0] rptr, wptr;

    assign empty   = (count == 0);
    assign full    = (count == DEPTH);
    assign rd_data = mem[rptr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rptr <= {AW{1'b0}};
            wptr <= {AW{1'b0}};
            count <= {(AW+1){1'b0}};
        end else if (flush) begin
            rptr <= {AW{1'b0}};
            wptr <= {AW{1'b0}};
            count <= {(AW+1){1'b0}};
        end else begin
            if (wr_en && !full) begin
                mem[wptr] <= wr_data;
                wptr      <= wptr + 1'b1;
            end
            if (rd_en && !empty)
                rptr <= rptr + 1'b1;

            case ({wr_en && !full, rd_en && !empty})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule
