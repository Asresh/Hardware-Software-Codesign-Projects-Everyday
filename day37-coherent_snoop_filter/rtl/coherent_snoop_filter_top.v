// Author: Asresh
`timescale 1ns/1ps
module coherent_snoop_filter_top #(
    parameter ADDR_WIDTH = 16,
    parameter LINE_LSB = 6,
    parameter SETS = 16,
    parameter NODES = 4,
    parameter NODE_BITS = $clog2(NODES),
    parameter REQ_WIDTH = ADDR_WIDTH + NODE_BITS + 3
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  req_valid,
    output wire                  req_ready,
    input  wire [2:0]            req_opcode,
    input  wire [NODE_BITS-1:0]  req_source,
    input  wire [ADDR_WIDTH-1:0] req_addr,
    output wire                  rsp_valid,
    input  wire                  rsp_ready,
    output wire                  rsp_hit,
    output wire                  rsp_error,
    output wire                  rsp_evicted,
    output wire [NODES-1:0]      rsp_probe_mask,
    output wire [NODES-1:0]      rsp_new_sharers,
    input  wire                  psel,
    input  wire                  penable,
    input  wire                  pwrite,
    input  wire [7:0]            paddr,
    input  wire [31:0]           pwdata,
    input  wire [3:0]            pstrb,
    output reg  [31:0]           prdata,
    output wire                  pready,
    output reg                   pslverr,
    output wire                  irq
);
    wire rst = ~rst_n;
    reg enable;
    reg irq_enable;
    reg clear_pulse;
    wire irq_pending;
    wire irq_ack;
    wire apb_access = psel && penable;
    wire apb_write = apb_access && pwrite;
    assign irq_ack = apb_write && paddr == 8'h08 && pwdata[0] && pstrb[0];
    assign pready = 1'b1;
    assign irq = irq_pending && irq_enable;

    wire [REQ_WIDTH-1:0] fifo_in = {req_opcode, req_source, req_addr};
    wire [REQ_WIDTH-1:0] fifo_out;
    wire fifo_in_ready;
    wire fifo_valid;
    wire fifo_ready;
    wire [2:0] dir_opcode = fifo_out[REQ_WIDTH-1 -: 3];
    wire [NODE_BITS-1:0] dir_source = fifo_out[ADDR_WIDTH +: NODE_BITS];
    wire [ADDR_WIDTH-1:0] dir_addr = fifo_out[ADDR_WIDTH-1:0];
    wire [NODES-1:0] probe_basis;
    wire include_source;
    wire [NODE_BITS-1:0] response_source;
    assign req_ready = fifo_in_ready && enable;

    reg [31:0] request_count;
    reg [31:0] hit_count;
    reg [31:0] miss_count;
    reg [31:0] probe_count;
    reg [31:0] error_count;
    integer p;
    reg [31:0] probe_popcount;

    always @* begin
        probe_popcount = 32'd0;
        for (p = 0; p < NODES; p = p + 1)
            probe_popcount = probe_popcount + rsp_probe_mask[p];
    end

    coh_request_fifo #(.WIDTH(REQ_WIDTH)) u_request_fifo (
        .clk(clk), .rst(rst), .clear(clear_pulse),
        .in_valid(req_valid && enable), .in_ready(fifo_in_ready), .in_data(fifo_in),
        .out_valid(fifo_valid), .out_ready(fifo_ready), .out_data(fifo_out)
    );

    coh_directory_bank #(
        .ADDR_WIDTH(ADDR_WIDTH), .LINE_LSB(LINE_LSB), .SETS(SETS), .NODES(NODES)
    ) u_directory (
        .clk(clk), .rst(rst), .clear(clear_pulse),
        .cmd_valid(fifo_valid), .cmd_ready(fifo_ready),
        .cmd_opcode(dir_opcode), .cmd_source(dir_source), .cmd_addr(dir_addr),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_hit(rsp_hit),
        .rsp_error(rsp_error), .rsp_evicted(rsp_evicted),
        .rsp_probe_basis(probe_basis), .rsp_include_source(include_source),
        .rsp_source(response_source), .rsp_new_sharers(rsp_new_sharers)
    );

    probe_mask_filter #(.NODES(NODES)) u_probe_filter (
        .sharers(probe_basis), .source(response_source),
        .include_source(include_source), .probe_mask(rsp_probe_mask)
    );

    coh_irq_latch u_irq (
        .clk(clk), .rst(rst), .set_i(rsp_valid && rsp_ready),
        .clear_i(irq_ack || clear_pulse), .pending(irq_pending)
    );

    always @(posedge clk) begin
        if (rst) begin
            enable <= 1'b0;
            irq_enable <= 1'b0;
            clear_pulse <= 1'b0;
            request_count <= 32'd0;
            hit_count <= 32'd0;
            miss_count <= 32'd0;
            probe_count <= 32'd0;
            error_count <= 32'd0;
        end else begin
            clear_pulse <= 1'b0;
            if (apb_write && paddr == 8'h00 && pstrb[0]) begin
                enable <= pwdata[0];
                irq_enable <= pwdata[1];
                if (pwdata[2]) begin
                    clear_pulse <= 1'b1;
                    request_count <= 32'd0;
                    hit_count <= 32'd0;
                    miss_count <= 32'd0;
                    probe_count <= 32'd0;
                    error_count <= 32'd0;
                end
            end
            if (fifo_valid && fifo_ready)
                request_count <= request_count + 1'b1;
            if (rsp_valid && rsp_ready) begin
                if (rsp_hit)
                    hit_count <= hit_count + 1'b1;
                else
                    miss_count <= miss_count + 1'b1;
                if (rsp_error)
                    error_count <= error_count + 1'b1;
                probe_count <= probe_count + probe_popcount;
            end
        end
    end

    always @* begin
        prdata = 32'd0;
        pslverr = 1'b0;
        case (paddr)
            8'h00: prdata = {30'd0, irq_enable, enable};
            8'h04: prdata = {29'd0, rsp_valid, fifo_valid, enable};
            8'h08: prdata = {31'd0, irq_pending};
            8'h0c: prdata = request_count;
            8'h10: prdata = hit_count;
            8'h14: prdata = miss_count;
            8'h18: prdata = probe_count;
            8'h1c: prdata = error_count;
            8'h20: prdata = (SETS << 16) | (NODES << 8) | 32'd2;
            default: begin
                prdata = 32'd0;
                pslverr = apb_access;
            end
        endcase
    end
endmodule
