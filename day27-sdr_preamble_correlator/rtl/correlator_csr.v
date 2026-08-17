// Author: Asresh
// AXI4-Lite-like selected/ready CSR bank, tap RAM, counters and sticky IRQ.
module correlator_csr #(
    parameter LANES = 8,
    parameter W = 8
) (
    input clk,
    input rst_n,
    input bus_valid,
    input bus_write,
    input [7:0] bus_addr,
    input [31:0] bus_wdata,
    output reg bus_ready,
    output reg [31:0] bus_rdata,
    output reg enabled,
    output reg [40:0] threshold,
    output [(LANES*W)-1:0] tap_i_flat,
    output [(LANES*W)-1:0] tap_q_flat,
    input result_fire,
    input result_detected,
    input frame_last_fire,
    output irq
);
    integer k;
    reg signed [W-1:0] tap_i [0:LANES-1];
    reg signed [W-1:0] tap_q [0:LANES-1];
    reg [31:0] vectors_seen;
    reg [31:0] detections;
    reg done_sticky;
    reg irq_enable;

    generate
        genvar g;
        for (g = 0; g < LANES; g = g + 1) begin : FLATTEN
            assign tap_i_flat[(g*W)+:W] = tap_i[g];
            assign tap_q_flat[(g*W)+:W] = tap_q[g];
        end
    endgenerate
    assign irq = irq_enable && done_sticky;

    always @(*) begin
        bus_ready = bus_valid;
        case (bus_addr)
            8'h00: bus_rdata = {29'd0, irq_enable, 1'b0, enabled};
            8'h04: bus_rdata = {30'd0, done_sticky, enabled};
            8'h08: bus_rdata = threshold[31:0];
            8'h0c: bus_rdata = {23'd0, threshold[40:32]};
            8'h10: bus_rdata = vectors_seen;
            8'h14: bus_rdata = detections;
            8'h18: bus_rdata = 32'h0008_0803;
            default: begin
                bus_rdata = 32'd0;
                for (k = 0; k < LANES; k = k + 1)
                    if (bus_addr == (8'h40 + (k * 4)))
                        bus_rdata = {{(32-(2*W)){1'b0}}, tap_q[k], tap_i[k]};
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enabled <= 1'b0;
            irq_enable <= 1'b0;
            threshold <= 41'd0;
            vectors_seen <= 32'd0;
            detections <= 32'd0;
            done_sticky <= 1'b0;
            for (k = 0; k < LANES; k = k + 1) begin
                tap_i[k] <= 0;
                tap_q[k] <= 0;
            end
        end else begin
            if (result_fire) begin
                vectors_seen <= vectors_seen + 1'b1;
                if (result_detected)
                    detections <= detections + 1'b1;
            end
            if (frame_last_fire)
                done_sticky <= 1'b1;
            if (bus_valid && bus_write) begin
                case (bus_addr)
                    8'h00: begin
                        enabled <= bus_wdata[0];
                        if (bus_wdata[1]) begin
                            vectors_seen <= 0;
                            detections <= 0;
                            done_sticky <= 0;
                        end
                        irq_enable <= bus_wdata[2];
                    end
                    8'h08: threshold[31:0] <= bus_wdata;
                    8'h0c: threshold[40:32] <= bus_wdata[8:0];
                    8'h1c: if (bus_wdata[0]) done_sticky <= 1'b0;
                    default: for (k = 0; k < LANES; k = k + 1)
                        if (bus_addr == (8'h40 + (k * 4))) begin
                            tap_i[k] <= bus_wdata[W-1:0];
                            tap_q[k] <= bus_wdata[W+(W-1):W];
                        end
                endcase
            end
        end
    end
endmodule
