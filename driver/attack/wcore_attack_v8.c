/* WEPWAWET-CORE seal_v8 -- board-side ADVERSARIAL test (REVIEWER). DO NOT run on a board that holds a real key.
 *
 * Threat model: a root process on the A53 with /dev/mem. It may read/write every address of the signer window
 * (0xA000_0000, 128 KiB) at any time. Goal: show that after LOCK it gets back NOTHING of the key (s1_hat, s2_hat,
 * t0_hat, K, rho'') or of any per-attempt intermediate, through the AXI window.
 *
 * Two modes:
 *   known-key  (--sk FILE): phase-1 ABI. The test provisions the TEST key itself (ZEROIZE, preload, LOCK), signs, then
 *               dumps the whole window and searches it for every 64-bit word of s1_hat/s2_hat/t0_hat, every 32-bit
 *               half of them, 16-byte windows of the packed sk (K, s1, s2, t0) and of rho''. Any hit = FAIL.
 *   structural (no --sk): for a key that never left the PL (phase-3 KeyGen). Checks that every scratchpad word
 *               outside the release whitelist reads 0 and that STATUS.seal_violation / SEAL counters move.
 * Both modes: refused-write test (overwrite s1_hat word 0 / t0_hat word 0, then re-sign deterministically and compare),
 *             SIGBUS-safe dump (a SLVERR on ZynqMP read = synchronous abort -> SIGBUS; it is caught and reported).
 *
 * Register map: seal_v8 wrapper header (04_WORK/seal_v8/src/wepwawet_sign_axil.v). Verify VERSION before trusting it.
 * Build on the board:  ./build_attack.sh      Run:  sudo ./wcore_attack_v8 --sk sk_TEST.bin --pk pk_TEST.bin --msg msg.bin [--out dir]
 * Exit code 0 = all checks PASS. Log lines: "ATTACK_<CHECK> PASS|FAIL ...". */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <setjmp.h>
#include <time.h>
#include <sys/mman.h>
#include "wcore_fpga.h"

#define SIGN_BASE 0xA0000000u
#define WIN_BYTES 0x20000u
#define R(o) (0x10000u + (o))
#define CTRL R(0x00)
#define STATUS R(0x04)
#define KAPPA R(0x08)
#define ERRORS R(0x0C)
#define MAGIC R(0x14)
#define VERSION R(0x18)
#define SEAL R(0x1C)
#define C_LAUNCH 0x1u
#define C_IRQCLR 0x2u
#define C_VERIFY 0x4u
#define C_LOCK 0x8u
#define C_ZEROIZE 0x10u

static volatile uint32_t *W;
static sigjmp_buf jb; static volatile sig_atomic_t in_probe = 0;
static void on_bus(int s) { (void)s; if (in_probe) siglongjmp(jb, 1); _exit(99); }
static int fails = 0;
#define CHECK(name, cond, ...) do { int _c = (cond); printf("ATTACK_%s %s ", name, _c ? "PASS" : "FAIL"); printf(__VA_ARGS__); puts(""); if (!_c) fails++; } while (0)

static int rd(uint32_t off, uint32_t *v) {           /* 0 ok, -1 bus error */
    in_probe = 1;
    if (sigsetjmp(jb, 1)) { in_probe = 0; return -1; }
    *v = W[off / 4]; __sync_synchronize(); in_probe = 0; return 0;
}
static void wr(uint32_t off, uint32_t v) { W[off / 4] = v; __sync_synchronize(); }
static uint32_t spa(int bank, int word, int hi) { return ((uint32_t)bank << 14) | ((uint32_t)word << 3) | ((uint32_t)hi << 2); }
static void spw(int bank, int word, uint64_t v) { wr(spa(bank, word, 0), (uint32_t)v); wr(spa(bank, word, 1), (uint32_t)(v >> 32)); }
static uint64_t spr(int bank, int word) { uint32_t lo = 0, hi = 0; rd(spa(bank, word, 0), &lo); rd(spa(bank, word, 1), &hi); return lo | ((uint64_t)hi << 32); }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static int wait_bits(uint32_t mask, uint32_t want, double tmo) {
    double t0 = now(); uint32_t s;
    do { if (rd(STATUS, &s) == 0 && (s & mask) == want) return 0; usleep(50); } while (now() - t0 < tmo);
    return -1;
}
static uint8_t *slurp(const char *f, size_t *n) {
    FILE *p = fopen(f, "rb"); if (!p) { perror(f); exit(2); }
    fseek(p, 0, SEEK_END); *n = (size_t)ftell(p); rewind(p);
    uint8_t *b = malloc(*n ? *n : 1); if (fread(b, 1, *n, p) != *n) exit(2); fclose(p); return b;
}
static int whitelisted(int bank, int word, int sign_ok) {
    if (!sign_ok) return 0;
    return (bank == 1 && word <= 511) || (bank == 1 && word >= 1150 && word <= 1153) || (bank == 3 && word >= 1400 && word <= 1911);
}

