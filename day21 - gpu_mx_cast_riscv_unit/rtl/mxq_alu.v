// ===========================================================================
// mxq_alu - the base integer ALU and the branch comparator.
//
// op[3] is the "alternate" bit the encoding already carries (funct7[5]), so
// SUB and SRA cost a mux rather than a decode.  The branch comparator is
// separate from the ALU result because the two are needed in the same cycle:
// one decides the writeback, the other decides the next PC.
// ===========================================================================
module mxq_alu (
    input  wire [3:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y,
    input  wire [2:0]  br_f3,
    output reg         br_take
);
    localparam ADD = 4'b0000, SLL = 4'b0001, SLT = 4'b0010, SLTU = 4'b0011,
               XOR = 4'b0100, SRL = 4'b0101, OR_ = 4'b0110, AND_ = 4'b0111,
               SUB = 4'b1000, SRA = 4'b1101, PASSB = 4'b1111;

    wire signed [31:0] as = a;
    wire signed [31:0] bs = b;
    wire        [4:0]  sh = b[4:0];

    always @* begin
        case (op)
            ADD:   y = a + b;
            SUB:   y = a - b;
            SLL:   y = a << sh;
            SLT:   y = (as < bs)  ? 32'd1 : 32'd0;
            SLTU:  y = (a  < b)   ? 32'd1 : 32'd0;
            XOR:   y = a ^ b;
            SRL:   y = a >> sh;
            SRA:   y = as >>> sh;
            OR_:   y = a | b;
            AND_:  y = a & b;
            PASSB: y = b;
            default: y = 32'd0;
        endcase
    end

    always @* begin
        case (br_f3)
            3'b000: br_take = (a == b);
            3'b001: br_take = (a != b);
            3'b100: br_take = (as <  bs);
            3'b101: br_take = (as >= bs);
            3'b110: br_take = (a  <  b);
            3'b111: br_take = (a  >= b);
            default: br_take = 1'b0;
        endcase
    end
endmodule
