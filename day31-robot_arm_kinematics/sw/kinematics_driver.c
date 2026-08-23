/* Author: Asresh */
#include "kinematics.h"
static int command(struct kin_bus *bus, uint8_t op, uint32_t data, uint64_t *reply) {
    uint64_t rx=0;
    if (bus==NULL || bus->exchange==NULL) return -1;
    if (bus->exchange(bus->context,((uint64_t)op<<32)|data,&rx)!=0) return -2;
    if (reply!=NULL) *reply=rx;
    return 0;
}
static int read_register(struct kin_bus *bus, uint8_t op, uint32_t *value) {
    uint64_t reply;
    if (value==NULL || command(bus,op,0,NULL)!=0 || command(bus,KIN_NOP,0,&reply)!=0) return -1;
    if ((uint8_t)(reply>>32)!=op) return -2;
    *value=(uint32_t)reply;
    return 0;
}
int kin_run(struct kin_bus *bus, const struct kin_joint *joints, size_t count,
            uint32_t timeout_polls, struct kin_result *result) {
    size_t i; uint32_t value; uint32_t polls=0;
    if (bus==NULL || joints==NULL || result==NULL || count==0u || count>KIN_MAX_JOINTS || timeout_polls==0u) return -1;
    if (command(bus,KIN_RESET,0,NULL)!=0 || command(bus,KIN_CONFIG,(uint32_t)count|UINT32_C(0x100),NULL)!=0) return -2;
    for (i=0; i<count; ++i) {
        uint32_t payload=((uint32_t)joints[i].length_q8<<16)|(uint16_t)joints[i].angle_q13;
        if (command(bus,KIN_PUSH,payload,NULL)!=0) return -2;
    }
    if (command(bus,KIN_START,0,NULL)!=0) return -2;
    while (polls++<timeout_polls) {
        int level=bus->irq_level==NULL ? 0 : bus->irq_level(bus->context);
        if (level<0) return -2;
        if (level!=0) break;
    }
    if (polls>timeout_polls) return -3;
    if (read_register(bus,KIN_X,&value)!=0) return -2;
    result->x_q8=(int32_t)value;
    if (read_register(bus,KIN_Y,&value)!=0) return -2;
    result->y_q8=(int32_t)value;
    if (read_register(bus,KIN_CYCLES,&result->cycles)!=0) return -2;
    if (read_register(bus,KIN_JOINTS,&value)!=0) return -2;
    result->joints=(uint8_t)value;
    if (command(bus,KIN_ACK,0,NULL)!=0) return -2;
    return 0;
}
