/* Author: Asresh */
#ifndef KINEMATICS_H
#define KINEMATICS_H
#include <stddef.h>
#include <stdint.h>
#define KIN_MAX_JOINTS 8u
#define KIN_PI_Q13 INT32_C(25736)
enum kin_opcode { KIN_NOP=0x00, KIN_RESET=0x01, KIN_CONFIG=0x10, KIN_PUSH=0x20,
    KIN_START=0x30, KIN_STATUS=0x40, KIN_X=0x41, KIN_Y=0x42,
    KIN_CYCLES=0x43, KIN_JOINTS=0x44, KIN_ACK=0x50 };
struct kin_joint { uint16_t length_q8; int16_t angle_q13; };
struct kin_result { int32_t x_q8; int32_t y_q8; uint32_t cycles; uint8_t joints; };
struct kin_bus { void *context; int (*exchange)(void *, uint64_t, uint64_t *); int (*irq_level)(void *); };
int kin_reference(const struct kin_joint *joints, size_t count, struct kin_result *result);
uint64_t kin_scalar_cycles(size_t count);
int kin_scalar_reference(const struct kin_joint *joints, size_t count, struct kin_result *result);
int kin_run(struct kin_bus *bus, const struct kin_joint *joints, size_t count,
            uint32_t timeout_polls, struct kin_result *result);
#endif
