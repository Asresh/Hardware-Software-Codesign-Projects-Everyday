// ============================================================================
// kvp_tlb.v - set-associative KV-block translation cache (the "block-table TLB")
//
//   Key         : {seq_id[SEQ_W-1:0], logical_block[LOG_W-1:0]}
//   Index       : the low SET_BITS of the key (low bits of the logical block, so
//                 a sequence's consecutive blocks spread across all sets)
//   Tag         : the remaining key bits
//   Data        : the physical KV block number
//   Replacement : true LRU - a per-set move-to-front order vector; an invalid
//                 way is always preferred over the LRU victim (lowest index
//                 first) so a cold cache fills deterministically.
//
//   All WAYS tags of the indexed set are compared in parallel, so a probe is
//   combinational: `probe_hit`/`probe_phys` are valid in the same cycle the key
//   is presented.  The single probe port is shared by lookup, fill and
//   invalidate, exactly as the core's FSM uses it:
//
//     touch_en  : hit - promote the hit way to MRU
//     fill_en   : miss - install {tag, fill_phys} into the victim way, MRU
//     inv_en    : drop the entry for probe_key if present (block freed)
//     flush_en  : invalidate every way (sequence swap-out / cache flush)
//
//   Priority is flush > fill > inv > touch; the core never asserts two at once.
// ============================================================================
`default_nettype none

module kvp_tlb #(
    parameter integer SETS   = 16,
    parameter integer WAYS   = 4,
    parameter integer KEY_W  = 28,
    parameter integer PHYS_W = 24
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire [KEY_W-1:0]  probe_key,
    output wire              probe_hit,
    output wire [PHYS_W-1:0] probe_phys,

    input  wire              touch_en,
    input  wire              fill_en,
    input  wire [PHYS_W-1:0] fill_phys,
    input  wire              inv_en,
    input  wire              flush_en
);
    // ---- derived geometry ----
    localparam integer SET_BITS = (SETS <=  2) ? 1 :
                                 (SETS <=  4) ? 2 :
                                 (SETS <=  8) ? 3 :
                                 (SETS <= 16) ? 4 :
                                 (SETS <= 32) ? 5 :
                                 (SETS <= 64) ? 6 : 7;
    localparam integer WAY_BITS = (WAYS <=  2) ? 1 :
                                 (WAYS <=  4) ? 2 :
                                 (WAYS <=  8) ? 3 : 4;
    localparam integer TAG_W    = KEY_W - SET_BITS;
    localparam integer ORD_W    = WAYS * WAY_BITS;

    // ---- storage ----
    reg              ent_valid [0:SETS*WAYS-1];
    reg [TAG_W-1:0]  ent_tag   [0:SETS*WAYS-1];
    reg [PHYS_W-1:0] ent_phys  [0:SETS*WAYS-1];
    reg [ORD_W-1:0]  ord       [0:SETS-1];   // slot 0 = MRU, slot WAYS-1 = LRU

    // ---- probe decode ----
    wire [SET_BITS-1:0] p_set = probe_key[SET_BITS-1:0];
    wire [TAG_W-1:0]    p_tag = probe_key[KEY_W-1:SET_BITS];

    reg                hit_r;
    reg [WAY_BITS-1:0] hit_way_r;
    reg [PHYS_W-1:0]   hit_phys_r;
    integer            w;
    always @(*) begin
        hit_r      = 1'b0;
        hit_way_r  = {WAY_BITS{1'b0}};
        hit_phys_r = {PHYS_W{1'b0}};
        for (w = 0; w < WAYS; w = w + 1) begin
            if (ent_valid[p_set*WAYS + w] && (ent_tag[p_set*WAYS + w] == p_tag)) begin
                hit_r      = 1'b1;
                hit_way_r  = w;                     // truncates to WAY_BITS
                hit_phys_r = ent_phys[p_set*WAYS + w];
            end
        end
    end
    assign probe_hit  = hit_r;
    assign probe_phys = hit_phys_r;

    // ---- victim selection: lowest invalid way, else LRU ----
    reg                any_inval;
    reg [WAY_BITS-1:0] inval_way;
    integer            v;
    always @(*) begin
        any_inval = 1'b0;
        inval_way = {WAY_BITS{1'b0}};
        for (v = WAYS-1; v >= 0; v = v - 1) begin  // descending: lowest index wins
            if (!ent_valid[p_set*WAYS + v]) begin
                any_inval = 1'b1;
                inval_way = v;
            end
        end
    end
    wire [WAY_BITS-1:0] lru_way    = ord[p_set][(WAYS-1)*WAY_BITS +: WAY_BITS];
    wire [WAY_BITS-1:0] victim_way = any_inval ? inval_way : lru_way;

    // ---- identity order vector (reset / flush state) ----
    wire [ORD_W-1:0] ident;
    genvar q;
    generate
        for (q = 0; q < WAYS; q = q + 1) begin : g_ident
            assign ident[q*WAY_BITS +: WAY_BITS] = q;   // truncates to WAY_BITS
        end
    endgenerate

    // ---- move-to-front over the per-set order vector ----
    function [ORD_W-1:0] mtf;
        input [ORD_W-1:0]    cur;
        input [WAY_BITS-1:0] way;
        integer i, k;
        reg [ORD_W-1:0] o;
        begin
            o = {ORD_W{1'b0}};
            o[0 +: WAY_BITS] = way;
            k = 1;
            for (i = 0; i < WAYS; i = i + 1) begin
                if (cur[i*WAY_BITS +: WAY_BITS] != way) begin
                    o[k*WAY_BITS +: WAY_BITS] = cur[i*WAY_BITS +: WAY_BITS];
                    k = k + 1;
                end
            end
            mtf = o;
        end
    endfunction

    // ---- update ----
    integer s, j;
    always @(posedge clk) begin
        if (!rst_n || flush_en) begin
            for (s = 0; s < SETS; s = s + 1) begin
                ord[s] <= ident;
                for (j = 0; j < WAYS; j = j + 1)
                    ent_valid[s*WAYS + j] <= 1'b0;
            end
        end else if (fill_en) begin
            ent_valid[p_set*WAYS + victim_way] <= 1'b1;
            ent_tag  [p_set*WAYS + victim_way] <= p_tag;
            ent_phys [p_set*WAYS + victim_way] <= fill_phys;
            ord[p_set] <= mtf(ord[p_set], victim_way);
        end else if (inv_en) begin
            if (hit_r) ent_valid[p_set*WAYS + hit_way_r] <= 1'b0;
        end else if (touch_en) begin
            if (hit_r) ord[p_set] <= mtf(ord[p_set], hit_way_r);
        end
    end
endmodule

`default_nettype wire
