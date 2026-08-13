module hidf_preprocess #(
    parameter CHANNELS = 8,
    parameter SAMPLE_W = 16,
    parameter SUM_W = 20
) (
    input  wire [CHANNELS*SAMPLE_W-1:0] samples,
    input  wire [SAMPLE_W-1:0] baseline,
    output reg  [SUM_W-1:0] total,
    output reg  [SUM_W-1:0] right_sum,
    output reg  [SUM_W-1:0] bottom_sum
);
    integer i;
    reg [SAMPLE_W-1:0] raw;
    reg [SAMPLE_W:0] corrected;
    always @* begin
        total = {SUM_W{1'b0}};
        right_sum = {SUM_W{1'b0}};
        bottom_sum = {SUM_W{1'b0}};
        raw = {SAMPLE_W{1'b0}};
        corrected = {(SAMPLE_W+1){1'b0}};
        for (i = 0; i < CHANNELS; i = i + 1) begin
            raw = samples[i*SAMPLE_W +: SAMPLE_W];
            corrected = (raw > baseline) ? ({1'b0, raw} - {1'b0, baseline}) : 0;
            total = total + corrected;
            if ((i % 4) == 1 || (i % 4) == 3)
                right_sum = right_sum + corrected;
            if ((i % 4) == 2 || (i % 4) == 3)
                bottom_sum = bottom_sum + corrected;
        end
    end
endmodule
