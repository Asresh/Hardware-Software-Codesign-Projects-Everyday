// Author: Asresh
// SECDED decision and correction stage; double-bit faults are reported only.
module ecc_correct(input wire [38:0] code_i, input wire [5:0] syndrome_i,
    input wire overall_odd_i, output reg [38:0] code_o,
    output reg corrected_o, output reg uncorrectable_o);
    always @* begin
        code_o = code_i; corrected_o = 1'b0; uncorrectable_o = 1'b0;
        if (overall_odd_i) begin
            corrected_o = 1'b1;
            if (syndrome_i == 0) code_o[38] = ~code_i[38];
            else if (syndrome_i <= 38) code_o[syndrome_i-1] = ~code_i[syndrome_i-1];
            else begin corrected_o = 1'b0; uncorrectable_o = 1'b1; end
        end else if (syndrome_i != 0) uncorrectable_o = 1'b1;
    end
endmodule
