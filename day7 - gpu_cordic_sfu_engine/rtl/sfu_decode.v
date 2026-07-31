// -----------------------------------------------------------------------------
// sfu_decode.v
// The per-function decode: it turns a request (op, a, b) into the CORDIC initial
// vector and mode, and turns the CORDIC result vector back into the two output
// words. This is where the SFU's "function table" lives - the CORDIC core itself
// is function-agnostic.
//
//  op          mode                init vector (x0,y0,z0)              outputs
//  --          ----                ----------------------              -------
//  SINCOS      circ / rotate       (1/Kc, 0, z)                        sin=y cos=x
//  EXP         hyp  / rotate       (1/Kh, 0, z)                     exp=x+y cosh=x
//  COSHSINH    hyp  / rotate       (1/Kh, 0, z)                    cosh=x sinh=y
//  ATAN2       circ / vector       (x/Kc, y/Kc, 0)              atan2=z  hypot=x
//  LN          hyp  / vector       ((w+1)/Kh, (w-1)/Kh, 0)             ln=2*z
//  SQRT        hyp  / vector       ((w+.25)/Kh, (w-.25)/Kh, 0)         sqrt=x
//
// The gain constant K is divided out by pre-scaling the initial vector with
// 1/Kc or 1/Kh (constant Q4.28 multiplies), so the CORDIC outputs are already
// correctly scaled and only an add (exp), a doubling (ln) or a passthrough
// remains. Bit-identical to sfu_eval() in sw/sfu_accel.h.
// -----------------------------------------------------------------------------
`default_nettype none

module sfu_decode (
    input  wire [2:0]         op,
    input  wire signed [31:0] a,
    input  wire signed [31:0] b,

    // -> CORDIC core
    output reg                is_hyp,
    output reg                is_vec,
    output reg  signed [39:0] x0,
    output reg  signed [39:0] y0,
    output reg  signed [39:0] z0,

    // <- CORDIC core
    input  wire signed [39:0] xo,
    input  wire signed [39:0] yo,
    input  wire signed [39:0] zo,
    output reg  signed [31:0] r0,
    output reg  signed [31:0] r1
);
`include "sfu_const.vh"

    localparam [2:0] OP_SINCOS   = 3'd0, OP_EXP  = 3'd1, OP_COSHSINH = 3'd2,
                     OP_ATAN2    = 3'd3, OP_LN   = 3'd4, OP_SQRT      = 3'd5;

    // ---- pre-scale operands (constant Q4.28 multiplies) ----
    // x-side and y-side each drive one multiply, with muxed constant/operand.
    reg  signed [31:0] xk, xv, yk, yv;
    always @(*) begin
        case (op)
            OP_ATAN2: begin xk = INV_KC; xv = b;        yk = INV_KC; yv = a;        end
            OP_LN:    begin xk = INV_KH; xv = a + ONE_Q; yk = INV_KH; yv = a - ONE_Q; end
            OP_SQRT:  begin xk = INV_KH; xv = a + QTR_Q; yk = INV_KH; yv = a - QTR_Q; end
            default:  begin xk = 32'sd0; xv = 32'sd0;   yk = 32'sd0; yv = 32'sd0;   end
        endcase
    end
    wire signed [63:0] xprod = xk * xv;
    wire signed [63:0] yprod = yk * yv;
    wire signed [39:0] x_mul = xprod >>> FBITS;   // Q4.28 result, 40-bit
    wire signed [39:0] y_mul = yprod >>> FBITS;

    wire signed [39:0] invkc_ext = {{8{INV_KC[31]}}, INV_KC};
    wire signed [39:0] invkh_ext = {{8{INV_KH[31]}}, INV_KH};
    wire signed [39:0] a_ext     = {{8{a[31]}}, a};

    // ---- initial vector + mode ----
    always @(*) begin
        case (op)
            OP_SINCOS:   begin is_hyp=1'b0; is_vec=1'b0; x0=invkc_ext; y0=40'sd0; z0=a_ext; end
            OP_EXP,
            OP_COSHSINH: begin is_hyp=1'b1; is_vec=1'b0; x0=invkh_ext; y0=40'sd0; z0=a_ext; end
            OP_ATAN2:    begin is_hyp=1'b0; is_vec=1'b1; x0=x_mul;     y0=y_mul;  z0=40'sd0; end
            OP_LN,
            OP_SQRT:     begin is_hyp=1'b1; is_vec=1'b1; x0=x_mul;     y0=y_mul;  z0=40'sd0; end
            default:     begin is_hyp=1'b0; is_vec=1'b0; x0=40'sd0;    y0=40'sd0; z0=40'sd0; end
        endcase
    end

    // ---- result mapping (truncate 40-bit working value to Q4.28 word) ----
    wire signed [39:0] exp_sum = xo + yo;
    wire signed [39:0] ln_dbl  = zo <<< 1;
    always @(*) begin
        case (op)
            OP_SINCOS:   begin r0 = yo[31:0];      r1 = xo[31:0]; end
            OP_EXP:      begin r0 = exp_sum[31:0]; r1 = xo[31:0]; end
            OP_COSHSINH: begin r0 = xo[31:0];      r1 = yo[31:0]; end
            OP_ATAN2:    begin r0 = zo[31:0];      r1 = xo[31:0]; end
            OP_LN:       begin r0 = ln_dbl[31:0];  r1 = 32'sd0;   end
            OP_SQRT:     begin r0 = xo[31:0];      r1 = 32'sd0;   end
            default:     begin r0 = 32'sd0;        r1 = 32'sd0;   end
        endcase
    end
endmodule

`default_nettype wire
