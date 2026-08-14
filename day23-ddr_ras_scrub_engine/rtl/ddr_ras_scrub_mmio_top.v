// Author: Asresh
// Integration top: host MMIO descriptor doorbell, DMA memory master, and IRQ.
module ddr_ras_scrub_mmio_top(input wire clk,input wire rst_n,
    input wire bus_valid_i,input wire bus_write_i,input wire [5:0] bus_addr_i,input wire [31:0] bus_wdata_i,
    output wire bus_ready_o,output wire [31:0] bus_rdata_o,output wire irq_o,
    output wire rd_req_valid_o,input wire rd_req_ready_i,output wire [31:0] rd_req_addr_o,
    input wire rd_rsp_valid_i,input wire [63:0] rd_rsp_data_i,
    output wire wr_req_valid_o,input wire wr_req_ready_i,output wire [31:0] wr_req_addr_o,output wire [63:0] wr_req_data_o);
    wire start,irq_clear,busy;wire[31:0]base,count,corrected,uncorrectable;
    ras_mmio_regs u_regs(.clk(clk),.rst_n(rst_n),.bus_valid_i(bus_valid_i),.bus_write_i(bus_write_i),
      .bus_addr_i(bus_addr_i),.bus_wdata_i(bus_wdata_i),.bus_ready_o(bus_ready_o),.bus_rdata_o(bus_rdata_o),
      .start_o(start),.irq_clear_o(irq_clear),.base_o(base),.count_o(count),.busy_i(busy),.irq_i(irq_o),
      .corrected_i(corrected),.uncorrectable_i(uncorrectable));
    ddr_ras_scrub_top u_core(.clk(clk),.rst_n(rst_n),.start_i(start),.irq_clear_i(irq_clear),
      .desc_base_i(base),.desc_count_i(count),.busy_o(busy),.irq_o(irq_o),.corrected_count_o(corrected),
      .uncorrectable_count_o(uncorrectable),.rd_req_valid_o(rd_req_valid_o),.rd_req_ready_i(rd_req_ready_i),
      .rd_req_addr_o(rd_req_addr_o),.rd_rsp_valid_i(rd_rsp_valid_i),.rd_rsp_data_i(rd_rsp_data_i),
      .wr_req_valid_o(wr_req_valid_o),.wr_req_ready_i(wr_req_ready_i),.wr_req_addr_o(wr_req_addr_o),.wr_req_data_o(wr_req_data_o));
endmodule
