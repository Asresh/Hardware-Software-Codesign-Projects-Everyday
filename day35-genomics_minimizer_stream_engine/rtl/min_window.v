// Author: Asresh
module min_window #(parameter WIDTH=32, parameter WINDOW=8) (
    input wire clk, input wire rst_n, input wire clear, input wire push,
    input wire [WIDTH-1:0] value, input wire [31:0] position,
    output reg valid, output reg [WIDTH-1:0] min_value, output reg [31:0] min_position
);
    reg [WIDTH-1:0] values [0:WINDOW-1];
    reg [31:0] positions [0:WINDOW-1];
    integer count, i;
    reg [WIDTH-1:0] best;
    reg [31:0] best_pos;
    always @* begin
        valid = push && (count + 1 >= WINDOW);
        min_value = value; min_position = position;
        for (i=0;i<WINDOW-1;i=i+1)
            if ((i < count) && ((values[i] < min_value) || ((values[i] == min_value) && (positions[i] < min_position)))) begin
                min_value = values[i]; min_position = positions[i];
            end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            count <= 0;
            for (i=0;i<WINDOW;i=i+1) begin values[i] <= 0; positions[i] <= 0; end
        end else if (clear) begin
            count <= push ? 1 : 0;
            for (i=0;i<WINDOW;i=i+1) begin values[i] <= 0; positions[i] <= 0; end
            if (push) begin values[0] <= value; positions[0] <= position; end
        end else if (push) begin
            for (i=WINDOW-1;i>0;i=i-1) begin values[i] <= values[i-1]; positions[i] <= positions[i-1]; end
            values[0] <= value; positions[0] <= position;
            if (count < WINDOW) count <= count + 1;
        end
    end
endmodule
