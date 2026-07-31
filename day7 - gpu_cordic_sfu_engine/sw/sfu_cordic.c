/* ---------------------------------------------------------------------------
 * sfu_cordic.c
 * The CORDIC schedule: builds the fixed-point angle tables and gains once (from
 * libm, rounded to Q4.28), and emits the very same integers to the Verilog ROM
 * so hardware and software iterate on identical constants. This is the single
 * point where the constants are defined; everything else (golden, baseline,
 * RTL) consumes them, which is what makes the hardware bit-exact against the
 * software golden.
 *
 * Circular steps use shifts 0..NC-1 with angles atan(2^-i). Hyperbolic steps use
 * shifts 1..27 with angles atanh(2^-i); the shifts 4 and 13 are repeated (the
 * Walther convergence condition for hyperbolic CORDIC), giving NH=29 steps.
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <math.h>
#include "sfu_accel.h"

int32_t sfu_atan_tab[SFU_NC];
int32_t sfu_hyp_shf[SFU_NH];
int32_t sfu_atanh_tab[SFU_NH];
int32_t sfu_invKc;
int32_t sfu_invKh;

static int32_t toQ(double d) { return (int32_t)llround(d * (double)SFU_ONE_Q); }

void sfu_init(void)
{
    /* circular: shifts 0 .. NC-1 */
    double Kc = 1.0;
    for (int i = 0; i < (int)SFU_NC; i++) {
        sfu_atan_tab[i] = toQ(atan(ldexp(1.0, -i)));
        Kc *= sqrt(1.0 + ldexp(1.0, -2 * i));
    }
    sfu_invKc = toQ(1.0 / Kc);

    /* hyperbolic: shifts 1 .. 27 with repeats at 4 and 13 */
    double Kh = 1.0;
    int    n = 0, next_rep = 4;
    for (int i = 1; i <= 27; i++) {
        sfu_hyp_shf[n]   = i;
        sfu_atanh_tab[n] = toQ(atanh(ldexp(1.0, -i)));
        Kh *= sqrt(1.0 - ldexp(1.0, -2 * i));
        n++;
        if (i == next_rep) {                 /* repeat this step */
            sfu_hyp_shf[n]   = i;
            sfu_atanh_tab[n] = toQ(atanh(ldexp(1.0, -i)));
            Kh *= sqrt(1.0 - ldexp(1.0, -2 * i));
            n++;
            next_rep = 3 * next_rep + 1;
        }
    }
    sfu_invKh = toQ(1.0 / Kh);               /* n now equals SFU_NH */
}

/* Emit the CORDIC ROM as $readmemh hex: one 64-bit word per step,
 * [63:32] = shift amount, [31:0] = angle (Q4.28). Circular steps first
 * (indices 0..NC-1), then hyperbolic steps (indices NC..NROM-1). */
int sfu_emit_rom(const char *rom_path)
{
    FILE *f = fopen(rom_path, "w");
    if (!f) return 1;
    for (int i = 0; i < (int)SFU_NC; i++)
        fprintf(f, "%08x%08x\n", (uint32_t)i, (uint32_t)sfu_atan_tab[i]);
    for (int i = 0; i < (int)SFU_NH; i++)
        fprintf(f, "%08x%08x\n",
                (uint32_t)sfu_hyp_shf[i], (uint32_t)sfu_atanh_tab[i]);
    fclose(f);
    return 0;
}
