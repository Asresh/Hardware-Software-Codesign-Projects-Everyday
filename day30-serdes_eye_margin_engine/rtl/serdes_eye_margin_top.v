// Author: Asresh
module serdes_eye_margin_top #(
    parameter FIFO_DEPTH = 8,
    parameter FIFO_PTR_W = 3
) (
    input wire clk, input wire rst_n,
    input wire psel, input wire penable, input wire pwrite,
    input wire [7:0] paddr, input wire [31:0] pwdata,
    output wire [31:0] prdata, output wire pready, output wire pslverr,
    input wire sample_valid, output wire sample_ready,
    input wire [6:0] sample_phase, input wire [15:0] sample_errors, input wire sample_last,
    output wire irq
);
    wire start_pulse, irq_enable, engine_done, open_point;
    wire [15:0] error_limit;
    wire [23:0] fifo_in = {sample_last,sample_phase,sample_errors};
    wire [23:0] fifo_out;
    wire fifo_valid, tracker_ready;
    wire [FIFO_PTR_W:0] fifo_level_i;
    wire [3:0] fifo_level = fifo_level_i;
    wire [6:0] best_start;
    wire [8:0] best_length, sample_count;
    eye_sample_fifo #(.WIDTH(24),.DEPTH(FIFO_DEPTH),.PTR_W(FIFO_PTR_W)) fifo (
        .clk(clk),.rst_n(rst_n),.clear(start_pulse),
        .in_valid(sample_valid),.in_ready(sample_ready),.in_data(fifo_in),
        .out_valid(fifo_valid),.out_ready(tracker_ready),.out_data(fifo_out),.level(fifo_level_i));
    eye_error_filter filter (.error_count(fifo_out[15:0]),.error_limit(error_limit),.is_open(open_point));
    eye_run_tracker tracker (.clk(clk),.rst_n(rst_n),.clear(start_pulse),
        .sample_valid(fifo_valid),.sample_ready(tracker_ready),.sample_phase(fifo_out[22:16]),
        .sample_open(open_point),.sample_last(fifo_out[23]),.done(engine_done),
        .best_start(best_start),.best_length(best_length),.sample_count(sample_count));
    eye_apb_csr csr (.clk(clk),.rst_n(rst_n),.psel(psel),.penable(penable),.pwrite(pwrite),
        .paddr(paddr),.pwdata(pwdata),.prdata(prdata),.pready(pready),.pslverr(pslverr),
        .start_pulse(start_pulse),.irq_enable(irq_enable),.error_limit(error_limit),
        .engine_done(engine_done),.best_start(best_start),.best_length(best_length),
        .sample_count(sample_count),.fifo_level(fifo_level),.irq(irq));
endmodule
