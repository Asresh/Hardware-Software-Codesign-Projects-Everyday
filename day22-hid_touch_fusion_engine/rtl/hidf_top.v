module hidf_top #(
    parameter CHANNELS = 8,
    parameter SAMPLE_W = 16,
    parameter SUM_W = 20
) (
    input  wire clk,
    input  wire rst_n,
    input  wire spi_sclk,
    input  wire spi_cs_n,
    input  wire spi_mosi,
    output wire spi_miso,
    output reg  irq
);
    localparam CMD_CONFIG = 8'h01, CMD_FRAME = 8'h10;
    localparam CMD_STATUS = 8'h20, CMD_RESULT = 8'h21;
    wire [7:0] rx_byte;
    wire rx_valid;
    reg [7:0] tx_byte;
    reg tx_load;
    reg [7:0] command;
    reg [5:0] index;
    reg [15:0] baseline;
    reg [SUM_W-1:0] threshold;
    reg [CHANNELS*SAMPLE_W-1:0] samples;
    reg core_start;
    wire [9:0] core_x, core_y;
    wire [SUM_W-1:0] core_pressure;
    wire core_touched, core_busy, core_done;
    wire [15:0] core_latency;
    reg result_valid;
    reg [71:0] result_shift;

    hidf_spi_phy phy (.clk(clk), .rst_n(rst_n), .spi_sclk(spi_sclk),
        .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .rx_byte(rx_byte), .rx_valid(rx_valid), .tx_byte(tx_byte), .tx_load(tx_load));
    hidf_fusion_core #(.CHANNELS(CHANNELS), .SAMPLE_W(SAMPLE_W), .SUM_W(SUM_W)) core (
        .clk(clk), .rst_n(rst_n), .start(core_start), .samples(samples),
        .baseline(baseline), .threshold(threshold), .x(core_x), .y(core_y),
        .pressure(core_pressure), .touched(core_touched), .busy(core_busy),
        .done(core_done), .latency_cycles(core_latency));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_byte <= 0; tx_load <= 0; command <= 0; index <= 0;
            baseline <= 100; threshold <= 80; samples <= 0; core_start <= 0;
            irq <= 0; result_valid <= 0; result_shift <= 0;
        end else begin
            tx_load <= 1'b0;
            core_start <= 1'b0;
            if (spi_cs_n) begin command <= 0; index <= 0; end
            if (core_done) begin
                irq <= 1'b1;
                result_valid <= 1'b1;
                result_shift <= {6'b0, core_x, 6'b0, core_y, 12'b0, core_pressure,
                                 7'b0, core_touched};
            end
            if (rx_valid) begin
                if (command == 0) begin
                    command <= rx_byte;
                    index <= 0;
                    if (rx_byte == CMD_STATUS) begin
                        tx_byte <= {6'b0, result_valid, core_busy}; tx_load <= 1'b1;
                    end else if (rx_byte == CMD_RESULT) begin
                        tx_byte <= result_shift[71:64]; tx_load <= 1'b1;
                    end
                end else begin
                    index <= index + 1'b1;
                    if (command == CMD_CONFIG) begin
                        if (index == 0) baseline[15:8] <= rx_byte;
                        else if (index == 1) baseline[7:0] <= rx_byte;
                        else if (index == 2) threshold[19:16] <= rx_byte[3:0];
                        else if (index == 3) threshold[15:8] <= rx_byte;
                        else if (index == 4) threshold[7:0] <= rx_byte;
                    end else if (command == CMD_FRAME) begin
                        if (!index[0]) samples[(index/2)*16+8 +: 8] <= rx_byte;
                        else begin
                            samples[(index/2)*16 +: 8] <= rx_byte;
                            if (index == 15) begin
                                core_start <= 1'b1;
                                irq <= 1'b0;
                                result_valid <= 1'b0;
                            end
                        end
                    end else if (command == CMD_STATUS) begin
                        tx_byte <= {6'b0, result_valid, core_busy}; tx_load <= 1'b1;
                    end else if (command == CMD_RESULT) begin
                        result_shift <= {result_shift[63:0], 8'b0};
                        tx_byte <= result_shift[63:56]; tx_load <= 1'b1;
                        if (index == 8) begin result_valid <= 1'b0; irq <= 1'b0; end
                    end
                end
            end
        end
    end
endmodule