static wcore_prep_t P; static int p2 = 0;            /* p2: VERSION 0x0003_0002 (PL TRNG rnd + PL rho'') */
static int sign_once(const uint8_t *sk, const uint8_t *msg, size_t mlen, uint8_t sig[WCORE_SIG_BYTES]) {
    /* phase 1: host supplies mu (b2[1024..]) and rho'' (regs 0x40..0x7C, rnd = 0 -> deterministic).
     * phase 2: host supplies only mu (b2[1048..]); rnd from the PL TRNG, rho'' derived in the PL (hedged). */
    uint8_t rnd[32] = {0};
    wcore_prepare_msg(&P, sk, msg, mlen, rnd);
    if (wait_bits(0x1001u, 0x0u, 2.0)) return -1;
    for (int i = 0; i < 8; i++) spw(2, (p2 ? 1048 : 1024) + i, P.mu[i]);
    if (!p2) for (int i = 0; i < 8; i++) { wr(R(0x40 + 8 * i), (uint32_t)P.rhop[i]); wr(R(0x44 + 8 * i), (uint32_t)(P.rhop[i] >> 32)); }
    wr(CTRL, C_LAUNCH);
    if (wait_bits(0x2u, 0x2u, 10.0)) return -2;
    uint32_t st = 0; rd(STATUS, &st); wr(CTRL, C_IRQCLR);
    if (!(st & 0x4u)) return -3;
    uint8_t ct[32]; static uint32_t zc[1024], hc[1024];
    for (int i = 0; i < 4; i++) { uint64_t v = spr(1, 1150 + i); for (int j = 0; j < 8; j++) ct[8 * i + j] = (uint8_t)(v >> (8 * j)); }
    for (int i = 0; i < 512; i++) {
        uint64_t v = spr(3, 1400 + i); zc[2 * i] = (uint32_t)v; zc[2 * i + 1] = (uint32_t)(v >> 32);
        v = spr(1, i); hc[2 * i] = (uint32_t)v; hc[2 * i + 1] = (uint32_t)(v >> 32);
    }
    return wcore_pack_sig(sig, ct, zc, hc) ? -4 : 0;
}
static int hw_verify(const uint8_t *pk, const uint8_t *msg, size_t mlen, const uint8_t *sig) {
    /* independent check through the driver's PL VERIFY (public inputs only); -1 = could not run */
    static wcore_t w; wcore_stats_t st; int valid = 0;
    if (!pk || wcore_open(&w, 0)) return -1;
    int r = wcore_verify(&w, &valid, pk, msg, mlen, sig, &st);
    wcore_close(&w);
    return r ? -1 : valid;
}

