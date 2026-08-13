// ===========================================================================
// mxq_regfile - 32 x 32, two combinational read ports, one write port.
//
// x0 is forced to zero on read rather than special-cased on write, so a write
// to x0 is harmless and needs no decode.  There is no read-during-write
// bypass here: the write happens at the end of the same cycle the consumer
// reads in, so the bypass lives in the core where the writeback value is
// already selected.  x10 is exported continuously because the host reads it
// back as the program's return value after the halt.
// ===========================================================================
module mxq_regfile (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [4:0]  ra1,
    input  wire [4:0]  ra2,
    output wire [31:0] rd1,
    output wire [31:0] rd2,
    input  wire        we,
    input  wire [4:0]  wa,
    input  wire [31:0] wd,
    input  wire        arg_we,          // host-loaded a0..a3 at launch
    input  wire [31:0] arg0,
    input  wire [31:0] arg1,
    input  wire [31:0] arg2,
    input  wire [31:0] arg3,
    output wire [31:0] x10
);
    reg [31:0] x [0:31];
    integer i;

    assign rd1 = (ra1 == 5'd0) ? 32'd0 : x[ra1];
    assign rd2 = (ra2 == 5'd0) ? 32'd0 : x[ra2];
    assign x10 = x[10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) x[i] <= 32'd0;
        end else if (arg_we) begin
            for (i = 0; i < 32; i = i + 1) x[i] <= 32'd0;
            x[10] <= arg0;
            x[11] <= arg1;
            x[12] <= arg2;
            x[13] <= arg3;
        end else if (we) begin
            x[wa] <= wd;
        end
    end
endmodule
