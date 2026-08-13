// ===========================================================================
// mxq_sram - single-port synchronous RAM with byte enables.
//
// One port, shared between the core and the host by time rather than by
// arbitration: the host owns it while the core is halted and the core owns it
// while it runs.  That is not a simplification, it is the contract - a host
// that writes the program while the program is running has a bug, and this
// makes the bug a returned error instead of a race.  Read data appears the
// cycle after the address, which is what sets the pipeline's shape.
// ===========================================================================
module mxq_sram #(
    parameter AW = 12
) (
    input  wire            clk,
    input  wire            en,
    input  wire            we,
    input  wire [3:0]      be,
    input  wire [AW-1:0]   addr,
    input  wire [31:0]     wdata,
    output reg  [31:0]     rdata
);
    reg [31:0] mem [0:(1 << AW) - 1];
    integer i;

    initial begin
        for (i = 0; i < (1 << AW); i = i + 1) mem[i] = 32'd0;
    end

    always @(posedge clk) begin
        if (en) begin
            if (we) begin
                if (be[0]) mem[addr][7:0]   <= wdata[7:0];
                if (be[1]) mem[addr][15:8]  <= wdata[15:8];
                if (be[2]) mem[addr][23:16] <= wdata[23:16];
                if (be[3]) mem[addr][31:24] <= wdata[31:24];
            end else begin
                rdata <= mem[addr];
            end
        end
    end
endmodule
