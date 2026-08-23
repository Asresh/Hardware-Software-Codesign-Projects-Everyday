/* Author: Asresh */
#include "kinematics.h"
static const int32_t atan_q13[16] = {6434,3798,2007,1019,511,256,128,64,32,16,8,4,2,1,1,0};
static int32_t sar32(int32_t value, unsigned shift) {
    int64_t magnitude;
    if (shift == 0u) return value;
    if (value >= 0) return value / (int32_t)(UINT32_C(1) << shift);
    magnitude = -(int64_t)value;
    return (int32_t)(-((magnitude + ((INT64_C(1) << shift) - 1)) / (INT64_C(1) << shift)));
}
static int32_t sar64_to32(int64_t value, unsigned shift) {
    uint64_t magnitude;
    if (value >= 0) return (int32_t)(value / (INT64_C(1) << shift));
    magnitude = (uint64_t)(-value);
    return (int32_t)(-((int64_t)((magnitude + ((UINT64_C(1) << shift) - 1u)) >> shift)));
}
static void cordic(int32_t angle, int32_t *cosine, int32_t *sine) {
    int32_t x, y = 0, z = angle;
    unsigned i;
    if (z > KIN_PI_Q13/2) { x = -19898; z -= KIN_PI_Q13; }
    else if (z < -KIN_PI_Q13/2) { x = -19898; z += KIN_PI_Q13; }
    else x = 19898;
    for (i = 0; i < 16u; ++i) {
        int32_t xs = sar32(y,i), ys = sar32(x,i), nx, ny;
        if (z < 0) { nx=x+xs; ny=y-ys; z+=atan_q13[i]; }
        else { nx=x-xs; ny=y+ys; z-=atan_q13[i]; }
        x=nx; y=ny;
    }
    *cosine=x; *sine=y;
}
int kin_reference(const struct kin_joint *joints, size_t count, struct kin_result *result) {
    int32_t heading=0, x=0, y=0;
    size_t i;
    if (joints==NULL || result==NULL || count==0u || count>KIN_MAX_JOINTS) return -1;
    for (i=0; i<count; ++i) {
        int32_t c, s;
        heading += joints[i].angle_q13;
        if (heading > KIN_PI_Q13) heading -= 2*KIN_PI_Q13;
        else if (heading < -KIN_PI_Q13) heading += 2*KIN_PI_Q13;
        cordic(heading,&c,&s);
        x += sar64_to32((int64_t)joints[i].length_q8*c,15u);
        y += sar64_to32((int64_t)joints[i].length_q8*s,15u);
    }
    result->x_q8=x; result->y_q8=y; result->cycles=0; result->joints=(uint8_t)count;
    return 0;
}
