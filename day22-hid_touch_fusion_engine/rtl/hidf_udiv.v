module hidf_udiv #(
    parameter WIDTH = 32
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [WIDTH-1:0] numerator,
    input  wire [WIDTH-1:0] denominator,
    output reg  [WIDTH-1:0] quotient,
    output reg  busy,
    output reg  done
);
    reg [WIDTH-1:0] dividend;
    reg [WIDTH:0] remainder;
    reg [WIDTH-1:0] denom;
    reg [$clog2(WIDTH+1)-1:0] count;
    reg [WIDTH:0] shifted;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quotient <= 0; dividend <= 0; remainder <= 0; denom <= 0;
            count <= 0; busy <= 0; done <= 0; shifted <= 0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                quotient <= 0;
                dividend <= numerator;
                remainder <= 0;
                denom <= denominator;
                count <= WIDTH;
                busy <= 1'b1;
            end else if (busy) begin
                shifted = {remainder[WIDTH-1:0], dividend[WIDTH-1]};
                dividend <= {dividend[WIDTH-2:0], 1'b0};
                if (shifted >= {1'b0, denom}) begin
                    remainder <= shifted - {1'b0, denom};
                    quotient <= {quotient[WIDTH-2:0], 1'b1};
                end else begin
                    remainder <= shifted;
                    quotient <= {quotient[WIDTH-2:0], 1'b0};
                end
                count <= count - 1'b1;
                if (count == 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
