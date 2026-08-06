// ============================================================================
// kds_regfile - AXI4-Lite control/status plane and interrupt controller.
//
// The host owns policy: it writes the graph into memory, points NODE_BASE and
// RSLT_BASE at it, says how many nodes there are and writes CTRL.START. From
// there the engine is autonomous until it raises GRAPH_DONE or an error, both
// sticky and cleared write-1-to-clear so an interrupt can never be lost between
// the handler reading it and clearing it.
//
// Everything the runtime would otherwise have to measure with timers is a
// read-only counter here: the makespan of the last graph, how many ticks were
// lost to structural stalls versus dependency stalls, the peak number of
// devices in flight, the serial tick count the schedule was compressed from,
// and per-device occupancy - which is what a load balancer actually needs.
// ============================================================================
`include "kds_defs.vh"

module kds_regfile #(
    parameter MAX_NODES = `KDS_MAX_NODES,
    parameter DEVICES   = `KDS_DEVICES
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- AXI4-Lite slave ---------------------------------------------------
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output reg  [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,

    // ---- to / from the core ------------------------------------------------
    output reg         start,
    output reg  [31:0] cfg_num_nodes,
    output reg  [31:0] cfg_node_base,
    output reg  [31:0] cfg_rslt_base,
    input  wire [2:0]  st_state,
    input  wire [3:0]  st_err,
    input  wire        st_busy,
    input  wire        ev_done,
    input  wire        ev_err,

    input  wire [31:0] c_makespan,
    input  wire [31:0] c_dispatched,
    input  wire [31:0] c_stall,
    input  wire [31:0] c_depwait,
    input  wire [31:0] c_maxconc,
    input  wire [31:0] c_serial,
    input  wire [31:0] c_buscyc,
    input  wire [31:0] c_fetchw,
    input  wire [31:0] c_wbw,
    input  wire [DEVICES*32-1:0] c_devbusy_flat,

    output wire        irq
);

    localparam [7:0] CAP_NODES = MAX_NODES;
    localparam [7:0] CAP_DEVS  = DEVICES;

    function [7:0] dev_addr;
        input integer k;
        begin dev_addr = `KDS_A_DEVBUSY0 + k[7:0] * 8'd4; end
    endfunction

    reg [1:0] irq_status;
    reg [1:0] irq_enable;

    // ---- write channel: address and data taken together --------------------
    wire wr_fire = s_awvalid && s_wvalid && !s_bvalid;
    assign s_awready = wr_fire;
    assign s_wready  = wr_fire;
    assign s_bresp   = 2'b00;

    wire [7:0] wa = s_awaddr[7:0];
    wire [7:0] ra = s_araddr[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start         <= 1'b0;
            cfg_num_nodes <= 32'd0;
            cfg_node_base <= 32'd0;
            cfg_rslt_base <= 32'd0;
            irq_status    <= 2'b00;
            irq_enable    <= 2'b00;
            s_bvalid      <= 1'b0;
        end else begin
            start <= 1'b0;

            if (ev_done) irq_status[0] <= 1'b1;
            if (ev_err ) irq_status[1] <= 1'b1;

            if (wr_fire) begin
                s_bvalid <= 1'b1;
                case (wa)
                    `KDS_A_CTRL:       if (s_wdata[0]) start <= 1'b1;
                    `KDS_A_NUM_NODES:  cfg_num_nodes <= s_wdata;
                    `KDS_A_NODE_BASE:  cfg_node_base <= s_wdata;
                    `KDS_A_RSLT_BASE:  cfg_rslt_base <= s_wdata;
                    `KDS_A_IRQ_STATUS: irq_status    <= irq_status & ~s_wdata[1:0];
                    `KDS_A_IRQ_ENABLE: irq_enable    <= s_wdata[1:0];
                    default: ;
                endcase
            end
            if (s_bvalid && s_bready) s_bvalid <= 1'b0;
        end
    end

    // ---- read channel ------------------------------------------------------
    assign s_arready = s_arvalid && !s_rvalid;
    assign s_rresp   = 2'b00;

    reg [31:0] rmux;
    integer d;
    always @* begin
        rmux = 32'd0;
        case (ra)
            `KDS_A_CTRL:       rmux = 32'd0;
            `KDS_A_STATUS:     rmux = {20'd0, st_err, 1'b0, st_state, 1'b0,
                                       (st_state == `KDS_S_ERROR),
                                       (st_state == `KDS_S_DONE), st_busy};
            `KDS_A_NUM_NODES:  rmux = cfg_num_nodes;
            `KDS_A_NODE_BASE:  rmux = cfg_node_base;
            `KDS_A_RSLT_BASE:  rmux = cfg_rslt_base;
            `KDS_A_IRQ_STATUS: rmux = {30'd0, irq_status};
            `KDS_A_IRQ_ENABLE: rmux = {30'd0, irq_enable};
            `KDS_A_MAKESPAN:   rmux = c_makespan;
            `KDS_A_DISPATCHED: rmux = c_dispatched;
            `KDS_A_STALL:      rmux = c_stall;
            `KDS_A_DEPWAIT:    rmux = c_depwait;
            `KDS_A_MAXCONC:    rmux = c_maxconc;
            `KDS_A_SERIAL:     rmux = c_serial;
            `KDS_A_BUSCYC:     rmux = c_buscyc;
            `KDS_A_FETCHW:     rmux = c_fetchw;
            `KDS_A_WBW:        rmux = c_wbw;
            `KDS_A_CAPS:       rmux = {16'd0, CAP_NODES, CAP_DEVS};
            default: begin
                rmux = 32'd0;
                for (d = 0; d < DEVICES; d = d + 1)
                    if (ra == dev_addr(d)) rmux = c_devbusy_flat[d*32 +: 32];
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_rvalid <= 1'b0;
            s_rdata  <= 32'd0;
        end else begin
            if (s_arvalid && s_arready) begin
                s_rdata  <= rmux;
                s_rvalid <= 1'b1;
            end else if (s_rvalid && s_rready) begin
                s_rvalid <= 1'b0;
            end
        end
    end

    assign irq = |(irq_status & irq_enable);

endmodule
