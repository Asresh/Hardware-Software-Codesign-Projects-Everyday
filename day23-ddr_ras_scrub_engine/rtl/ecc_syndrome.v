// Author: Asresh
// Parallel SECDED syndrome tree for a 39-bit shortened Hamming code.
module ecc_syndrome(input wire [38:0] code_i, output reg [5:0] syndrome_o, output reg overall_odd_o);
    integer p;
    always @* begin
        syndrome_o = 6'd0; overall_odd_o = 1'b0;
        for (p = 1; p <= 38; p = p + 1) begin
            if (code_i[p-1]) syndrome_o = syndrome_o ^ p[5:0];
            overall_odd_o = overall_odd_o ^ code_i[p-1];
        end
        overall_odd_o = overall_odd_o ^ code_i[38];
    end
endmodule
