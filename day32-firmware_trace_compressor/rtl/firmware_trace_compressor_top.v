// Author: Asresh
`timescale 1ns/1ps
module firmware_trace_compressor_top #(
    parameter RING_DEPTH = 512,
    parameter RING_AW = 9,
    parameter BANK_DEPTH = 8,
    parameter BANK_AW = 3
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        bus_valid,
    input  wire        bus_write,
    input  wire [12:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output wire        bus_ready,
    output reg  [31:0] bus_rdata,
    output wire        irq
);
    localparam CTRL = 13'h0000, STATUS = 13'h0004, INPUT_COUNT = 13'h0008;
    localparam OUTPUT_COUNT = 13'h000c, CYCLES = 13'h0010, CAPS = 13'h0014;
    localparam [7:0] BANK_CAP = BANK_DEPTH;
    localparam [15:0] RING_CAP = RING_DEPTH;

    reg busy, done_sticky, irq_en, error_sticky;
    reg [RING_AW:0] input_count;
    reg [RING_AW:0] output_count;
    reg [31:0] cycle_count;
    reg [RING_AW:0] fill_global;
    reg fill_bank, drain_bank;
    reg [BANK_AW:0] fill_idx, drain_idx;
    reg [BANK_AW:0] bank_count0, bank_count1;
    reg bank_ready0, bank_ready1;
    reg encoder_clear;

    wire input_window = (bus_addr >= 13'h0100) && (bus_addr < 13'h0900);
    wire output_window = (bus_addr >= 13'h1000);
    wire input_host_we = bus_valid && bus_write && input_window && !busy;
    wire [RING_AW-1:0] input_host_addr = (bus_addr - 13'h0100) >> 2;
    wire [RING_AW-1:0] input_accel_addr = fill_global[RING_AW-1:0];
    wire [31:0] input_accel_data;
    wire pp_wr_en = busy && (fill_global < input_count) &&
                    !(fill_bank ? bank_ready1 : bank_ready0);
    wire [31:0] pp_rd_data;
    wire drain_ready = drain_bank ? bank_ready1 : bank_ready0;
    wire [BANK_AW:0] drain_count = drain_bank ? bank_count1 : bank_count0;
    wire enc_in_valid = busy && drain_ready;
    wire enc_in_ready;
    wire enc_last = (fill_global == input_count) &&
                    (drain_idx + 1'b1 == drain_count) &&
                    !(drain_bank ? bank_ready0 : bank_ready1);
    wire enc_out_valid, enc_done;
    wire [63:0] enc_out_data;
    wire [RING_AW-1:0] output_host_addr = (bus_addr - 13'h1000) >> 3;
    wire output_host_high = bus_addr[2];
    wire [31:0] output_host_data;

    assign bus_ready = bus_valid;
    assign irq = irq_en && done_sticky;

    trace_input_ring #(.DEPTH(RING_DEPTH), .AW(RING_AW)) u_input_ring (
        .clk(clk), .host_we(input_host_we), .host_addr(input_host_addr),
        .host_wdata(bus_wdata), .accel_addr(input_accel_addr),
        .accel_rdata(input_accel_data));

    trace_pingpong_buffer #(.BANK_DEPTH(BANK_DEPTH), .BW(BANK_AW)) u_pingpong (
        .clk(clk), .wr_en(pp_wr_en), .wr_bank(fill_bank),
        .wr_addr(fill_idx[BANK_AW-1:0]), .wr_data(input_accel_data),
        .rd_bank(drain_bank), .rd_addr(drain_idx[BANK_AW-1:0]),
        .rd_data(pp_rd_data));

    trace_run_encoder u_encoder (
        .clk(clk), .rst_n(rst_n), .clear(encoder_clear),
        .in_valid(enc_in_valid), .in_ready(enc_in_ready),
        .in_data(pp_rd_data), .in_last(enc_last),
        .out_valid(enc_out_valid), .out_data(enc_out_data), .done(enc_done));

    trace_output_ring #(.DEPTH(RING_DEPTH), .AW(RING_AW)) u_output_ring (
        .clk(clk), .accel_we(enc_out_valid),
        .accel_addr(output_count[RING_AW-1:0]), .accel_wdata(enc_out_data),
        .host_addr(output_host_addr), .host_high(output_host_high),
        .host_rdata(output_host_data));

    always @* begin
        bus_rdata = 32'b0;
        if (output_window) bus_rdata = output_host_data;
        else case (bus_addr)
            STATUS:       bus_rdata = {28'b0, error_sticky, done_sticky, busy, irq};
            INPUT_COUNT:  bus_rdata = input_count;
            OUTPUT_COUNT: bus_rdata = output_count;
            CYCLES:       bus_rdata = cycle_count;
            CAPS:         bus_rdata = {BANK_CAP, RING_CAP[7:0], 16'h5452};
            default:      bus_rdata = 32'b0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done_sticky <= 1'b0;
            error_sticky <= 1'b0;
            irq_en <= 1'b0;
            input_count <= 0;
            output_count <= 0;
            cycle_count <= 0;
            fill_global <= 0;
            fill_bank <= 1'b0;
            drain_bank <= 1'b0;
            fill_idx <= 0;
            drain_idx <= 0;
            bank_count0 <= 0;
            bank_count1 <= 0;
            bank_ready0 <= 1'b0;
            bank_ready1 <= 1'b0;
            encoder_clear <= 1'b0;
        end else begin
            encoder_clear <= 1'b0;
            if (bus_valid && bus_write && bus_addr == CTRL) begin
                irq_en <= bus_wdata[1];
                if (bus_wdata[2]) begin
                    done_sticky <= 1'b0;
                    error_sticky <= 1'b0;
                end
                if (bus_wdata[0] && !busy) begin
                    done_sticky <= 1'b0;
                    error_sticky <= (input_count == 0) || (input_count > RING_DEPTH);
                    output_count <= 0;
                    cycle_count <= 0;
                    fill_global <= 0;
                    fill_bank <= 1'b0;
                    drain_bank <= 1'b0;
                    fill_idx <= 0;
                    drain_idx <= 0;
                    bank_ready0 <= 1'b0;
                    bank_ready1 <= 1'b0;
                    encoder_clear <= 1'b1;
                    if ((input_count != 0) && (input_count <= RING_DEPTH)) busy <= 1'b1;
                    else done_sticky <= 1'b1;
                end
            end
            if (bus_valid && bus_write && bus_addr == INPUT_COUNT && !busy)
                input_count <= bus_wdata[RING_AW:0];

            if (busy) begin
                cycle_count <= cycle_count + 1'b1;
                if (pp_wr_en) begin
                    fill_global <= fill_global + 1'b1;
                    if ((fill_idx + 1'b1 == BANK_DEPTH) ||
                        (fill_global + 1'b1 == input_count)) begin
                        if (fill_bank) begin bank_ready1 <= 1'b1; bank_count1 <= fill_idx + 1'b1; end
                        else begin bank_ready0 <= 1'b1; bank_count0 <= fill_idx + 1'b1; end
                        fill_idx <= 0;
                        fill_bank <= ~fill_bank;
                    end else fill_idx <= fill_idx + 1'b1;
                end
                if (enc_in_valid && enc_in_ready) begin
                    if (drain_idx + 1'b1 == drain_count) begin
                        if (drain_bank) bank_ready1 <= 1'b0;
                        else bank_ready0 <= 1'b0;
                        drain_idx <= 0;
                        drain_bank <= ~drain_bank;
                    end else drain_idx <= drain_idx + 1'b1;
                end
                if (enc_out_valid) output_count <= output_count + 1'b1;
                if (enc_done) begin
                    busy <= 1'b0;
                    done_sticky <= 1'b1;
                end
            end
        end
    end
endmodule
