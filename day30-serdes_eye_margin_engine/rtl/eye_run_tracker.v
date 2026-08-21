// Author: Asresh
module eye_run_tracker #(
    parameter PHASE_W = 7,
    parameter COUNT_W = 9
) (
    input wire clk, input wire rst_n, input wire clear,
    input wire sample_valid, output wire sample_ready,
    input wire [PHASE_W-1:0] sample_phase, input wire sample_open, input wire sample_last,
    output reg done, output reg [PHASE_W-1:0] best_start,
    output reg [COUNT_W-1:0] best_length, output reg [COUNT_W-1:0] sample_count
);
    reg [PHASE_W-1:0] run_start;
    reg [COUNT_W-1:0] run_length;
    reg [COUNT_W-1:0] candidate_length;
    reg [PHASE_W-1:0] candidate_start;
    assign sample_ready = !done;
    always @* begin
        candidate_length = sample_open ? (run_length + 1'b1) : {COUNT_W{1'b0}};
        candidate_start = (sample_open && run_length == 0) ? sample_phase : run_start;
    end
    always @(posedge clk) begin
        if (!rst_n || clear) begin
            run_start <= 0; run_length <= 0; best_start <= 0;
            best_length <= 0; sample_count <= 0; done <= 0;
        end else if (sample_valid && sample_ready) begin
            sample_count <= sample_count + 1'b1;
            if (sample_open) begin
                run_start <= candidate_start;
                run_length <= candidate_length;
                if (candidate_length > best_length) begin
                    best_start <= candidate_start;
                    best_length <= candidate_length;
                end
            end else run_length <= 0;
            if (sample_last) done <= 1'b1;
        end
    end
endmodule
