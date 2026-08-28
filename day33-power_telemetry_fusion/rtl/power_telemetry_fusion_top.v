// Author: Asresh
// Top-level control plane and DMA sequencer. Firmware starts a descriptor;
// hardware validates it, streams samples through the fusion pipeline, writes
// ordered results, records progress, and raises a sticky completion interrupt.
module power_telemetry_fusion_top #(
    parameter ADDR_WIDTH = 16,
    parameter MAX_SAMPLES = 1024
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  mmio_valid,
    input  wire                  mmio_write,
    input  wire [7:0]            mmio_addr,
    input  wire [31:0]           mmio_wdata,
    output wire                  mmio_ready,
    output reg  [31:0]           mmio_rdata,
    output wire                  mem_rd_valid,
    output wire [ADDR_WIDTH-1:0] mem_rd_addr,
    input  wire                  mem_rd_ready,
    input  wire [31:0]           mem_rd_data,
    output wire                  mem_wr_valid,
    output wire [ADDR_WIDTH-1:0] mem_wr_addr,
    output wire [31:0]           mem_wr_data,
    input  wire                  mem_wr_ready,
    output wire                  irq
);
    localparam ST_IDLE = 2'd0, ST_FETCH = 2'd1, ST_RUN = 2'd2;
    reg [1:0] state;
    reg [ADDR_WIDTH-1:0] descriptor_addr;
    reg [11:0] nominal_mv;
    reg signed [7:0] temperature_limit;
    reg [7:0] droop_weight, current_weight, thermal_weight;
    reg [30:0] alert_threshold;
    reg irq_enable;
    reg error_sticky;
    reg descriptor_start;
    reg done_pulse;
    reg [31:0] cycle_count;
    reg [15:0] issued_count, written_count;

    wire descriptor_mem_valid;
    wire [ADDR_WIDTH-1:0] descriptor_mem_addr;
    wire descriptor_busy, descriptor_done;
    wire [ADDR_WIDTH-1:0] source_addr, destination_addr;
    wire [15:0] descriptor_count;
    wire [31:0] descriptor_flags;
    wire pipeline_in_ready, pipeline_out_valid;
    wire [31:0] pipeline_result;
    wire sample_request = state == ST_RUN && issued_count < descriptor_count &&
                          pipeline_in_ready;
    wire sample_accept = sample_request && mem_rd_ready;
    wire write_accept = mem_wr_valid && mem_wr_ready;
    wire irq_pending;
    wire irq_clear = mmio_valid && mmio_write && mmio_addr == 8'h24 &&
                     mmio_wdata[0];

    assign mmio_ready = mmio_valid;
    assign mem_rd_valid = state == ST_FETCH ? descriptor_mem_valid : sample_request;
    assign mem_rd_addr = state == ST_FETCH ? descriptor_mem_addr :
                         source_addr + {issued_count[ADDR_WIDTH-3:0], 2'b00};
    assign mem_wr_valid = state == ST_RUN && pipeline_out_valid;
    assign mem_wr_addr = destination_addr +
                         {written_count[ADDR_WIDTH-3:0], 2'b00};
    assign mem_wr_data = pipeline_result;

    ptf_descriptor_reader #(.ADDR_WIDTH(ADDR_WIDTH)) descriptor_reader (
        .clk(clk), .rst_n(rst_n), .start(descriptor_start),
        .base_addr(descriptor_addr), .mem_valid(descriptor_mem_valid),
        .mem_addr(descriptor_mem_addr),
        .mem_ready(mem_rd_ready && state == ST_FETCH), .mem_rdata(mem_rd_data),
        .busy(descriptor_busy), .done(descriptor_done), .src_addr(source_addr),
        .dst_addr(destination_addr), .count(descriptor_count),
        .flags(descriptor_flags)
    );

    ptf_pipeline pipeline (
        .clk(clk), .rst_n(rst_n), .in_valid(sample_accept),
        .in_ready(pipeline_in_ready), .in_sample(mem_rd_data),
        .nominal_mv(nominal_mv), .temperature_limit(temperature_limit),
        .droop_weight(droop_weight), .current_weight(current_weight),
        .thermal_weight(thermal_weight), .alert_threshold(alert_threshold),
        .out_valid(pipeline_out_valid), .out_ready(mem_wr_ready),
        .out_result(pipeline_result)
    );

    ptf_irq_latch irq_latch (
        .clk(clk), .rst_n(rst_n), .enable(irq_enable), .set_done(done_pulse),
        .clear_done(irq_clear), .pending(irq_pending), .irq(irq)
    );

    always @* begin
        case (mmio_addr)
            8'h00: mmio_rdata = {30'd0, irq_enable, 1'b0};
            8'h04: mmio_rdata = {29'd0, error_sticky, irq_pending,
                                 state != ST_IDLE};
            8'h08: mmio_rdata = {{(32-ADDR_WIDTH){1'b0}}, descriptor_addr};
            8'h0c: mmio_rdata = cycle_count;
            8'h10: mmio_rdata = {16'd0, written_count};
            8'h14: mmio_rdata = {20'd0, nominal_mv};
            8'h18: mmio_rdata = {{24{temperature_limit[7]}}, temperature_limit};
            8'h1c: mmio_rdata = {8'd0, thermal_weight, current_weight,
                                 droop_weight};
            8'h20: mmio_rdata = {1'b0, alert_threshold};
            8'h24: mmio_rdata = {31'd0, irq_pending};
            8'h28: mmio_rdata = 32'h0001_0000;
            default: mmio_rdata = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            descriptor_addr <= {ADDR_WIDTH{1'b0}};
            nominal_mv <= 12'd900;
            temperature_limit <= 8'sd85;
            droop_weight <= 8'd1;
            current_weight <= 8'd1;
            thermal_weight <= 8'd1;
            alert_threshold <= 31'd1000;
            irq_enable <= 1'b0;
            error_sticky <= 1'b0;
            descriptor_start <= 1'b0;
            done_pulse <= 1'b0;
            cycle_count <= 32'd0;
            issued_count <= 16'd0;
            written_count <= 16'd0;
        end else begin
            descriptor_start <= 1'b0;
            done_pulse <= 1'b0;
            if (state != ST_IDLE)
                cycle_count <= cycle_count + 32'd1;
            if (mmio_valid && mmio_write) begin
                case (mmio_addr)
                    8'h00: begin
                        irq_enable <= mmio_wdata[1];
                        if (mmio_wdata[0] && state == ST_IDLE) begin
                            state <= ST_FETCH;
                            descriptor_start <= 1'b1;
                            cycle_count <= 32'd0;
                            issued_count <= 16'd0;
                            written_count <= 16'd0;
                            error_sticky <= 1'b0;
                        end
                    end
                    8'h08: descriptor_addr <= mmio_wdata[ADDR_WIDTH-1:0];
                    8'h14: nominal_mv <= mmio_wdata[11:0];
                    8'h18: temperature_limit <= mmio_wdata[7:0];
                    8'h1c: begin
                        droop_weight <= mmio_wdata[7:0];
                        current_weight <= mmio_wdata[15:8];
                        thermal_weight <= mmio_wdata[23:16];
                    end
                    8'h20: alert_threshold <= mmio_wdata[30:0];
                endcase
            end
            if (state == ST_FETCH && descriptor_done) begin
                if (descriptor_count == 0 || descriptor_count > MAX_SAMPLES ||
                    source_addr[1:0] != 0 || destination_addr[1:0] != 0 ||
                    descriptor_flags != 0) begin
                    state <= ST_IDLE;
                    error_sticky <= 1'b1;
                    done_pulse <= 1'b1;
                end else begin
                    state <= ST_RUN;
                end
            end
            if (state == ST_RUN) begin
                if (sample_accept)
                    issued_count <= issued_count + 16'd1;
                if (write_accept) begin
                    written_count <= written_count + 16'd1;
                    if (written_count + 16'd1 == descriptor_count) begin
                        state <= ST_IDLE;
                        done_pulse <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
