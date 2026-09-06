// Author: Asresh
`timescale 1ns/1ps
module coh_directory_bank #(
    parameter ADDR_WIDTH = 16,
    parameter LINE_LSB = 6,
    parameter SETS = 16,
    parameter NODES = 4,
    parameter NODE_BITS = $clog2(NODES),
    parameter SET_BITS = $clog2(SETS),
    parameter TAG_WIDTH = ADDR_WIDTH - LINE_LSB - SET_BITS
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  clear,
    input  wire                  cmd_valid,
    output wire                  cmd_ready,
    input  wire [2:0]            cmd_opcode,
    input  wire [NODE_BITS-1:0]  cmd_source,
    input  wire [ADDR_WIDTH-1:0] cmd_addr,
    output reg                   rsp_valid,
    input  wire                  rsp_ready,
    output reg                   rsp_hit,
    output reg                   rsp_error,
    output reg                   rsp_evicted,
    output reg  [NODES-1:0]      rsp_probe_basis,
    output reg                   rsp_include_source,
    output reg  [NODE_BITS-1:0]  rsp_source,
    output reg  [NODES-1:0]      rsp_new_sharers
);
    localparam OP_READ_SHARED = 3'd0;
    localparam OP_READ_UNIQUE = 3'd1;
    localparam OP_WRITEBACK   = 3'd2;
    localparam OP_EVICT       = 3'd3;
    localparam OP_FLUSH_LINE  = 3'd4;
    localparam ENTRIES = SETS * 2;

    reg [TAG_WIDTH-1:0] tags [0:ENTRIES-1];
    reg [NODES-1:0] sharers [0:ENTRIES-1];
    reg dirty [0:ENTRIES-1];
    reg valid [0:ENTRIES-1];
    reg replace_way [0:SETS-1];

    wire [SET_BITS-1:0] set_index;
    wire [TAG_WIDTH-1:0] request_tag;
    wire [NODES-1:0] source_mask;
    integer base_index;
    integer selected_index;
    integer i;
    reg hit_found;
    reg selected_valid;
    reg [NODES-1:0] selected_sharers;
    reg selected_dirty;

    assign set_index = cmd_addr[LINE_LSB +: SET_BITS];
    assign request_tag = cmd_addr[ADDR_WIDTH-1 -: TAG_WIDTH];
    assign source_mask = {{(NODES-1){1'b0}}, 1'b1} << cmd_source;
    assign cmd_ready = ~rsp_valid | rsp_ready;

    always @* begin
        base_index = set_index * 2;
        hit_found = 1'b0;
        selected_index = base_index;
        if (valid[base_index] && tags[base_index] == request_tag) begin
            hit_found = 1'b1;
            selected_index = base_index;
        end else if (valid[base_index + 1] && tags[base_index + 1] == request_tag) begin
            hit_found = 1'b1;
            selected_index = base_index + 1;
        end else if (!valid[base_index]) begin
            selected_index = base_index;
        end else if (!valid[base_index + 1]) begin
            selected_index = base_index + 1;
        end else begin
            selected_index = base_index + replace_way[set_index];
        end
        selected_valid = valid[selected_index];
        selected_sharers = sharers[selected_index];
        selected_dirty = dirty[selected_index];
    end

    always @(posedge clk) begin
        if (rst || clear) begin
            rsp_valid <= 1'b0;
            rsp_hit <= 1'b0;
            rsp_error <= 1'b0;
            rsp_evicted <= 1'b0;
            rsp_probe_basis <= {NODES{1'b0}};
            rsp_include_source <= 1'b0;
            rsp_source <= {NODE_BITS{1'b0}};
            rsp_new_sharers <= {NODES{1'b0}};
            for (i = 0; i < ENTRIES; i = i + 1) begin
                tags[i] <= {TAG_WIDTH{1'b0}};
                sharers[i] <= {NODES{1'b0}};
                dirty[i] <= 1'b0;
                valid[i] <= 1'b0;
            end
            for (i = 0; i < SETS; i = i + 1)
                replace_way[i] <= 1'b0;
        end else begin
            if (rsp_ready)
                rsp_valid <= 1'b0;
            if (cmd_valid && cmd_ready) begin
                rsp_valid <= 1'b1;
                rsp_hit <= hit_found;
                rsp_error <= 1'b0;
                rsp_evicted <= 1'b0;
                rsp_probe_basis <= {NODES{1'b0}};
                rsp_include_source <= 1'b0;
                rsp_source <= cmd_source;
                rsp_new_sharers <= hit_found ? selected_sharers : source_mask;

                case (cmd_opcode)
                    OP_READ_SHARED: begin
                        if (hit_found) begin
                            rsp_probe_basis <= selected_dirty ? selected_sharers : {NODES{1'b0}};
                            sharers[selected_index] <= selected_sharers | source_mask;
                            dirty[selected_index] <= 1'b0;
                            rsp_new_sharers <= selected_sharers | source_mask;
                        end else begin
                            rsp_evicted <= selected_valid;
                            rsp_probe_basis <= selected_valid ? selected_sharers : {NODES{1'b0}};
                            rsp_include_source <= 1'b1;
                            valid[selected_index] <= 1'b1;
                            tags[selected_index] <= request_tag;
                            sharers[selected_index] <= source_mask;
                            dirty[selected_index] <= 1'b0;
                            replace_way[set_index] <= ~selected_index[0];
                        end
                    end
                    OP_READ_UNIQUE: begin
                        if (hit_found) begin
                            rsp_probe_basis <= selected_sharers;
                            sharers[selected_index] <= source_mask;
                            dirty[selected_index] <= 1'b1;
                        end else begin
                            rsp_evicted <= selected_valid;
                            rsp_probe_basis <= selected_valid ? selected_sharers : {NODES{1'b0}};
                            rsp_include_source <= 1'b1;
                            valid[selected_index] <= 1'b1;
                            tags[selected_index] <= request_tag;
                            sharers[selected_index] <= source_mask;
                            dirty[selected_index] <= 1'b1;
                            replace_way[set_index] <= ~selected_index[0];
                        end
                        rsp_new_sharers <= source_mask;
                    end
                    OP_WRITEBACK: begin
                        if (hit_found && |(selected_sharers & source_mask)) begin
                            dirty[selected_index] <= 1'b0;
                        end else begin
                            rsp_error <= 1'b1;
                        end
                    end
                    OP_EVICT: begin
                        if (hit_found && |(selected_sharers & source_mask)) begin
                            sharers[selected_index] <= selected_sharers & ~source_mask;
                            rsp_new_sharers <= selected_sharers & ~source_mask;
                            if ((selected_sharers & ~source_mask) == {NODES{1'b0}}) begin
                                valid[selected_index] <= 1'b0;
                                dirty[selected_index] <= 1'b0;
                            end
                        end else begin
                            rsp_error <= 1'b1;
                        end
                    end
                    OP_FLUSH_LINE: begin
                        if (hit_found) begin
                            rsp_probe_basis <= selected_sharers;
                            rsp_include_source <= 1'b1;
                            rsp_new_sharers <= {NODES{1'b0}};
                            valid[selected_index] <= 1'b0;
                            sharers[selected_index] <= {NODES{1'b0}};
                            dirty[selected_index] <= 1'b0;
                        end
                    end
                    default: begin
                        rsp_error <= 1'b1;
                    end
                endcase
            end
        end
    end
endmodule
