/* Author: Asresh */
#include "kinematics.h"
#include <math.h>
uint64_t kin_scalar_cycles(size_t count) { return UINT64_C(400) + UINT64_C(6000)*count; }
int kin_scalar_reference(const struct kin_joint *joints, size_t count, struct kin_result *result) {
    double heading=0.0, x=0.0, y=0.0;
    size_t i;
    if (joints==NULL || result==NULL || count==0u || count>KIN_MAX_JOINTS) return -1;
    for (i=0; i<count; ++i) {
        double length=(double)joints[i].length_q8/256.0;
        heading += (double)joints[i].angle_q13/8192.0;
        x += length*cos(heading); y += length*sin(heading);
    }
    result->x_q8=(int32_t)llround(x*256.0); result->y_q8=(int32_t)llround(y*256.0);
    result->cycles=(uint32_t)kin_scalar_cycles(count); result->joints=(uint8_t)count;
    return 0;
}
