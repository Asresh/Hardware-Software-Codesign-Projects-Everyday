// Author: Asresh
// Three-stage elastic datapath: extract physical features, multiply all three
// weights in parallel, then reduce and attach the threshold-alert bit. A single
// advance gate freezes every stage under output backpressure without reordering.
module ptf_pipeline (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [31:0] in_sample,
    input  wire [11:0] nominal_mv,
    input  wire signed [7:0] temperature_limit,
    input  wire [7:0]  droop_weight,
    input  wire [7:0]  current_weight,
    input  wire [7:0]  thermal_weight,
    input  wire [30:0] alert_threshold,
    output wire        out_valid,
    input  wire        out_ready,
    output wire [31:0] out_result
);
    reg v1, v2, v3;
    reg [11:0] s1_droop, s1_current;
    reg [7:0] s1_hot;
    reg [7:0] s1_wd, s1_wi, s1_wt;
    reg [30:0] s1_threshold;
    reg [19:0] s2_droop_term, s2_current_term;
    reg [15:0] s2_thermal_term;
    reg [30:0] s2_threshold;
    reg [31:0] s3_result;
    wire advance;
    wire [11:0] sample_voltage = in_sample[11:0];
    wire [11:0] sample_current = in_sample[23:12];
    wire signed [7:0] sample_temperature = in_sample[31:24];
    wire [11:0] feature_droop = sample_voltage < nominal_mv ?
                                nominal_mv - sample_voltage : 12'd0;
    wire [7:0] feature_hot = sample_temperature > temperature_limit ?
                             sample_temperature - temperature_limit : 8'd0;
    wire [31:0] sum_terms = {12'd0, s2_droop_term} +
                            {12'd0, s2_current_term} +
                            {16'd0, s2_thermal_term};
    wire [30:0] bounded_risk = sum_terms[31] ? 31'h7fffffff : sum_terms[30:0];

    assign advance = !v3 || out_ready;
    assign in_ready = advance;
    assign out_valid = v3;
    assign out_result = s3_result;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0;
            v2 <= 1'b0;
            v3 <= 1'b0;
            s1_droop <= 12'd0;
            s1_current <= 12'd0;
            s1_hot <= 8'd0;
            s1_wd <= 8'd0;
            s1_wi <= 8'd0;
            s1_wt <= 8'd0;
            s1_threshold <= 31'd0;
            s2_droop_term <= 20'd0;
            s2_current_term <= 20'd0;
            s2_thermal_term <= 16'd0;
            s2_threshold <= 31'd0;
            s3_result <= 32'd0;
        end else if (advance) begin
            v3 <= v2;
            v2 <= v1;
            v1 <= in_valid;
            if (in_valid) begin
                s1_droop <= feature_droop;
                s1_current <= sample_current;
                s1_hot <= feature_hot;
                s1_wd <= droop_weight;
                s1_wi <= current_weight;
                s1_wt <= thermal_weight;
                s1_threshold <= alert_threshold;
            end
            if (v1) begin
                s2_droop_term <= s1_droop * s1_wd;
                s2_current_term <= s1_current * s1_wi;
                s2_thermal_term <= s1_hot * s1_wt;
                s2_threshold <= s1_threshold;
            end
            if (v2)
                s3_result <= {(bounded_risk >= s2_threshold), bounded_risk};
        end
    end
endmodule
