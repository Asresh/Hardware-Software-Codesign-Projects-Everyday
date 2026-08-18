/* Author: Asresh */
#ifndef REPLAY_GUARD_H
#define REPLAY_GUARD_H
#include <stdint.h>
#include <stddef.h>
#define RG_ENTRIES 32u
#define RG_CONTEXTS 8u
#define RG_CTRL 0x00u
#define RG_META 0x04u
#define RG_NONCE0 0x08u
#define RG_RESULT 0x18u
#define RG_ACCEPTED 0x1cu
#define RG_REPLAYS 0x20u
#define RG_STALE 0x24u
#define RG_VERSION 0x28u
enum rg_op { RG_CHECK=0, RG_SET_EPOCH=1, RG_FLUSH_CONTEXT=2, RG_FLUSH_ALL=3 };
enum rg_reason { RG_ACCEPT=0, RG_REPLAY=1, RG_STALE_EPOCH=2, RG_EPOCH_SET=3, RG_FLUSHED=4 };
struct rg_request { uint8_t op, context; uint16_t epoch; uint32_t nonce[4]; };
struct rg_result { uint8_t accept, reason, slot; };
struct rg_entry { uint8_t valid, context; uint16_t epoch; uint32_t nonce[4]; };
struct rg_model { struct rg_entry entries[RG_ENTRIES]; uint16_t floor[RG_CONTEXTS]; uint8_t replace; uint32_t accepted,replays,stale; };
void rg_model_reset(struct rg_model *m);
struct rg_result rg_model_step(struct rg_model *m,const struct rg_request *q);
uint64_t rg_baseline_cycles(const struct rg_request *q,const struct rg_model *before);
typedef void (*rg_write_fn)(void *,uint32_t,uint32_t);
typedef uint32_t (*rg_read_fn)(void *,uint32_t);
int rg_submit(void *cookie,rg_write_fn wr,rg_read_fn rd,const struct rg_request *q,struct rg_result *r,uint32_t timeout);
#endif
