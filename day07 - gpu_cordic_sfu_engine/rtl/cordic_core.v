// -----------------------------------------------------------------------------
// cordic_core.v
// One iterative CORDIC lane - the SFU's arithmetic engine. On a start pulse it
// latches the initial vector {x0,y0,z0} and a mode {is_hyp, is_vec}, then walks
// the ROM schedule one micro-rotation per clock: shift-and-add only, no
// multiplier in the loop. Circular rotation (drive z->0) yields cos/sin in x/y;
// hyperbolic rotation yields cosh/sinh; vectoring (drive y->0) yields the
// accumulated angle in z and the magnitude in x. The unified update selects the
// x-add sign from is_hyp and the micro-rotation direction from is_vec, so all
// six SFU functions run on this one datapath.
//
// Bit-identical to sfu_cordic() in sw/sfu_accel.h: 40-bit signed working regs,
// arithmetic (floor) shifts, the same per-step angle constants from cordic_rom.
// A result takes NC (circular) or NH (hyperbolic) cycles; done pulses for one
// clock with {xo,yo,zo} valid.
// -----------------------------------------------------------------------------
`default_nettype none

module cordic_core #(
    parameter ROMFILE = "tb/vectors/cordic_rom.hex"
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    start,
    input  wire                    is_hyp,
    input  wire                    is_vec,
    input  wire signed [39:0]      x0,
    input  wire signed [39:0]      y0,
    input  wire signed [39:0]      z0,

    output reg                     busy,
    output reg                     done,
    output wire signed [39:0]      xo,
    output wire signed [39:0]      yo,
    output wire signed [39:0]      zo
);
`include "sfu_const.vh"

    localparam ST_IDLE = 1'b0, ST_RUN = 1'b1;

    reg               state;
    reg signed [39:0] x, y, z;
    reg               hyp_r, vec_r;
    reg  [7:0]        base_r, nsteps_r, step;

    // schedule lookup for the current step
    wire [5:0]         shf;
    wire signed [31:0] ang;
    cordic_rom #(.ROMFILE(ROMFILE)) u_rom (
        .idx(base_r + step), .shf(shf), .ang(ang)
    );

    // one micro-rotation (combinational)
    wire signed [39:0] xs = x >>> shf;                 // arithmetic (floor)
    wire signed [39:0] ys = y >>> shf;
    wire signed [39:0] ang_ext = {{8{ang[31]}}, ang};  // Q4.28 -> 40-bit
    wire               pos = vec_r ? (y < 0) : (z >= 0);

    wire signed [39:0] xn = hyp_r ? (pos ? (x + ys) : (x - ys))
                                  : (pos ? (x - ys) : (x + ys));
    wire signed [39:0] yn = pos ? (y + xs) : (y - xs);
    wire signed [39:0] zn = pos ? (z - ang_ext) : (z + ang_ext);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE; busy <= 1'b0; done <= 1'b0;
            x <= 40'sd0; y <= 40'sd0; z <= 40'sd0;
            hyp_r <= 1'b0; vec_r <= 1'b0;
            base_r <= 8'd0; nsteps_r <= 8'd0; step <= 8'd0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        x <= x0; y <= y0; z <= z0;
                        hyp_r    <= is_hyp;
                        vec_r    <= is_vec;
                        base_r   <= is_hyp ? NC[7:0] : 8'd0;
                        nsteps_r <= is_hyp ? NH[7:0] : NC[7:0];
                        step     <= 8'd0;
                        busy     <= 1'b1;
                        state    <= ST_RUN;
                    end
                end
                ST_RUN: begin
                    x <= xn; y <= yn; z <= zn;   // apply this step's rotation
                    step <= step + 8'd1;
                    if (step == nsteps_r - 8'd1) begin
                        state <= ST_IDLE;
                        busy  <= 1'b0;
                        done  <= 1'b1;           // {x,y,z} now hold the result
                    end
                end
            endcase
        end
    end

    assign xo = x;
    assign yo = y;
    assign zo = z;
endmodule

`default_nettype wire
