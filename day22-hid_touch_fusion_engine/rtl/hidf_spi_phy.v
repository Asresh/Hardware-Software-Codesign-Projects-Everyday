module hidf_spi_phy (
    input  wire clk,
    input  wire rst_n,
    input  wire spi_sclk,
    input  wire spi_cs_n,
    input  wire spi_mosi,
    output wire spi_miso,
    output reg  [7:0] rx_byte,
    output reg  rx_valid,
    input  wire [7:0] tx_byte,
    input  wire tx_load
);
    reg [2:0] sclk_sync;
    reg [1:0] cs_sync;
    reg [1:0] mosi_sync;
    reg [7:0] rx_shift;
    reg [7:0] tx_shift;
    reg [2:0] bit_count;
    reg suppress_fall;
    wire rise = sclk_sync[1] & ~sclk_sync[2];
    wire fall = ~sclk_sync[1] & sclk_sync[2];
    wire selected = ~cs_sync[1];
    assign spi_miso = selected ? tx_shift[7] : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_sync <= 0; cs_sync <= 3; mosi_sync <= 0; rx_shift <= 0;
            tx_shift <= 0; bit_count <= 0; rx_byte <= 0; rx_valid <= 0;
            suppress_fall <= 0;
        end else begin
            sclk_sync <= {sclk_sync[1:0], spi_sclk};
            cs_sync <= {cs_sync[0], spi_cs_n};
            mosi_sync <= {mosi_sync[0], spi_mosi};
            rx_valid <= 1'b0;
            if (!selected) begin
                bit_count <= 0;
                suppress_fall <= 0;
                if (tx_load) tx_shift <= tx_byte;
            end else begin
                if (tx_load) begin
                    tx_shift <= tx_byte;
                    /* tx_load follows the byte's rising edge; its synchronized
                     * falling edge is still in flight and must not consume bit 7. */
                    suppress_fall <= 1'b1;
                end
                if (rise) begin
                    rx_shift <= {rx_shift[6:0], mosi_sync[1]};
                    if (bit_count == 7) begin
                        rx_byte <= {rx_shift[6:0], mosi_sync[1]};
                        rx_valid <= 1'b1;
                        bit_count <= 0;
                    end else bit_count <= bit_count + 1'b1;
                end
                if (fall && !tx_load) begin
                    if (suppress_fall)
                        suppress_fall <= 1'b0;
                    else
                        tx_shift <= {tx_shift[6:0], 1'b0};
                end
            end
        end
    end
endmodule
