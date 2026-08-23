// Author: Asresh
`timescale 1ns/1ps
// Packet: {start_timestamp, end_timestamp, event_id, payload, run_length}.
module trace_run_encoder (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [31:0] in_data,
    input  wire        in_last,
    output reg         out_valid,
    output reg  [63:0] out_data,
    output reg         done
);
    reg active;
    reg flush_pending;
    reg [15:0] start_ts, end_ts, run_length;
    reg [7:0] event_id, payload;

    assign in_ready = !flush_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            flush_pending <= 1'b0;
            out_valid <= 1'b0;
            out_data <= 64'b0;
            done <= 1'b0;
            start_ts <= 16'b0;
            end_ts <= 16'b0;
            run_length <= 16'b0;
            event_id <= 8'b0;
            payload <= 8'b0;
        end else begin
            out_valid <= 1'b0;
            done <= 1'b0;
            if (clear) begin
                active <= 1'b0;
                flush_pending <= 1'b0;
            end else if (flush_pending) begin
                out_valid <= 1'b1;
                out_data <= {start_ts, end_ts, event_id, payload, run_length};
                flush_pending <= 1'b0;
                active <= 1'b0;
                done <= 1'b1;
            end else if (in_valid) begin
                if (!active) begin
                    start_ts <= in_data[31:16];
                    end_ts <= in_data[31:16];
                    event_id <= in_data[15:8];
                    payload <= in_data[7:0];
                    run_length <= 16'd1;
                    active <= !in_last;
                    if (in_last) begin
                        out_valid <= 1'b1;
                        out_data <= {in_data[31:16], in_data[31:16], in_data[15:8], in_data[7:0], 16'd1};
                        done <= 1'b1;
                    end
                end else if ((event_id == in_data[15:8]) &&
                             (payload == in_data[7:0]) &&
                             (run_length != 16'hffff)) begin
                    end_ts <= in_data[31:16];
                    run_length <= run_length + 16'd1;
                    if (in_last) begin
                        out_valid <= 1'b1;
                        out_data <= {start_ts, in_data[31:16], event_id, payload,
                                     run_length + 16'd1};
                        active <= 1'b0;
                        done <= 1'b1;
                    end
                end else begin
                    out_valid <= 1'b1;
                    out_data <= {start_ts, end_ts, event_id, payload, run_length};
                    start_ts <= in_data[31:16];
                    end_ts <= in_data[31:16];
                    event_id <= in_data[15:8];
                    payload <= in_data[7:0];
                    run_length <= 16'd1;
                    if (in_last)
                        flush_pending <= 1'b1;
                end
            end
        end
    end
endmodule
