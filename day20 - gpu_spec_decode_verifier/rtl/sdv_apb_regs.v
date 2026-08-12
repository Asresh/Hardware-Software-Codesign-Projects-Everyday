// ===========================================================================
// sdv_apb_regs.v - APB3 control/status plane.
//
// Carries the per-job configuration (mode, the two acceptance thresholds and
// the software cap on accepted tokens), the sticky interrupt with its
// write-1-to-clear acknowledge, and the telemetry a serving runtime actually
// wants back: how many tokens were accepted, how many jobs were rejected or
// hit the cap, where the cycles went (loading, source-starved, backpressured)
// and - the one that pays for itself - a per-position acceptance histogram.
// A draft tree is only worth its cost if the deeper positions are being
// accepted often enough, and HIST[k] is exactly that measurement, taken for
// free on the datapath instead of by instrumenting the host loop.
//
// Unmapped addresses answer with PSLVERR rather than silently reading zero.
// ===========================================================================
`default_nettype none
`include "sdv_defs.vh"

module sdv_apb_regs #(
    parameter integer N  = 64,
    parameter integer D  = 16,
    parameter integer DW = 5
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- APB3 ------------------------------------------------------------
    input  wire         psel,
    input  wire         penable,
    input  wire         pwrite,
    input  wire [11:0]  paddr,
    input  wire [31:0]  pwdata,
    output reg  [31:0]  prdata,
    output wire         pready,
    output reg          pslverr,

    // ---- configuration out ------------------------------------------------
    output wire         en,
    output wire [1:0]   cfg_mode,
    output wire [15:0]  cfg_th_abs,
    output wire [15:0]  cfg_th_rel,
    output wire [15:0]  cfg_max_acc,
    output wire         soft_rst,

    // ---- statistics strobes in --------------------------------------------
    input  wire         st_busy,
    input  wire         st_srcstall,
    input  wire         st_bpstall,
    input  wire         st_job_done,
    input  wire         st_node_inc,
    input  wire         st_accept_inc,
    input  wire [DW-1:0] st_accept_depth,
    input  wire         st_err_job,
    input  wire         st_clamp_job,
    input  wire [2:0]   st_errcode,
    input  wire [31:0]  st_last_cyc,
    input  wire [15:0]  st_last_acc,
    input  wire         core_busy,
    input  wire         eg_empty,

    output wire         irq
);
    localparam integer NHIST = D;

    reg [31:0] ctrl, th_abs, th_rel, max_acc;
    reg [2:0]  irq_stat;
    reg [2:0]  errcode;
    reg [31:0] c_jobs, c_nodes, c_accept, c_errjobs, c_clamp;
    reg [31:0] c_busy, c_srcstall, c_bpstall, c_lastcyc, c_lastacc;
    reg [31:0] hist [0:NHIST-1];

    wire [7:0] widx  = paddr[9:2];
    wire       acc_w = psel && penable && pwrite;
    wire       clr   = ctrl[8];

    assign pready      = 1'b1;
    assign en          = ctrl[0];
    assign cfg_mode    = ctrl[3:2];
    assign cfg_th_abs  = th_abs[15:0];
    assign cfg_th_rel  = th_rel[15:0];
    assign cfg_max_acc = max_acc[15:0];
    assign soft_rst    = ctrl[9];
    assign irq         = ctrl[1] && (|irq_stat);

    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            ctrl <= 0; th_abs <= 0; th_rel <= 0; max_acc <= 0;
            irq_stat <= 0; errcode <= 0;
            c_jobs <= 0; c_nodes <= 0; c_accept <= 0; c_errjobs <= 0;
            c_clamp <= 0; c_busy <= 0; c_srcstall <= 0; c_bpstall <= 0;
            c_lastcyc <= 0; c_lastacc <= 0;
            for (i = 0; i < NHIST; i = i + 1) hist[i] <= 0;
        end else begin
            ctrl[8] <= 1'b0;              // CLR_STATS is self-clearing
            ctrl[9] <= 1'b0;              // SOFT_RST  is self-clearing

            // ---- counters ------------------------------------------------
            if (clr) begin
                c_jobs <= 0; c_nodes <= 0; c_accept <= 0; c_errjobs <= 0;
                c_clamp <= 0; c_busy <= 0; c_srcstall <= 0; c_bpstall <= 0;
                c_lastcyc <= 0; c_lastacc <= 0;
                for (i = 0; i < NHIST; i = i + 1) hist[i] <= 0;
            end else begin
                if (st_busy)      c_busy     <= c_busy     + 32'd1;
                if (st_srcstall)  c_srcstall <= c_srcstall + 32'd1;
                if (st_bpstall)   c_bpstall  <= c_bpstall  + 32'd1;
                if (st_node_inc)  c_nodes    <= c_nodes    + 32'd1;
                if (st_job_done)  c_jobs     <= c_jobs     + 32'd1;
                if (st_err_job)   c_errjobs  <= c_errjobs  + 32'd1;
                if (st_clamp_job) c_clamp    <= c_clamp    + 32'd1;
                if (st_accept_inc) begin
                    c_accept <= c_accept + 32'd1;
                    hist[st_accept_depth - 1'b1] <=
                        hist[st_accept_depth - 1'b1] + 32'd1;
                end
                if (st_job_done) begin
                    c_lastcyc <= st_last_cyc;
                    c_lastacc <= {16'd0, st_last_acc};
                end
            end

            // ---- sticky interrupt / error code ----------------------------
            if (st_job_done) begin
                irq_stat[0] <= 1'b1;
                if (st_err_job) begin
                    irq_stat[1] <= 1'b1;
                    errcode     <= st_errcode;
                end
                if (st_clamp_job) irq_stat[2] <= 1'b1;
            end

            // ---- APB writes ----------------------------------------------
            if (acc_w) begin
                case (widx)
                `R_CTRL:     ctrl     <= pwdata;
                `R_TH_ABS:   th_abs   <= pwdata;
                `R_TH_REL:   th_rel   <= pwdata;
                `R_MAX_ACC:  max_acc  <= pwdata;
                `R_IRQ_STAT: irq_stat <= irq_stat & ~pwdata[2:0];  // W1C
                `R_ERRCODE:  errcode  <= 3'd0;
                default: ;
                endcase
            end
        end
    end

    // ---- reads ---------------------------------------------------------------
    always @* begin
        prdata  = 32'h0;
        pslverr = 1'b0;
        if (widx >= `R_HIST_BASE) begin
            if (widx < (`R_HIST_BASE + NHIST[7:0]))
                prdata = hist[widx - `R_HIST_BASE];
            else
                pslverr = psel && penable;
        end else begin
            case (widx)
            `R_CTRL:        prdata = ctrl;
            `R_STATUS:      prdata = {30'd0, eg_empty, core_busy};
            `R_TH_ABS:      prdata = th_abs;
            `R_TH_REL:      prdata = th_rel;
            `R_MAX_ACC:     prdata = max_acc;
            `R_IRQ_STAT:    prdata = {29'd0, irq_stat};
            `R_ERRCODE:     prdata = {29'd0, errcode};
            `R_CAPS:        prdata = {8'd0, D[7:0], N[15:0]};
            `R_VERSION:     prdata = `SDV_VERSION;
            `R_ST_JOBS:     prdata = c_jobs;
            `R_ST_NODES:    prdata = c_nodes;
            `R_ST_ACCEPT:   prdata = c_accept;
            `R_ST_ERRJOBS:  prdata = c_errjobs;
            `R_ST_CLAMP:    prdata = c_clamp;
            `R_ST_BUSY:     prdata = c_busy;
            `R_ST_SRCSTALL: prdata = c_srcstall;
            `R_ST_BPSTALL:  prdata = c_bpstall;
            `R_ST_LASTCYC:  prdata = c_lastcyc;
            `R_ST_LASTACC:  prdata = c_lastacc;
            `R_REGMAP_CSUM: prdata = `SDV_REGMAP_CSUM;
            default:        pslverr = psel && penable;
            endcase
        end
    end
endmodule
`default_nettype wire
