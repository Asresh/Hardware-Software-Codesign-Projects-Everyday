// Author: Asresh
// Descriptor-driven DMA scrubber with one outstanding read and queued writebacks.
module ddr_ras_scrub_top #(parameter ADDR_W=32, parameter FIFO_DEPTH=4)(
    input wire clk,input wire rst_n,input wire start_i,input wire irq_clear_i,input wire [ADDR_W-1:0] desc_base_i,
    input wire [31:0] desc_count_i,output reg busy_o,output reg irq_o,
    output reg [31:0] corrected_count_o,output reg [31:0] uncorrectable_count_o,
    output reg rd_req_valid_o,input wire rd_req_ready_i,output reg [ADDR_W-1:0] rd_req_addr_o,
    input wire rd_rsp_valid_i,input wire [63:0] rd_rsp_data_i,
    output wire wr_req_valid_o,input wire wr_req_ready_i,output wire [ADDR_W-1:0] wr_req_addr_o,
    output wire [63:0] wr_req_data_o);
    reg [ADDR_W-1:0] next_addr,pending_addr; reg [31:0] issued,completed; reg outstanding;
    wire [5:0] syndrome; wire overall_odd,corrected,uncorrectable; wire [38:0] fixed_code;
    wire fifo_in_ready,fifo_out_valid,fifo_empty,fifo_full; wire [ADDR_W-1:0] fifo_addr; wire [38:0] fifo_code;
    ecc_syndrome u_syn(.code_i(rd_rsp_data_i[38:0]),.syndrome_o(syndrome),.overall_odd_o(overall_odd));
    ecc_correct u_fix(.code_i(rd_rsp_data_i[38:0]),.syndrome_i(syndrome),.overall_odd_i(overall_odd),
        .code_o(fixed_code),.corrected_o(corrected),.uncorrectable_o(uncorrectable));
    scrub_fifo #(.DEPTH(FIFO_DEPTH),.AW(ADDR_W)) u_fifo(.clk(clk),.rst_n(rst_n),
        .in_valid(rd_rsp_valid_i&&corrected),.in_ready(fifo_in_ready),.in_addr(pending_addr),.in_code(fixed_code),
        .out_valid(fifo_out_valid),.out_ready(wr_req_ready_i),.out_addr(fifo_addr),.out_code(fifo_code),.empty(fifo_empty),.full(fifo_full));
    assign wr_req_valid_o=fifo_out_valid; assign wr_req_addr_o=fifo_addr; assign wr_req_data_o={25'd0,fifo_code};
    always @* begin rd_req_valid_o=busy_o&&!outstanding&&(issued<desc_count_i)&&!fifo_full; rd_req_addr_o=next_addr; end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin busy_o<=0;irq_o<=0;corrected_count_o<=0;uncorrectable_count_o<=0;next_addr<=0;pending_addr<=0;issued<=0;completed<=0;outstanding<=0; end
        else begin
            if (start_i&&!busy_o) begin busy_o<=(desc_count_i!=0);irq_o<=(desc_count_i==0);corrected_count_o<=0;uncorrectable_count_o<=0;next_addr<=desc_base_i;issued<=0;completed<=0;outstanding<=0; end
            if (rd_req_valid_o&&rd_req_ready_i) begin outstanding<=1;pending_addr<=next_addr;next_addr<=next_addr+8;issued<=issued+1; end
            if (rd_rsp_valid_i&&outstanding) begin outstanding<=0;completed<=completed+1;if(corrected)corrected_count_o<=corrected_count_o+1;if(uncorrectable)uncorrectable_count_o<=uncorrectable_count_o+1; end
            if (busy_o&&(completed==desc_count_i)&&!outstanding&&fifo_empty) begin busy_o<=0;irq_o<=1; end
            if (irq_clear_i) irq_o<=0;
            if (start_i) irq_o<=(desc_count_i==0);
        end
    end
endmodule
