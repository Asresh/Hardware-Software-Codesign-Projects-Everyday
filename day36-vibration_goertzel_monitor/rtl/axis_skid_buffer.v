// Author: Asresh
`timescale 1ns/1ps
module axis_skid_buffer #(
    parameter WIDTH = 12
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire [WIDTH-1:0]     s_data,
    input  wire                 s_last,
    input  wire                 s_valid,
    output wire                 s_ready,
    output wire [WIDTH-1:0]     m_data,
    output wire                 m_last,
    output wire                 m_valid,
    input  wire                 m_ready
);
    reg [WIDTH-1:0] data_q;
    reg last_q;
    reg valid_q;

    assign s_ready = ~valid_q | m_ready;
    assign m_data = data_q;
    assign m_last = last_q;
    assign m_valid = valid_q;

    always @(posedge clk) begin
        if (rst) begin
            valid_q <= 1'b0;
            data_q <= {WIDTH{1'b0}};
            last_q <= 1'b0;
        end else if (s_ready) begin
            valid_q <= s_valid;
            if (s_valid) begin
                data_q <= s_data;
                last_q <= s_last;
            end
        end
    end
endmodule
