// ============================================================================
// kds_core - the command processor: graph fetch, validation, scheduling and
//            result writeback.
//
//   IDLE -> FETCH -> CHECK -> RUN -> WB -> DONE
//                                \-> ERROR
//
// FETCH pulls the whole node array into the on-chip scoreboard before a single
// scheduling decision is taken. That is deliberate: the RUN phase then touches
// no bus at all, so the schedule cannot be perturbed by memory timing and the
// golden model can predict it tick for tick. Addresses run ahead of returning
// data by up to OUTSTANDING transactions, so the fetch keeps the AXI4-Lite read
// channel busy every cycle a zero-wait slave will allow. Validation is folded
// into the fetch - each record is checked as it lands - so CHECK is one cycle
// that only looks at accumulated flags, and the reported error code has a fixed
// priority instead of depending on which record arrived first.
//
// RUN advances one tick per clock:
//   * kds_scoreboard turns (dep masks, retirement mask) into a ready vector,
//   * kds_placer picks the lowest ready node with a free allowed device,
//   * kds_devq counts the running nodes down and retires them.
// Every tick is exactly one of dispatch / structural stall (ready, but every
// allowed device busy) / dependency stall, hence
//     makespan == dispatched + stall + depwait
// and, because device occupancy is charged for the issue cycle as well,
//     sum(dev_busy) == sum over nodes of (duration+1) == serial_ticks.
// The testbench checks both identities on every graph.
//
// A tick with nothing runnable and nothing running means the graph has a cycle.
// There is no timeout involved - the condition is exact.
// ============================================================================
`include "kds_defs.vh"

module kds_core #(
    parameter MAX_NODES   = `KDS_MAX_NODES,
    parameter DEVICES     = `KDS_DEVICES,
    parameter NIDW        = 6,
    parameter DIDW        = 2,
    parameter DEPW        = 2,
    parameter NODE_WORDS  = 4,
    parameter OUTSTANDING = 4
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- control / status (kds_regfile) ------------------------------------
    input  wire                    start,
    input  wire [31:0]             cfg_num_nodes,
    input  wire [31:0]             cfg_node_base,
    input  wire [31:0]             cfg_rslt_base,
    output wire [2:0]              st_state,
    output reg  [3:0]              st_err,
    output wire                    st_busy,
    output reg                     ev_done,
    output reg                     ev_err,

    output reg  [31:0]             c_makespan,
    output reg  [31:0]             c_dispatched,
    output reg  [31:0]             c_stall,
    output reg  [31:0]             c_depwait,
    output reg  [31:0]             c_maxconc,
    output reg  [31:0]             c_serial,
    output reg  [31:0]             c_buscyc,
    output reg  [31:0]             c_fetchw,
    output reg  [31:0]             c_wbw,
    output wire [DEVICES*32-1:0]   c_devbusy_flat,

    // ---- memory ports (kds_axil_master) ------------------------------------
    output wire                    rd_req,
    output wire [31:0]             rd_addr,
    input  wire                    rd_gnt,
    input  wire                    rd_valid,
    input  wire [31:0]             rd_data,
    output wire                    wr_req,
    output wire [31:0]             wr_addr,
    output wire [31:0]             wr_wdata,
    input  wire                    wr_gnt,
    input  wire                    wr_done,
    output wire                    mem_clr,
    input  wire                    mem_err
);

    // ------------------------------------------------------------------ state
    reg [2:0]           state;
    reg [NIDW:0]        n_q;
    reg [MAX_NODES-1:0] valid_mask;
    reg [31:0]          nbase_q, rbase_q;

    reg [15:0]          f_issue, f_ack, f_total;
    reg [NIDW-1:0]      f_node;
    reg [15:0]          f_pos;
    reg [MAX_NODES-1:0] dep_acc;
    reg [15:0]          dur_l;
    reg [DEVICES-1:0]   dev_l;
    reg                 bad_dur, bad_dev, bad_dep, bad_bus;

    reg [MAX_NODES-1:0] done_mask, issued_mask;
    reg [31:0]          tick;
    reg [15:0]          seq_q;
    reg [31:0]          start_t [0:MAX_NODES-1];
    reg [31:0]          fin_t   [0:MAX_NODES-1];
    reg [DIDW-1:0]      dev_of  [0:MAX_NODES-1];
    reg [15:0]          seq_of  [0:MAX_NODES-1];
    reg [31:0]          devbusy [0:DEVICES-1];

    reg [15:0]          w_issue, w_ack, w_total;

    integer u;

    // ------------------------------------------------- graph store and logic
    wire [MAX_NODES*MAX_NODES-1:0] dep_flat;
    wire [MAX_NODES*DEVICES-1:0]   dev_flat;
    wire [15:0]                    rdur;
    wire [31:0]                    rkid;
    wire [NIDW-1:0]                raddr;
    wire [NIDW-1:0]                wb_node;

    wire [MAX_NODES-1:0]           ready;
    wire                           ready_any;
    wire [DEVICES-1:0]             busy, comp_valid, free_mask;
    wire [DEVICES*NIDW-1:0]        comp_node_flat;
    wire                           sel_valid_raw;
    wire [NIDW-1:0]                sel_node;
    wire [DIDW-1:0]                sel_dev;
    wire [DEVICES-1:0]             sel_dev_oh;

    wire idle_like = (state == `KDS_S_IDLE) || (state == `KDS_S_DONE) ||
                     (state == `KDS_S_ERROR);
    wire launch    = start && idle_like;

    wire nm_we = rd_valid && (state == `KDS_S_FETCH) && (f_pos == NODE_WORDS-1);

    assign wb_node = w_issue[NIDW+1:2];
    assign raddr   = (state == `KDS_S_WB) ? wb_node : sel_node;

    kds_node_mem #(.MAX_NODES(MAX_NODES), .DEVICES(DEVICES), .NIDW(NIDW)) u_mem (
        .clk(clk),
        .we(nm_we), .waddr(f_node), .wdur(dur_l), .wdev(dev_l),
        .wdep(dep_acc), .wkid(rd_data),
        .dep_flat(dep_flat), .dev_flat(dev_flat),
        .raddr(raddr), .rdur(rdur), .rkid(rkid)
    );

    kds_scoreboard #(.MAX_NODES(MAX_NODES)) u_sb (
        .dep_flat(dep_flat), .done_mask(done_mask), .issued_mask(issued_mask),
        .valid_mask(valid_mask), .ready(ready), .ready_any(ready_any)
    );

    assign free_mask = ~busy;

    kds_placer #(.MAX_NODES(MAX_NODES), .DEVICES(DEVICES),
                 .NIDW(NIDW), .DIDW(DIDW)) u_pl (
        .ready(ready), .dev_flat(dev_flat), .free_mask(free_mask),
        .sel_valid(sel_valid_raw), .sel_node(sel_node),
        .sel_dev(sel_dev), .sel_dev_oh(sel_dev_oh)
    );

    wire all_done = (done_mask == valid_mask);
    wire in_run   = (state == `KDS_S_RUN);
    wire deadlock = in_run && !all_done && !sel_valid_raw &&
                    (busy == {DEVICES{1'b0}});
    wire run_tick = in_run && !all_done && !deadlock;
    wire dispatch = run_tick && sel_valid_raw;

    kds_devq #(.DEVICES(DEVICES), .NIDW(NIDW), .DIDW(DIDW)) u_dq (
        .clk(clk), .rst_n(rst_n), .clear(launch), .tick_en(run_tick),
        .disp_valid(dispatch), .disp_dev(sel_dev), .disp_node(sel_node),
        .disp_dur(rdur),
        .busy(busy), .comp_valid(comp_valid), .comp_node_flat(comp_node_flat)
    );

    // devices occupied this tick: everything running, plus the slot being issued
    wire [DEVICES-1:0] occ = busy | (dispatch ? sel_dev_oh : {DEVICES{1'b0}});
    reg  [7:0]         conc;
    always @* begin
        conc = 8'd0;
        for (u = 0; u < DEVICES; u = u + 1)
            if (occ[u]) conc = conc + 8'd1;
    end

    // retirements of this tick as a scoreboard mask
    reg [MAX_NODES-1:0] comp_mask;
    always @* begin
        comp_mask = {MAX_NODES{1'b0}};
        for (u = 0; u < DEVICES; u = u + 1)
            if (comp_valid[u]) comp_mask[comp_node_flat[u*NIDW +: NIDW]] = 1'b1;
    end

    assign st_state = state;
    assign st_busy  = !idle_like;
    assign mem_clr  = launch;

    genvar gu;
    generate
        for (gu = 0; gu < DEVICES; gu = gu + 1) begin : g_db
            assign c_devbusy_flat[gu*32 +: 32] = devbusy[gu];
        end
    endgenerate

    // dependency bits that are illegal for this graph
    wire dep_bad_now = (|(dep_acc & ~valid_mask)) | dep_acc[f_node];

    // ------------------------------------------------------ memory requests
    assign rd_req   = (state == `KDS_S_FETCH) && (f_issue != f_total) &&
                      ((f_issue - f_ack) < OUTSTANDING);
    assign rd_addr  = nbase_q + {14'd0, f_issue, 2'b00};

    assign wr_req   = (state == `KDS_S_WB) && (w_issue != w_total) &&
                      ((w_issue - w_ack) < OUTSTANDING);
    assign wr_addr  = rbase_q + {14'd0, w_issue, 2'b00};
    assign wr_wdata = (w_issue[1:0] == 2'd0) ? start_t[wb_node] :
                      (w_issue[1:0] == 2'd1) ? fin_t[wb_node]   :
                      (w_issue[1:0] == 2'd2) ? {8'h01, {(8-DIDW){1'b0}},
                                                dev_of[wb_node], seq_of[wb_node]}
                                             : rkid;

    // ---------------------------------------------------------------- the FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= `KDS_S_IDLE;
            st_err      <= `KDS_E_NONE;
            ev_done     <= 1'b0;
            ev_err      <= 1'b0;
            n_q         <= {(NIDW+1){1'b0}};
            valid_mask  <= {MAX_NODES{1'b0}};
            nbase_q     <= 32'd0;
            rbase_q     <= 32'd0;
            done_mask   <= {MAX_NODES{1'b0}};
            issued_mask <= {MAX_NODES{1'b0}};
            tick        <= 32'd0;
            seq_q       <= 16'd0;
            f_issue     <= 16'd0;
            f_ack       <= 16'd0;
            f_total     <= 16'd0;
            f_node      <= {NIDW{1'b0}};
            f_pos       <= 16'd0;
            dep_acc     <= {MAX_NODES{1'b0}};
            dur_l       <= 16'd0;
            dev_l       <= {DEVICES{1'b0}};
            bad_dur     <= 1'b0;
            bad_dev     <= 1'b0;
            bad_dep     <= 1'b0;
            bad_bus     <= 1'b0;
            w_issue     <= 16'd0;
            w_ack       <= 16'd0;
            w_total     <= 16'd0;
            c_makespan  <= 32'd0; c_dispatched <= 32'd0; c_stall  <= 32'd0;
            c_depwait   <= 32'd0; c_maxconc    <= 32'd0; c_serial <= 32'd0;
            c_buscyc    <= 32'd0; c_fetchw     <= 32'd0; c_wbw    <= 32'd0;
            for (u = 0; u < DEVICES; u = u + 1) devbusy[u] <= 32'd0;
        end else begin
            ev_done <= 1'b0;
            ev_err  <= 1'b0;

            if (mem_err) bad_bus <= 1'b1;

            if (state == `KDS_S_FETCH || state == `KDS_S_WB)
                c_buscyc <= c_buscyc + 32'd1;

            case (state)
            // -------------------------------------------- IDLE / DONE / ERROR
            `KDS_S_IDLE, `KDS_S_DONE, `KDS_S_ERROR: begin
                if (start) begin
                    nbase_q     <= cfg_node_base;
                    rbase_q     <= cfg_rslt_base;
                    done_mask   <= {MAX_NODES{1'b0}};
                    issued_mask <= {MAX_NODES{1'b0}};
                    tick        <= 32'd0;
                    seq_q       <= 16'd0;
                    bad_dur     <= 1'b0;
                    bad_dev     <= 1'b0;
                    bad_dep     <= 1'b0;
                    bad_bus     <= 1'b0;
                    dep_acc     <= {MAX_NODES{1'b0}};
                    f_issue     <= 16'd0;
                    f_ack       <= 16'd0;
                    f_node      <= {NIDW{1'b0}};
                    f_pos       <= 16'd0;
                    w_issue     <= 16'd0;
                    w_ack       <= 16'd0;
                    st_err      <= `KDS_E_NONE;
                    c_makespan  <= 32'd0; c_dispatched <= 32'd0;
                    c_stall     <= 32'd0; c_depwait    <= 32'd0;
                    c_maxconc   <= 32'd0; c_serial     <= 32'd0;
                    c_buscyc    <= 32'd0; c_fetchw     <= 32'd0;
                    c_wbw       <= 32'd0;
                    for (u = 0; u < DEVICES; u = u + 1) devbusy[u] <= 32'd0;

                    if (cfg_num_nodes == 32'd0 || cfg_num_nodes > MAX_NODES) begin
                        st_err <= `KDS_E_LEN;
                        state  <= `KDS_S_ERROR;
                        ev_err <= 1'b1;
                    end else begin
                        n_q        <= cfg_num_nodes[NIDW:0];
                        valid_mask <= ~({MAX_NODES{1'b1}} << cfg_num_nodes[NIDW:0]);
                        f_total    <= cfg_num_nodes[15:0] * NODE_WORDS;
                        w_total    <= cfg_num_nodes[15:0] * 16'd4;
                        state      <= `KDS_S_FETCH;
                    end
                end
            end

            // ----------------------------------------------------------- FETCH
            `KDS_S_FETCH: begin
                if (rd_gnt) f_issue <= f_issue + 16'd1;

                if (rd_valid) begin
                    c_fetchw <= c_fetchw + 32'd1;
                    f_ack    <= f_ack + 16'd1;

                    if (f_pos == 16'd0) begin
                        dur_l <= rd_data[15:0];
                        dev_l <= rd_data[16 +: DEVICES];
                        if (rd_data[15:0] == 16'd0) bad_dur <= 1'b1;
                        if (rd_data[23:16] == 8'd0 ||
                            (rd_data[23:16] >> DEVICES) != 8'd0) bad_dev <= 1'b1;
                        c_serial <= c_serial + {16'd0, rd_data[15:0]} + 32'd1;
                    end else if (f_pos <= DEPW) begin
                        dep_acc[(f_pos-1)*32 +: 32] <= rd_data;
                    end

                    if (f_pos == NODE_WORDS-1) begin
                        // the record is complete - kds_node_mem latches it on
                        // this same edge, so only the checks remain here
                        if (dep_bad_now) bad_dep <= 1'b1;
                        dep_acc <= {MAX_NODES{1'b0}};
                        f_pos   <= 16'd0;
                        f_node  <= f_node + 1'b1;
                    end else begin
                        f_pos <= f_pos + 16'd1;
                    end

                    if (f_ack + 16'd1 == f_total) state <= `KDS_S_CHECK;
                end
            end

            // ----------------------------------------------------------- CHECK
            `KDS_S_CHECK: begin
                if (bad_bus) begin
                    st_err <= `KDS_E_BUS;  state <= `KDS_S_ERROR; ev_err <= 1'b1;
                end else if (bad_dur) begin
                    st_err <= `KDS_E_DUR;  state <= `KDS_S_ERROR; ev_err <= 1'b1;
                end else if (bad_dev) begin
                    st_err <= `KDS_E_DEV;  state <= `KDS_S_ERROR; ev_err <= 1'b1;
                end else if (bad_dep) begin
                    st_err <= `KDS_E_DEP;  state <= `KDS_S_ERROR; ev_err <= 1'b1;
                end else begin
                    state  <= `KDS_S_RUN;
                end
            end

            // ------------------------------------------------------------- RUN
            `KDS_S_RUN: begin
                if (all_done) begin
                    c_makespan <= tick;
                    state      <= `KDS_S_WB;
                end else if (deadlock) begin
                    st_err <= `KDS_E_CYCLE;
                    state  <= `KDS_S_ERROR;
                    ev_err <= 1'b1;
                end else begin
                    tick      <= tick + 32'd1;
                    done_mask <= done_mask | comp_mask;
                    for (u = 0; u < DEVICES; u = u + 1)
                        if (comp_valid[u])
                            fin_t[comp_node_flat[u*NIDW +: NIDW]] <= tick + 32'd1;

                    if (dispatch) begin
                        issued_mask[sel_node] <= 1'b1;
                        start_t[sel_node]     <= tick;
                        dev_of [sel_node]     <= sel_dev;
                        seq_of [sel_node]     <= seq_q;
                        seq_q                 <= seq_q + 16'd1;
                        c_dispatched          <= c_dispatched + 32'd1;
                    end else if (ready_any) begin
                        c_stall   <= c_stall   + 32'd1;
                    end else begin
                        c_depwait <= c_depwait + 32'd1;
                    end

                    for (u = 0; u < DEVICES; u = u + 1)
                        if (occ[u]) devbusy[u] <= devbusy[u] + 32'd1;
                    if ({24'd0, conc} > c_maxconc) c_maxconc <= {24'd0, conc};
                end
            end

            // ------------------------------------------------------- WRITEBACK
            `KDS_S_WB: begin
                if (wr_gnt) w_issue <= w_issue + 16'd1;
                if (wr_done) begin
                    c_wbw <= c_wbw + 32'd1;
                    w_ack <= w_ack + 16'd1;
                    if (w_ack + 16'd1 == w_total) begin
                        if (bad_bus || mem_err) begin
                            st_err  <= `KDS_E_BUS;
                            state   <= `KDS_S_ERROR;
                            ev_err  <= 1'b1;
                        end else begin
                            state   <= `KDS_S_DONE;
                            ev_done <= 1'b1;
                        end
                    end
                end
            end

            default: state <= `KDS_S_IDLE;
            endcase
        end
    end

endmodule
