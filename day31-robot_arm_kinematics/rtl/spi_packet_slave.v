// Author: Asresh
`timescale 1ns/1ps
module spi_packet_slave (
    input wire clk, input wire rst,
    input wire spi_sclk, input wire spi_cs_n, input wire spi_mosi, output wire spi_miso,
    output reg rx_valid, output reg [39:0] rx_word,
    input wire tx_load, input wire [39:0] tx_word
);
    reg sclk_d, cs_d;
    reg [39:0] rx_shift, tx_shift, tx_pending;
    reg [5:0] bit_count;
    wire sclk_rise = spi_sclk && !sclk_d;
    wire sclk_fall = !spi_sclk && sclk_d;
    assign spi_miso = tx_shift[39];
    always @(posedge clk) begin
        if (rst) begin
            sclk_d<=0; cs_d<=1; rx_shift<=0; tx_shift<=0; tx_pending<=0; bit_count<=0; rx_valid<=0; rx_word<=0;
        end else begin
            sclk_d <= spi_sclk; cs_d <= spi_cs_n; rx_valid <= 0;
            if (tx_load) tx_pending <= tx_word;
            if (cs_d && !spi_cs_n) begin tx_shift <= tx_pending; rx_shift <= 0; bit_count <= 0; end
            if (!spi_cs_n && sclk_rise) begin
                rx_shift <= {rx_shift[38:0], spi_mosi};
                if (bit_count == 39) begin rx_word <= {rx_shift[38:0], spi_mosi}; rx_valid <= 1; end
                else bit_count <= bit_count + 1'b1;
            end
            if (!spi_cs_n && sclk_fall) tx_shift <= {tx_shift[38:0], 1'b0};
        end
    end
endmodule
