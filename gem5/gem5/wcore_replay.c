/*
 * WEPWAWET-CORE driver bus-sequence replay for gem5 (SE mode).
 *
 * Issues the same MMIO accesses, in the same order, as the Stage 8 Python
 * backend (reference_from_handoff/wcore_stage8_backend.py) for a list of
 * kernel jobs, or the accesses of the PROPOSED chained driver.
 *
 * It is a C lower bound on the CPU cost of the driver: the real backend is
 * Python on PYNQ. The driver's time.sleep() calls are not executed here;
 * they are accounted separately from the source.
 *
 * The job table comes from a generated header (see gen_scenarios.py):
 *     -DSCENARIO_HEADER="scenario_xxx.h"
 * Build for the host with -DHOST_CHECK to count accesses instead of touching memory.
 */
#include <stdint.h>
#include <stdio.h>

#define HOST 0xA0040000u
#define SEQ  0xA0030000u
#define DESC 0xA0050000u
#define SHAKE128 0x80050000u
#define SHAKE256 0x80070000u

typedef struct {
    uint8_t lane;          /* 0 NTT, 1 INTT, 2 PolyMulAcc, 3 SHAKE256, 4 SHAKE128 */
    uint8_t new_program;   /* chained mode: this job starts a new microcoded program */
    uint16_t tx, rx;       /* descriptor word counts */
    uint16_t load, read;   /* chained mode: words the CPU loads / reads for this job */
    uint32_t msg_bytes, out_bytes, desc_lo, desc_hi;
} job_t;

#include SCENARIO_HEADER   /* defines: MODE_CHAIN (0/1), N_JOBS, static const job_t JOBS[] */

#define POOL_WORDS 8192u   /* 64 KiB of polynomial data on the CPU side, source and destination */
static uint64_t src_pool[POOL_WORDS];
static uint64_t dst_pool[POOL_WORDS];

#ifdef HOST_CHECK
static uint64_t n_read, n_write, seq_hash = 1469598103934665603ull;
static void mix(uint32_t kind, uint32_t addr) {
    seq_hash = (seq_hash ^ kind) * 1099511628211ull;
    seq_hash = (seq_hash ^ addr) * 1099511628211ull;
}
static uint32_t RD(uint32_t a) { n_read++; mix(1, a); return 0; }
static void WR(uint32_t a, uint32_t v) { (void)v; n_write++; mix(2, a); }
#else
#define RD(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define WR(a, v) (*(volatile uint32_t *)(uintptr_t)(a) = (uint32_t)(v))
#endif

static uint64_t sink;

static void write_word(uint32_t bank, uint32_t idx, uint64_t w) {
    WR(HOST + 0x00, bank * 2048u + idx);
    WR(HOST + 0x04, (uint32_t)w);
    WR(HOST + 0x08, (uint32_t)(w >> 32));
    sink += RD(HOST + 0x10);            /* _host_ready */
    WR(HOST + 0x0C, 1);
    sink += RD(HOST + 0x10);            /* poll: done on the first read */
}

static uint64_t read_word(uint32_t bank, uint32_t idx) {
    WR(HOST + 0x00, bank * 2048u + idx);
    sink += RD(HOST + 0x10);
    WR(HOST + 0x0C, 2);
    sink += RD(HOST + 0x10);
    uint64_t lo = RD(HOST + 0x14);
    uint64_t hi = RD(HOST + 0x18);
    return lo | (hi << 32);
}

static void shake_cfg(const job_t *j) {
    if (j->lane == 3) { WR(SHAKE256 + 0x10, j->msg_bytes); WR(SHAKE256 + 0x18, j->out_bytes); }
    if (j->lane == 4) { WR(SHAKE128 + 0x10, j->msg_bytes); WR(SHAKE128 + 0x18, j->out_bytes); }
}

