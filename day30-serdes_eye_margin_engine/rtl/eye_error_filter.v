// Author: Asresh
module eye_error_filter (
    input wire [15:0] error_count,
    input wire [15:0] error_limit,
    output wire is_open
);
    assign is_open = (error_count <= error_limit);
endmodule
