// Author: Asresh
// Three-stage, globally-stalled SIMD correlation pipeline with lossless output.
module preamble_correlator_core #(
    parameter LANES = 8,
    parameter W = 8,
    parameter SUM_W = (2*W)+4
) (
    input clk,
    input rst_n,
    input enabled,
    input [40:0] threshold,
    input [(LANES*W)-1:0] tap_i_flat,
    input [(LANES*W)-1:0] tap_q_flat,
    input [(LANES*2*W)-1:0] s_data,
    input [15:0] s_tag,
    input s_last,
    input s_valid,
    output s_ready,
    output [63:0] m_data,
    output m_last,
    output m_valid,
    input m_ready
);
    localparam PW = (2*W)+1;
    wire signed [(LANES*PW)-1:0] prod_i_flat;
    wire signed [(LANES*PW)-1:0] prod_q_flat;
    wire signed [SUM_W-1:0] reduce_i;
    wire signed [SUM_W-1:0] reduce_q;
    wire [40:0] mag_comb;
    reg signed [SUM_W-1:0] sum_i_r, sum_q_r;
    reg [40:0] mag_r;
    reg [40:0] power_r;
    reg [15:0] tag1, tag2, tag3;
    reg last1, last2, last3;
    reg v1, v2, v3;
    reg detected_r;
    wire advance = !v3 || m_ready;
    wire take = s_valid && s_ready;

    generate
        genvar g;
        for (g = 0; g < LANES; g = g + 1) begin : LANES_GEN
            complex_mac_lane #(.W(W)) lane (
                .sample_i(s_data[(g*2*W)+:W]),
                .sample_q(s_data[(g*2*W)+W+:W]),
                .tap_i(tap_i_flat[(g*W)+:W]),
                .tap_q(tap_q_flat[(g*W)+:W]),
                .product_i(prod_i_flat[(g*PW)+:PW]),
                .product_q(prod_q_flat[(g*PW)+:PW])
            );
        end
    endgenerate
    correlation_reduce #(.IW(PW), .OW(SUM_W)) reduce (
        .lane_i(prod_i_flat), .lane_q(prod_q_flat),
        .sum_i(reduce_i), .sum_q(reduce_q)
    );
    magnitude_square #(.W(SUM_W)) magnitude (
        .value_i(sum_i_r), .value_q(sum_q_r), .magnitude(mag_comb)
    );

    assign s_ready = enabled && advance;
    assign m_valid = v3;
    assign m_last = last3;
    assign m_data = {6'd0, detected_r, tag3, power_r};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 0; v2 <= 0; v3 <= 0;
            sum_i_r <= 0; sum_q_r <= 0; mag_r <= 0; power_r <= 0;
            tag1 <= 0; tag2 <= 0; tag3 <= 0;
            last1 <= 0; last2 <= 0; last3 <= 0;
            detected_r <= 0;
        end else if (advance) begin
            v3 <= v2;
            if (v2) begin
                power_r <= mag_r;
                detected_r <= (mag_r >= threshold);
                tag3 <= tag2;
                last3 <= last2;
            end
            v2 <= v1;
            if (v1) begin
                mag_r <= mag_comb;
                tag2 <= tag1;
                last2 <= last1;
            end
            v1 <= take;
            if (take) begin
                sum_i_r <= reduce_i;
                sum_q_r <= reduce_q;
                tag1 <= s_tag;
                last1 <= s_last;
            end
        end
    end
endmodule
