// Author: Asresh
module kmer_revcomp #(parameter BASES=16) (
    input  wire [2*BASES-1:0] kmer,
    output reg  [2*BASES-1:0] revcomp
);
    integer i;
    always @* begin
        revcomp = {2*BASES{1'b0}};
        for (i=0; i<BASES; i=i+1)
            revcomp[2*i +: 2] = ~kmer[2*(BASES-1-i) +: 2];
    end
endmodule
