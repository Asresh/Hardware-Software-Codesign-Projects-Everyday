// ===========================================================================
// mxq_mx_unit - the custom-0 functional unit.
//
// Five instructions, all register-to-register, all combinational, all in the
// execute stage beside the ALU.  There is no state, no handshake and no
// latency: an MX cast instruction costs exactly what an ADD costs, which is
// the entire reason for building it this way instead of as an accelerator
// behind a bus.  Two bf16 elements are processed per instruction because a
// 32-bit register holds two, so the unit's width is set by the register file
// rather than chosen.
//
//   MXAMAX  rd, rs1, rs2   rd = max(|rs1.lo|, |rs1.hi|, rs2)  - block amax
//   MXSCALE rd, rs1        rd = E8M0 shared scale for amax rs1
//   MXQ4    rd, rs1, rs2   rd = two E2M1 codes from rs1 at scale rs2
//   MXDQ    rd, rs1, rs2   rd = two bf16 from the codes in rs1 at scale rs2
//   MXPK    rd, rs1, rs2   rd = (rs1 >> 8) | (rs2[7:0] << 24)  - byte pack
//
// The longest path is MXQ4: exponent subtract -> variable shift -> seven
// parallel magnitude comparisons -> a 3-bit population count.  The comparisons
// are independent of each other, so the depth is one shifter plus one adder
// tree, not a search.
// ===========================================================================
`include "mxq_defs.vh"

module mxq_mx_unit (
    input  wire [2:0]  f3,
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    output reg  [31:0] out,
    output reg         legal
);

    // ---- magnitude of a bf16, with this design's edge rules ---------------
    // Inf and NaN clamp to the largest finite magnitude so one bad element
    // rescales its block instead of erasing it; subnormals flush to zero.
    function [14:0] mag_of;
        input [15:0] b;
        begin
            if (b[14:7] == 8'hFF)      mag_of = `MXQ_BF16_MAXF;
            else if (b[14:7] == 8'h00) mag_of = 15'd0;
            else                       mag_of = b[14:0];
        end
    endfunction

    // ---- E2M1 quantiser ---------------------------------------------------
    function [3:0] quant;
        input [15:0] b;
        input [7:0]  x;
        reg               s;
        reg [14:0]        mag;
        reg [7:0]         ev;
        reg [7:0]         sig;
        reg signed [10:0] sh;
        reg [8:0]         n;
        reg [11:0]        u, us;
        reg               sticky;
        reg [7:0]         lowmask;
        reg [2:0]         c;
        begin
            s   = b[15];
            mag = (b[14:7] == 8'hFF) ? `MXQ_BF16_MAXF : b[14:0];
            ev  = mag[14:7];
            if (ev == 8'h00) begin
                quant = {s, 3'b000};                 // zero or subnormal
            end else begin
                sig = {1'b1, mag[6:0]};
                sh  = $signed({3'b000, ev}) - $signed({3'b000, x}) + 11'sd1;
                if (sh > 11'sd4) begin
                    u = 12'hFFF; sticky = 1'b0;      // scale mismatch: saturate
                end else if (sh >= 11'sd0) begin
                    u = {4'b0000, sig} << sh[2:0];
                    sticky = 1'b0;
                end else begin
                    n = -sh;
                    if (n >= 9'd32) begin
                        u = 12'd0; sticky = 1'b1;    // everything shifted out
                    end else begin
                        u       = (n >= 9'd8) ? 12'd0 : ({4'b0000, sig} >> n[2:0]);
                        lowmask = (n >= 9'd8) ? 8'hFF : ((8'h01 << n[2:0]) - 8'h01);
                        sticky  = |(sig & lowmask);
                    end
                end

                // Round to nearest, ties to the even code.  The pair either
                // side of threshold k is (k, k+1), so the even member is k for
                // even k and k+1 for odd k - which is exactly the difference
                // between a strict and a non-strict compare.  Adding the
                // sticky bit to u makes "strictly above the midpoint"
                // expressible without a second comparison.
                us = u + {11'b0, sticky};
                c  = ((us >  12'd64)   ? 3'd1 : 3'd0)
                   + ((u  >= 12'd192)  ? 3'd1 : 3'd0)
                   + ((us >  12'd320)  ? 3'd1 : 3'd0)
                   + ((u  >= 12'd448)  ? 3'd1 : 3'd0)
                   + ((us >  12'd640)  ? 3'd1 : 3'd0)
                   + ((u  >= 12'd896)  ? 3'd1 : 3'd0)
                   + ((us >  12'd1280) ? 3'd1 : 3'd0);
                quant = {s, c};
            end
        end
    endfunction

    // ---- E2M1 dequantiser -------------------------------------------------
    function [15:0] dequant;
        input [3:0] code;
        input [7:0] x;
        reg               s;
        reg [2:0]         c;
        reg signed [10:0] e;
        reg [6:0]         man;
        begin
            s = code[3];
            c = code[2:0];
            if (c == 3'd0) begin
                dequant = {s, 15'd0};
            end else begin
                // exponent offset is (c >> 1) - 1, mantissa is 0x40 for the
                // three odd codes above 1 (1.5, 3, 6)
                e   = $signed({3'b000, x}) + $signed({8'd0, c[2:1]}) - 11'sd1;
                man = (c[0] & (|c[2:1])) ? 7'h40 : 7'h00;
                if (e <= 11'sd0)        dequant = {s, 15'd0};
                else if (e >= 11'sd255) dequant = {s, `MXQ_BF16_MAXF};
                else                    dequant = {s, e[7:0], man};
            end
        end
    endfunction

    // ---- shared scale -----------------------------------------------------
    function [7:0] shared_scale;
        input [14:0] amax;
        reg [7:0] ea;
        begin
            ea = amax[14:7];
            if (ea == 8'h00)                     shared_scale = 8'h00;
            else if (ea <= `MXQ_EMAX_ELEM)       shared_scale = 8'h00;
            else if (ea == 8'hFF)                shared_scale = 8'hFE - `MXQ_EMAX_ELEM;
            else                                 shared_scale = ea - `MXQ_EMAX_ELEM;
        end
    endfunction

    wire [14:0] m_lo = mag_of(rs1[15:0]);
    wire [14:0] m_hi = mag_of(rs1[31:16]);
    wire [14:0] m_in = rs2[14:0];
    wire [14:0] m_ab = (m_lo > m_hi) ? m_lo : m_hi;
    wire [14:0] m_mx = (m_ab > m_in) ? m_ab : m_in;

    always @* begin
        legal = 1'b1;
        case (f3)
            `MXQ_F3_AMAX:  out = {17'd0, m_mx};
            `MXQ_F3_SCALE: out = {24'd0, shared_scale(rs1[14:0])};
            `MXQ_F3_Q4:    out = {24'd0, quant(rs1[31:16], rs2[7:0]),
                                         quant(rs1[15:0],  rs2[7:0])};
            `MXQ_F3_DQ:    out = {dequant(rs1[7:4], rs2[7:0]),
                                  dequant(rs1[3:0], rs2[7:0])};
            `MXQ_F3_PK:    out = {rs2[7:0], rs1[31:8]};
            default:     begin out = 32'd0; legal = 1'b0; end
        endcase
    end

endmodule