/* Case B: exactly the order of WcoreStage8._run */
static void stage8_job(const job_t *j, uint32_t k) {
    const uint64_t *src = &src_pool[(k * 256u) % (POOL_WORDS - 2048u)];
    uint64_t *dst = &dst_pool[(k * 128u) % (POOL_WORDS - 2048u)];
    sink += RD(HOST + 0x10);                         /* _host_ready */
    sink += RD(SEQ + 8);                             /* _idle */
    shake_cfg(j);
    for (uint32_t i = 0; i < j->tx; i++) write_word(0, i, src[i]);
    for (uint32_t i = 0; i < j->rx; i++) write_word(1, i, 0);
    sink += RD(SEQ + 8);                             /* _idle */
    WR(DESC + 0, j->desc_lo); WR(DESC + 8, j->desc_hi);
    sink += RD(DESC + 0); sink += RD(DESC + 8);
    WR(SEQ + 0, 1); WR(SEQ + 0, 0);                  /* start pulse (2 ms sleep omitted) */
    sink += RD(SEQ + 8);                             /* completion poll */
    WR(SEQ + 0, 2); WR(SEQ + 0, 0);                  /* ack pulse (2 ms sleep omitted) */
    sink += RD(SEQ + 8);                             /* _idle */
    for (uint32_t i = 0; i < j->rx; i++) dst[i] = read_word(1, i);
    sink += RD(SEQ + 8);                             /* finally: idle check before scrub */
    for (uint32_t i = 0; i < j->tx; i++) write_word(0, i, 0);
    for (uint32_t i = 0; i < j->rx; i++) write_word(1, i, 0);
    WR(DESC + 0, 0); WR(DESC + 8, 0);
}

/* Case C (PROPOSED, not implemented in RTL): one microcoded program of several instructions.
 * The CPU loads only words that are not already in the scratchpad and reads only what it needs. */
static uint32_t chain_program(uint32_t first) {
    uint32_t last = first + 1;
    while (last < N_JOBS && !JOBS[last].new_program) last++;
    sink += RD(HOST + 0x10);
    sink += RD(SEQ + 8);
    for (uint32_t k = first; k < last; k++) {
        const uint64_t *src = &src_pool[(k * 256u) % (POOL_WORDS - 2048u)];
        for (uint32_t i = 0; i < JOBS[k].load; i++) write_word(0, i, src[i]);
    }
    sink += RD(SEQ + 8);
    for (uint32_t k = first; k < last; k++) {        /* one microcode instruction per kernel */
        shake_cfg(&JOBS[k]);
        WR(DESC + 0, JOBS[k].desc_lo); WR(DESC + 8, JOBS[k].desc_hi);
        sink += RD(DESC + 0); sink += RD(DESC + 8);
    }
    WR(SEQ + 0, 1); WR(SEQ + 0, 0);
    sink += RD(SEQ + 8);
    WR(SEQ + 0, 2); WR(SEQ + 0, 0);
    sink += RD(SEQ + 8);
    for (uint32_t k = first; k < last; k++) {
        uint64_t *dst = &dst_pool[(k * 128u) % (POOL_WORDS - 2048u)];
        for (uint32_t i = 0; i < JOBS[k].read; i++) dst[i] = read_word(1, i);
    }
    sink += RD(SEQ + 8);
    WR(DESC + 0, 0); WR(DESC + 8, 0);
    return last;
}

int main(void) {
    for (uint32_t i = 0; i < POOL_WORDS; i++) src_pool[i] = 0x9E3779B97F4A7C15ull * (i + 1);
    if (MODE_CHAIN) {
        uint32_t k = 0;
        while (k < N_JOBS) k = chain_program(k);
    } else {
        for (uint32_t k = 0; k < N_JOBS; k++) stage8_job(&JOBS[k], k);
    }
    uint64_t check = sink;
    for (uint32_t i = 0; i < POOL_WORDS; i += 97) check += dst_pool[i];
#ifdef HOST_CHECK
    printf("reads %llu writes %llu hash %016llx\n", (unsigned long long)n_read,
           (unsigned long long)n_write, (unsigned long long)seq_hash);
#else
    printf("wcore_replay jobs %u mode %s done %016llx\n", (unsigned)N_JOBS, MODE_CHAIN ? "chain" : "stage8",
           (unsigned long long)check);
#endif
    return 0;
}
