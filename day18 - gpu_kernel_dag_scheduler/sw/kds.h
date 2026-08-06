/* ===========================================================================
 * kds.h - multi-GPU kernel-DAG scheduler: shared ABI, register map, golden
 *         model and cost-model baseline declarations.
 *
 * The same header is used by
 *   - the host vector generator / golden model (kds_host.c, kds_model.c),
 *   - the software-only baseline scheduler   (kds_baseline.c),
 *   - the bare-metal driver                  (kds_driver.c),
 * so the register offsets, the node record layout and the scheduling
 * semantics have exactly one definition.
 * ===========================================================================
 */
#ifndef KDS_H
#define KDS_H

#include <stdint.h>

/* ---------------------------------------------------------------- geometry */
#ifndef KDS_MAX_NODES
#define KDS_MAX_NODES 64          /* scoreboard depth (CAM entries)          */
#endif
#ifndef KDS_DEVICES
#define KDS_DEVICES 4             /* execution slots = GPUs / stream queues  */
#endif

#define KDS_DEPW        ((KDS_MAX_NODES + 31) / 32)  /* dep-mask words       */
#define KDS_NODE_WORDS  (KDS_DEPW + 2)               /* words per node record*/
#define KDS_RSLT_WORDS  4                            /* words per result rec */

/* --------------------------------------------------- node record in memory
 *  w0        : { 8'b flags(rsvd) , 8'b dev_mask , 16'b duration }
 *  w1..wDEPW : dependency bitmask, bit j == 1 -> node j must retire first
 *  wDEPW+1   : kernel id (opaque, echoed into the result record)
 */
#define KDS_W0_DUR(w)   ((uint16_t)((w) & 0xffffu))
#define KDS_W0_DEV(w)   ((uint8_t)(((w) >> 16) & 0xffu))
#define KDS_W0_PACK(dur, dev) (((uint32_t)(dur) & 0xffffu) | (((uint32_t)(dev) & 0xffu) << 16))

/* ------------------------------------------------- result record in memory
 *  w0 : start tick   (tick the node was issued)
 *  w1 : finish tick  (tick its dependents became eligible)
 *  w2 : { 8'b flags , 8'b device , 16'b dispatch sequence number }
 *  w3 : kernel id echo
 */
#define KDS_R2_PACK(seq, dev, fl) (((uint32_t)(seq) & 0xffffu) | (((uint32_t)(dev) & 0xffu) << 16) \
                                   | (((uint32_t)(fl) & 0xffu) << 24))
#define KDS_R2_SEQ(w)   ((uint16_t)((w) & 0xffffu))
#define KDS_R2_DEV(w)   ((uint8_t)(((w) >> 16) & 0xffu))
#define KDS_R2_FLAGS(w) ((uint8_t)(((w) >> 24) & 0xffu))
#define KDS_FLAG_EXEC   0x01u

/* ------------------------------------------------------------ register map */
#define KDS_CTRL         0x00u   /* W1S: [0] START (self clearing)            */
#define KDS_STATUS       0x04u   /* RO : [0] BUSY [1] DONE [2] ERR [6:4] state
                                          [11:8] error code                   */
#define KDS_NUM_NODES    0x08u   /* RW : nodes in this graph launch           */
#define KDS_NODE_BASE    0x0Cu   /* RW : byte address of the node array       */
#define KDS_RSLT_BASE    0x10u   /* RW : byte address of the result array      */
#define KDS_IRQ_STATUS   0x14u   /* RW1C: [0] GRAPH_DONE [1] ERROR            */
#define KDS_IRQ_ENABLE   0x18u   /* RW                                        */
#define KDS_MAKESPAN     0x1Cu   /* RO : scheduler ticks of the RUN phase     */
#define KDS_DISPATCHED   0x20u   /* RO : nodes issued                         */
#define KDS_STALL_TICKS  0x24u   /* RO : ready but every allowed device busy  */
#define KDS_DEPWAIT_TICK 0x28u   /* RO : nothing ready (dependency stall)     */
#define KDS_MAX_CONC     0x2Cu   /* RO : peak simultaneously occupied devices */
#define KDS_SERIAL_TICKS 0x30u   /* RO : sum over nodes of (duration + 1)     */
#define KDS_BUS_CYCLES   0x34u   /* RO : cycles spent in FETCH + WRITEBACK    */
#define KDS_FETCH_WORDS  0x38u   /* RO : words read  from the node array      */
#define KDS_WB_WORDS     0x3Cu   /* RO : words written to the result array    */
#define KDS_DEV_BUSY0    0x40u   /* RO : per-device occupied ticks, +4 each   */
#define KDS_CAPS         0x60u   /* RO : { 16'b MAX_NODES , 8'b0 , 8'b DEVICES } */