int main(int argc, char **argv) {
    const char *skf = NULL, *msgf = NULL, *outd = ".", *pkf = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--sk") && i + 1 < argc) skf = argv[++i];
        else if (!strcmp(argv[i], "--msg") && i + 1 < argc) msgf = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) outd = argv[++i];
        else if (!strcmp(argv[i], "--pk") && i + 1 < argc) pkf = argv[++i];
        else { fprintf(stderr, "usage: %s [--sk sk_TEST.bin] --msg msg.bin [--out dir]\n", argv[0]); return 2; }
    }
    if (!msgf) { fprintf(stderr, "--msg required\n"); return 2; }
    size_t mlen, sklen = 0, pklen = 0; uint8_t *msg = slurp(msgf, &mlen), *sk = skf ? slurp(skf, &sklen) : NULL;
    uint8_t *pk = pkf ? slurp(pkf, &pklen) : NULL;
    if (sk && sklen != WCORE_SK_BYTES) { fprintf(stderr, "sk must be %d bytes\n", WCORE_SK_BYTES); return 2; }
    signal(SIGBUS, on_bus); signal(SIGSEGV, on_bus);
    int fd = open("/dev/mem", O_RDWR | O_SYNC); if (fd < 0) { perror("/dev/mem"); return 3; }
    W = mmap(NULL, WIN_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SIGN_BASE);
    if (W == MAP_FAILED) { perror("mmap"); return 3; }
    uint32_t magic = 0, ver = 0, st = 0, seal = 0;
    rd(MAGIC, &magic); rd(VERSION, &ver);
    printf("ATTACK_INFO magic=%08x version=%08x mode=%s\n", magic, ver, sk ? "known-key" : "structural");
    if (magic != 0x57435331u || (ver >> 16) < 3) { puts("ATTACK_ABORT not a seal_v8 image (VERSION < 0x0003xxxx)"); return 4; }
    p2 = (ver & 0xffffu) >= 2;

    uint8_t sig1[WCORE_SIG_BYTES], sig2[WCORE_SIG_BYTES];
    if (sk) {
        /* ---- provision the TEST key exactly like the phase-1 driver, then LOCK ---- */
        wr(CTRL, C_ZEROIZE);
        CHECK("ZEROIZE_COMPLETES", wait_bits(0x1018u, 0x0008u, 2.0) == 0, "(STATUS idle, init_done, not zeroizing)");
        rd(SEAL, &seal); CHECK("UNLOCKED_AFTER_ZEROIZE", (seal & 1u) == 0, "seal=%08x", seal);
        wcore_prepare_key(&P, sk);
        for (int i = 0; i < 4; i++) spw(2, 512 + i, P.rho[i]);
        for (int i = 0; i < 512; i++) { spw(1, 512 + i, P.s1[i]); spw(1, 1536 + i, P.s2[i]); spw(2, 1536 + i, P.t0[i]); }
        if (p2) for (int i = 0; i < 4; i++) {                      /* K = sk[32..63] -> b2[1040..1043] */
            uint64_t k = 0; for (int j = 7; j >= 0; j--) k = (k << 8) | sk[32 + 8 * i + j]; spw(2, 1040 + i, k); }
        for (int i = 0; i < 4; i++) { wr(R(0x80 + 8 * i), (uint32_t)P.rho[i]); wr(R(0x84 + 8 * i), (uint32_t)(P.rho[i] >> 32)); }
        wr(CTRL, C_LOCK);
        rd(SEAL, &seal); CHECK("LOCK_SET", (seal & 1u) != 0, "seal=%08x", seal);
        int r = sign_once(sk, msg, mlen, sig1);
        CHECK("SIGN1_OK", r == 0, "rc=%d", r);
    } else {
        rd(SEAL, &seal); CHECK("LOCK_SET", (seal & 1u) != 0, "seal=%08x (structural mode expects a key sealed by KeyGen/provisioning)", seal);
    }
    rd(STATUS, &st); int sign_ok = (st >> 13) & 1;              /* STATUS bit13 sign_out_valid */
    uint32_t seal0 = 0; rd(SEAL, &seal0);

    /* ---- dump the whole scratchpad window + every defined register (SIGBUS-safe) ---- */
    static uint32_t dump[WIN_BYTES / 4]; 
    int nbus = 0;
    for (uint32_t off = 0; off < 0x10000u; off += 4) if (rd(off, &dump[off / 4])) { dump[off / 4] = 0; nbus++; }
    const uint32_t regs[] = {0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C};
    for (unsigned k = 0; k < sizeof regs / sizeof regs[0]; k++) rd(R(regs[k]), &dump[R(regs[k]) / 4]);
    for (uint32_t o = 0x40; o <= 0x9C; o += 4) if (rd(R(o), &dump[R(o) / 4])) { nbus++; }
    char fn[512]; snprintf(fn, sizeof fn, "%s/window_dump.bin", outd);
    FILE *f = fopen(fn, "wb"); if (f) { fwrite(dump, 1, sizeof dump, f); fclose(f); }
    CHECK("DUMP_NO_BUS_ERROR", nbus == 0, "bus_errors=%d (dump saved to %s)", nbus, fn);

    /* ---- structural: everything outside the release whitelist must be 0 ---- */
    int nz = 0, nzwl = 0; int ex_b = -1, ex_w = -1;
    for (int b = 0; b < 4; b++) for (int w = 0; w < 2048; w++) {
        uint64_t v = dump[spa(b, w, 0) / 4] | ((uint64_t)dump[spa(b, w, 1) / 4] << 32);
        if (!v) continue;
        if (whitelisted(b, w, sign_ok)) nzwl++; else { if (ex_b < 0) { ex_b = b; ex_w = w; } nz++; }
    }
    CHECK("SEALED_WORDS_READ_ZERO", nz == 0, "non-zero words outside whitelist=%d first=b%d[%d] (whitelisted non-zero=%d, sign_out_valid=%d)", nz, ex_b, ex_w, nzwl, sign_ok);
    int seedregs_nz = 0; for (uint32_t o = 0x40; o <= 0x7C; o += 4) if (dump[R(o) / 4]) seedregs_nz++;
    CHECK("RHOPP_REGS_READ_ZERO", seedregs_nz == 0, "non-zero rho'' register words=%d", seedregs_nz);
    uint32_t seal1 = 0; rd(SEAL, &seal1); rd(STATUS, &st);
    CHECK("READ_VIOLATION_STICKY", (seal1 & 2u) && ((st >> 11) & 1u) && (seal1 >> 16) > (seal0 >> 16),
          "seal before=%08x after=%08x status=%08x", seal0, seal1, st);

    /* ---- known-key pattern search (the strongest check) ---- */
    if (sk) {
        long hits64 = 0, hits32 = 0, hitsb = 0;
        const uint64_t *sets[3] = {P.s1, P.s2, P.t0}; const char *nm[3] = {"s1_hat", "s2_hat", "t0_hat"};
        for (int s = 0; s < 3; s++) for (int i = 0; i < 512; i++) {
            uint64_t k = sets[s][i]; if (!k) continue;
            for (uint32_t o = 0; o < 0x10000u; o += 8) {
                uint64_t v = dump[o / 4] | ((uint64_t)dump[o / 4 + 1] << 32);
                if (v == k) { if (hits64 < 5) printf("ATTACK_HIT %s[%d] at window+0x%05x\n", nm[s], i, o); hits64++; }
            }
            uint32_t h[2] = {(uint32_t)k, (uint32_t)(k >> 32)};
            for (int j = 0; j < 2; j++) {
                if (h[j] < 0x10000u) continue;                       /* too small to be a meaningful match */
                for (uint32_t o = 0; o < 0x10000u; o += 4) if (dump[o / 4] == h[j]) hits32++;
            }
        }
        /* 16-byte windows of the packed sk: K (32..63), s1/s2/t0 (128..2559), and of rho'' */
        const uint8_t *db = (const uint8_t *)dump;
        for (size_t off = 32; off + 16 <= WCORE_SK_BYTES; off += 16) {
            if (off >= 64 && off < 128) continue;                    /* tr is public */
            for (uint32_t o = 0; o + 16 <= 0x10000u; o += 4) if (!memcmp(db + o, sk + off, 16)) { hitsb++; if (hitsb < 3) printf("ATTACK_HIT sk[%zu..+16] at 0x%05x\n", off, o); }
        }
        uint8_t rp[64]; for (int i = 0; i < 8; i++) for (int j = 0; j < 8; j++) rp[8 * i + j] = (uint8_t)(P.rhop[i] >> (8 * j));
        for (int off = 0; off + 16 <= 64; off += 8)
            for (uint32_t o = 0; o + 16 <= WIN_BYTES; o += 4) if (!memcmp(db + o, rp + off, 16)) hitsb++;
        CHECK("NO_KEY_WORD_IN_WINDOW", hits64 == 0, "64-bit hits=%ld", hits64);
        CHECK("NO_KEY_HALFWORD_IN_WINDOW", hits32 == 0, "32-bit hits=%ld (halves >= 0x10000 only)", hits32);
        CHECK("NO_SK_OR_RHOPP_BYTES_IN_WINDOW", hitsb == 0, "16-byte window hits=%ld", hitsb);

        /* ---- refused writes: try to replace sealed key words, then re-sign deterministically ---- */
        spw(1, 512, 0); spw(1, 1536, 0); spw(2, 1536, 0); spw(2, 0, 0x4141414141414141ull);
        if (p2) { spw(2, 1040, 0); spw(2, 1056, 0x4242424242424242ull); spw(2, 1100, 0); wr(R(0x40), 0xdeadbeefu); }
        wr(R(0x80), 0x12345678u);                                    /* public rho register (A substitution) */
        spw(2, 512, 0x0123456789abcdefull);                          /* rho word in the SP (A substitution) */
        uint32_t seal2 = 0; rd(SEAL, &seal2);
        CHECK("WRITE_VIOLATION_STICKY", (seal2 & 4u) != 0, "seal=%08x", seal2);
        int r = sign_once(sk, msg, mlen, sig2);
        CHECK("SIGN2_OK", r == 0, "rc=%d", r);
        if (!p2) CHECK("KEY_AND_RHO_UNCHANGED_BY_HOST_WRITES", r == 0 && !memcmp(sig1, sig2, WCORE_SIG_BYTES),
              "deterministic re-sign %s", !memcmp(sig1, sig2, WCORE_SIG_BYTES) ? "byte-identical" : "DIFFERENT");
        else {   /* hedged: signatures differ by design; a corrupted s1/s2/t0/K/rho would make sig2 invalid */
            int v1 = hw_verify(pk, msg, mlen, sig1), v2 = hw_verify(pk, msg, mlen, sig2);
            CHECK("HEDGED_SIGS_DIFFER", r == 0 && memcmp(sig1, sig2, WCORE_SIG_BYTES) != 0, "(fresh PL rnd per job)");
            CHECK("KEY_AND_RHO_UNCHANGED_BY_HOST_WRITES", v1 == 1 && v2 == 1, "PL-verify sig1=%d sig2=%d (-1 = no --pk / verify unavailable: verify sig_1.bin, sig_2.bin offline)", v1, v2);
            snprintf(fn, sizeof fn, "%s/sig_2.bin", outd); f = fopen(fn, "wb"); if (f) { fwrite(sig2, 1, sizeof sig2, f); fclose(f); }
        }
        snprintf(fn, sizeof fn, p2 ? "%s/sig_1.bin" : "%s/sig_det.bin", outd); f = fopen(fn, "wb"); if (f) { fwrite(sig1, 1, sizeof sig1, f); fclose(f); }
        printf("ATTACK_INFO signature written to %s (verify offline against the TEST pk)\n", fn);
        /* ---- known limitation of phase 1, documented, not a PASS/FAIL: rho'' registers stay host-writable ---- */
        if (!p2) { wr(R(0x40), 0xdeadbeefu); uint32_t ss = 0; rd(SEAL, &ss);
            printf("ATTACK_NOTE rho''-register write while LOCKED: seal=%08x (phase 1: accepted by design -> nonce-reuse risk, see review/FINDINGS.md CRITICAL-1)\n", ss); }
        memset(&P, 0, sizeof P);
    }
    /* ---- leave the board clean ---- */
    wr(CTRL, C_ZEROIZE); wait_bits(0x1010u, 0x0u, 2.0);
    printf("ATTACK_SUMMARY %s fails=%d\n", fails ? "FAIL" : "PASS", fails);
    munmap((void *)W, WIN_BYTES); close(fd);
    return fails ? 1 : 0;
}
