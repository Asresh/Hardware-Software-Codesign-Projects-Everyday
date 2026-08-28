// Author: Asresh
// Four-beat descriptor fetcher for source address, destination address, sample
// count, and flags. It holds each request until the DMA read channel accepts it.
module ptf_descriptor_reader #(
    parameter ADDR_WIDTH = 16
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    input  wire [ADDR_WIDTH-1:0] base_addr,
    output wire                  mem_valid,
    output wire [ADDR_WIDTH-1:0] mem_addr,
    input  wire                  mem_ready,
    input  wire [31:0]           mem_rdata,
    output reg                   busy,
    output reg                   done,
    output reg  [ADDR_WIDTH-1:0] src_addr,
    output reg  [ADDR_WIDTH-1:0] dst_addr,
    output reg  [15:0]           count,
    output reg  [31:0]           flags
);
    reg [1:0] word_index;

    assign mem_valid = busy;
    assign mem_addr = base_addr + {{(ADDR_WIDTH-4){1'b0}}, word_index, 2'b00};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            word_index <= 2'd0;
            src_addr <= {ADDR_WIDTH{1'b0}};
            dst_addr <= {ADDR_WIDTH{1'b0}};
            count <= 16'd0;
            flags <= 32'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                word_index <= 2'd0;
            end else if (busy && mem_ready) begin
                case (word_index)
                    2'd0: src_addr <= mem_rdata[ADDR_WIDTH-1:0];
                    2'd1: dst_addr <= mem_rdata[ADDR_WIDTH-1:0];
                    2'd2: count <= mem_rdata[15:0];
                    2'd3: flags <= mem_rdata;
                endcase
                if (word_index == 2'd3) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    word_index <= word_index + 2'd1;
                end
            end
        end
    end
endmodule
