// -----------------------------------------------------------------------------
// fir_datapath.v
// Transposed-form FIR filter datapath, signed fixed-point, one output sample
// per accepted input sample (steady state = 1 sample/clock).
//
//   y[n] = sum_{k=0..TAPS-1} h[k] * x[n-k]      (streaming, zero initial state)
//
// Transposed direct form: the incoming sample is broadcast to every tap
// multiplier, and each tap register holds a running partial sum that is passed
// down the chain. This keeps the critical path at one multiply + one add
// regardless of TAPS (the reason the transposed form is the textbook choice for
// a "deeply pipelined" FIR), unlike the direct form whose adder tree grows with
// TAPS.
//
//   acc[TAPS-1] <= h[TAPS-1]*x
//   acc[k]      <= h[k]*x + acc[k+1]          for k = TAPS-2 .. 0
//   y            = acc[0]
//
// Accumulator width is sized so the full-precision result never overflows:
//   ACC_WIDTH = DATA_WIDTH + COEF_WIDTH + ceil(log2(TAPS))
// so the datapath is bit-exact against a wide-integer software golden model.
//
// Handshake: a single-entry output register with a valid/ready interface. A
// new sample is accepted (s_valid & s_ready) only when the output slot is free
// or being drained this cycle, so no result is ever dropped under backpressure.
// `clr` synchronously zeroes the accumulator chain at a job boundary.
// -----------------------------------------------------------------------------
`default_nettype none

module fir_datapath #(
    parameter integer DATA_WIDTH = 16,
    parameter integer COEF_WIDTH = 16,
    parameter integer TAPS       = 8,
    parameter integer ACC_WIDTH  = DATA_WIDTH + COEF_WIDTH + $clog2(TAPS)
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          clr,          // flush accumulator state

    // coefficients, packed h[0] in the low bits, held stable during a job
    input  wire [TAPS*COEF_WIDTH-1:0]    coef_flat,

    // input sample stream
    input  wire                          s_valid,
    output wire                          s_ready,
    input  wire signed [DATA_WIDTH-1:0]  s_data,

    // output sample stream
    output reg                           m_valid,
    input  wire                          m_ready,
    output wire signed [ACC_WIDTH-1:0]   m_data
);
    localparam integer PROD_WIDTH = DATA_WIDTH + COEF_WIDTH;

    // Accept a new input when the output register is empty or draining this cycle.
    assign s_ready = ~m_valid | m_ready;
    wire   fire    = s_valid & s_ready;

    // Unpack coefficients into signed lanes.
    wire signed [COEF_WIDTH-1:0] coef [0:TAPS-1];
    genvar gi;
    generate
        for (gi = 0; gi < TAPS; gi = gi + 1) begin : g_coef
            assign coef[gi] = coef_flat[gi*COEF_WIDTH +: COEF_WIDTH];
        end
    endgenerate

    // Transposed accumulator chain.
    reg  signed [ACC_WIDTH-1:0] acc [0:TAPS-1];

    // Per-tap product, sign-extended to the accumulator width.
    wire signed [PROD_WIDTH-1:0] prod [0:TAPS-1];
    wire signed [ACC_WIDTH-1:0]  prod_ext [0:TAPS-1];
    generate
        for (gi = 0; gi < TAPS; gi = gi + 1) begin : g_prod
            assign prod[gi]     = coef[gi] * s_data;
            assign prod_ext[gi] = {{(ACC_WIDTH-PROD_WIDTH){prod[gi][PROD_WIDTH-1]}}, prod[gi]};
        end
    endgenerate

    integer k;
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            for (k = 0; k < TAPS; k = k + 1)
                acc[k] <= {ACC_WIDTH{1'b0}};
        end else if (fire) begin
            acc[TAPS-1] <= prod_ext[TAPS-1];
            for (k = 0; k < TAPS-1; k = k + 1)
                acc[k] <= prod_ext[k] + acc[k+1];
        end
    end

    // Output-register valid tracking.
    always @(posedge clk) begin
        if (!rst_n || clr) m_valid <= 1'b0;
        else if (fire)     m_valid <= 1'b1;   // a fresh result lands in acc[0]
        else if (m_ready)  m_valid <= 1'b0;   // drained with nothing to replace it
    end

    assign m_data = acc[0];
endmodule

`default_nettype wire
