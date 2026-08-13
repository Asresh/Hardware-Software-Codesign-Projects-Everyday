module hidf_fusion_core #(
    parameter CHANNELS = 8,
    parameter SAMPLE_W = 16,
    parameter SUM_W = 20
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [CHANNELS*SAMPLE_W-1:0] samples,
    input  wire [SAMPLE_W-1:0] baseline,
    input  wire [SUM_W-1:0] threshold,
    output reg  [9:0] x,
    output reg  [9:0] y,
    output reg  [SUM_W-1:0] pressure,
    output reg  touched,
    output reg  busy,
    output reg  done,
    output reg  [15:0] latency_cycles
);
    wire [SUM_W-1:0] total_w, right_w, bottom_w;
    reg [31:0] x_num, y_num, denominator;
    reg div_start;
    wire [31:0] x_q, y_q;
    wire x_done, y_done, x_busy, y_busy;

    hidf_preprocess #(.CHANNELS(CHANNELS), .SAMPLE_W(SAMPLE_W), .SUM_W(SUM_W)) prep (
        .samples(samples), .baseline(baseline), .total(total_w),
        .right_sum(right_w), .bottom_sum(bottom_w));
    hidf_udiv #(.WIDTH(32)) div_x (.clk(clk), .rst_n(rst_n), .start(div_start),
        .numerator(x_num), .denominator(denominator), .quotient(x_q),
        .busy(x_busy), .done(x_done));
    hidf_udiv #(.WIDTH(32)) div_y (.clk(clk), .rst_n(rst_n), .start(div_start),
        .numerator(y_num), .denominator(denominator), .quotient(y_q),
        .busy(y_busy), .done(y_done));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 512; y <= 512; pressure <= 0; touched <= 0; busy <= 0;
            done <= 0; latency_cycles <= 0; x_num <= 0; y_num <= 0;
            denominator <= 1; div_start <= 0;
        end else begin
            done <= 1'b0;
            div_start <= 1'b0;
            if (start && !busy) begin
                pressure <= total_w;
                touched <= (total_w >= threshold) && (total_w != 0);
                latency_cycles <= 1;
                if ((total_w >= threshold) && (total_w != 0)) begin
                    x_num <= right_w * 10'd1023;
                    y_num <= bottom_w * 10'd1023;
                    denominator <= total_w;
                    busy <= 1'b1;
                    div_start <= 1'b1;
                end else begin
                    x <= 512; y <= 512; busy <= 1'b0; done <= 1'b1;
                end
            end else if (busy) begin
                latency_cycles <= latency_cycles + 1'b1;
                if (x_done && y_done) begin
                    x <= x_q[9:0];
                    y <= y_q[9:0];
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