#define KDS_DEV_BUSY(i)  (KDS_DEV_BUSY0 + 4u * (uint32_t)(i))

/* status / irq bits */
#define KDS_ST_BUSY      0x00000001u
#define KDS_ST_DONE      0x00000002u
#define KDS_ST_ERR       0x00000004u
#define KDS_ST_STATE(s)  (((s) >> 4) & 0x7u)
#define KDS_ST_ERRC(s)   (((s) >> 8) & 0xfu)
#define KDS_IRQ_DONE     0x00000001u
#define KDS_IRQ_ERR      0x00000002u
#define KDS_CTRL_START   0x00000001u

/* error codes (also the STATUS[11:8] field) */
#define KDS_ERR_NONE     0
#define KDS_ERR_LEN      1      /* num_nodes == 0 or > MAX_NODES             */
#define KDS_ERR_DUR      2      /* a node declared a zero duration           */
#define KDS_ERR_DEV      3      /* empty affinity mask, or a device that does
                                   not exist on this scheduler               */
#define KDS_ERR_DEP      4      /* dependency on a node >= num_nodes, or self */
#define KDS_ERR_CYCLE    5      /* nothing runnable and nothing running       */
#define KDS_ERR_BUS      6      /* SLVERR / DECERR on the memory port         */

/* FSM state encoding reported in STATUS[6:4] */
#define KDS_S_IDLE   0
#define KDS_S_FETCH  1
#define KDS_S_CHECK  2
#define KDS_S_RUN    3
#define KDS_S_WB     4
#define KDS_S_DONE   5
#define KDS_S_ERROR  6

/* ------------------------------------------------------------- host types */
typedef struct {
    uint16_t dur;                    /* execution ticks, >= 1               */
    uint8_t  dev;                    /* affinity mask over KDS_DEVICES      */
    uint32_t dep[KDS_DEPW];          /* predecessor bitmask                 */
    uint32_t kid;                    /* kernel id payload                   */
} kds_node_t;

typedef struct {
    uint32_t start[KDS_MAX_NODES];
    uint32_t finish[KDS_MAX_NODES];
    uint8_t  dev[KDS_MAX_NODES];
    uint16_t seq[KDS_MAX_NODES];
    uint32_t makespan;
    uint32_t dispatched;
    uint32_t stall_ticks;
    uint32_t depwait_ticks;
    uint32_t max_conc;
    uint32_t serial_ticks;
    uint32_t dev_busy[KDS_DEVICES];
    int      err;
} kds_result_t;

/* golden model - bit-exact mirror of the RUN phase of kds_core.v */
int  kds_model(const kds_node_t *nd, int n, kds_result_t *r);

/* software-only baseline: same schedule, executed by a CPU that has to pay
 * for every readiness scan, completion poll and kernel launch itself. */
typedef struct {
    uint32_t cycles;        /* modelled CPU-driven makespan                  */
    uint32_t rounds;        /* scheduling rounds executed                    */
    uint64_t ops_scan;      /* readiness-scan node visits                    */
    uint64_t ops_poll;      /* device completion polls                       */
    uint64_t ops_launch;    /* kernel launches                               */
    uint64_t ops_load;      /* graph words loaded                            */
    uint32_t idle_dev_ticks;/* device ticks lost to scheduler occupancy      */
} kds_base_t;

int kds_baseline(const kds_node_t *nd, int n, kds_base_t *b);

/* cost model, cycles per modelled scalar operation (documented in README) */
#define KDS_C_LOAD        4u                 /* graph word load             */
#define KDS_C_SCAN_NODE   (4u + 2u * KDS_DEPW) /* one node visited in a scan */
#define KDS_C_POLL_DEV    6u                 /* poll one device for done    */
#define KDS_C_LAUNCH      120u               /* build + ring a launch doorbell */

#endif /* KDS_H */
