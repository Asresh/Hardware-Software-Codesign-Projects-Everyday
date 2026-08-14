// Author: Asresh
// Selected/ready 32-bit host register bank for descriptor launch and RAS telemetry.
module ras_mmio_regs(input wire clk,input wire rst_n,input wire bus_valid_i,input wire bus_write_i,
    input wire [5:0] bus_addr_i,input wire [31:0] bus_wdata_i,output wire bus_ready_o,
    output reg [31:0] bus_rdata_o,output reg start_o,output reg irq_clear_o,
    output reg [31:0] base_o,output reg [31:0] count_o,input wire busy_i,input wire irq_i,
    input wire [31:0] corrected_i,input wire [31:0] uncorrectable_i);
    assign bus_ready_o=bus_valid_i;
    always @* begin
        case(bus_addr_i[5:2])
          0:bus_rdata_o=0;1:bus_rdata_o=base_o;2:bus_rdata_o=count_o;
          3:bus_rdata_o={30'd0,irq_i,busy_i};4:bus_rdata_o=corrected_i;
          5:bus_rdata_o=uncorrectable_i;6:bus_rdata_o={31'd0,irq_i};
          default:bus_rdata_o=32'h0;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin start_o<=0;irq_clear_o<=0;base_o<=0;count_o<=0;end else begin
            start_o<=0;irq_clear_o<=0;
            if(bus_valid_i&&bus_write_i)case(bus_addr_i[5:2])
              0:if(bus_wdata_i[0])start_o<=1;1:base_o<=bus_wdata_i;2:count_o<=bus_wdata_i;
              6:if(bus_wdata_i[0])irq_clear_o<=1;default:begin end
            endcase
        end
    end
endmodule
