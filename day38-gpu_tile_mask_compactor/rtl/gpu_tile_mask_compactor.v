// Author: Asresh
`timescale 1ns/1ps
module gpu_tile_mask_compactor #(
  parameter COUNT_WIDTH = 32
)(
  input  wire        clk,
  input  wire        reset_n,
  input  wire        s_axis_valid,
  output wire        s_axis_ready,
  input  wire [63:0] s_axis_data,
  input  wire        s_axis_last,
  output reg         m_axis_valid,
  input  wire        m_axis_ready,
  output reg  [31:0] m_axis_data,
  output reg         m_axis_last,
  input  wire        hsel,
  input  wire [1:0]  htrans,
  input  wire        hwrite,
  input  wire [7:0]  haddr,
  input  wire [31:0] hwdata,
  input  wire        hready,
  output reg  [31:0] hrdata,
  output wire        hreadyout,
  output wire        hresp,
  output reg         irq
);
  localparam ADDR_CTRL=8'h00, ADDR_STATUS=8'h04, ADDR_IN_COUNT=8'h08,
             ADDR_OUT_COUNT=8'h0c, ADDR_BATCH_COUNT=8'h10,
             ADDR_ZERO_COUNT=8'h14, ADDR_THRESHOLD=8'h18;
  reg enabled;
  reg [6:0] sparse_threshold;
  reg [COUNT_WIDTH-1:0] in_count, out_count, batch_count, zero_count;
  wire [31:0] byte_counts;
  wire [7:0] byte_nonzero;
  wire [6:0] active_count;
  wire [5:0] first_active, last_active;
  wire empty;
  wire write_access = hsel && htrans[1] && hwrite && hready;

  tile_byte_scan u_scan(.mask(s_axis_data), .byte_counts(byte_counts), .byte_nonzero(byte_nonzero));
  tile_mask_reduce u_reduce(.mask(s_axis_data), .byte_counts(byte_counts),
    .byte_nonzero(byte_nonzero), .active_count(active_count),
    .first_active(first_active), .last_active(last_active), .empty(empty));

  assign s_axis_ready = enabled && (!m_axis_valid || m_axis_ready);
  assign hreadyout = 1'b1;
  assign hresp = 1'b0;

  always @* begin
    case (haddr)
      ADDR_CTRL:        hrdata = {31'd0, enabled};
      ADDR_STATUS:      hrdata = {30'd0, irq, m_axis_valid};
      ADDR_IN_COUNT:    hrdata = in_count;
      ADDR_OUT_COUNT:   hrdata = out_count;
      ADDR_BATCH_COUNT: hrdata = batch_count;
      ADDR_ZERO_COUNT:  hrdata = zero_count;
      ADDR_THRESHOLD:   hrdata = {25'd0, sparse_threshold};
      default:          hrdata = 32'd0;
    endcase
  end

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      enabled <= 1'b0;
      sparse_threshold <= 7'd8;
      in_count <= {COUNT_WIDTH{1'b0}};
      out_count <= {COUNT_WIDTH{1'b0}};
      batch_count <= {COUNT_WIDTH{1'b0}};
      zero_count <= {COUNT_WIDTH{1'b0}};
      m_axis_valid <= 1'b0;
      m_axis_data <= 32'd0;
      m_axis_last <= 1'b0;
      irq <= 1'b0;
    end else begin
      if (m_axis_valid && m_axis_ready) begin
        m_axis_valid <= 1'b0;
        out_count <= out_count + 1'b1;
        if (m_axis_last) begin
          batch_count <= batch_count + 1'b1;
          irq <= 1'b1;
        end
      end

      if (s_axis_valid && s_axis_ready) begin
        m_axis_valid <= 1'b1;
        m_axis_data <= {11'd0, (active_count <= sparse_threshold), empty,
                       last_active, first_active, active_count};
        m_axis_last <= s_axis_last;
        in_count <= in_count + 1'b1;
        if (empty) zero_count <= zero_count + 1'b1;
      end

      if (write_access && haddr == ADDR_CTRL) begin
        enabled <= hwdata[0];
        if (hwdata[1]) begin
          in_count <= {COUNT_WIDTH{1'b0}};
          out_count <= {COUNT_WIDTH{1'b0}};
          batch_count <= {COUNT_WIDTH{1'b0}};
          zero_count <= {COUNT_WIDTH{1'b0}};
        end
        if (hwdata[2]) irq <= 1'b0;
      end
      if (write_access && haddr == ADDR_THRESHOLD)
        sparse_threshold <= hwdata[6:0];
    end
  end
endmodule
