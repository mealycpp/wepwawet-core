/* seal_v8 board self-test (C, no Python). Image: 05_RESULTS/aup_kit_v8 (VERSION 0x0003_0002, DET_RND=0).
 * usage: sudo ./wcore_selftest_v8 N poll_us
 *  S0 open, VERSION, TRNG reg DET bit must be 0 (board build is never deterministic)
 *  S1 PQClean keygen (independent C), ZEROIZE if a key is already sealed, provision + LOCK
 *  S2 probes while LOCKED: s1_hat/s2_hat/t0_hat/K words read 0, violation counter moves, a write to t0_hat is
 *     refused (signatures below still verify => the sealed key was not changed), former rho'' regs read 0
 *  S3 N hedged signatures with the sealed key -> PQClean verify + mutated-message reject + FPGA verify
 *  S4 same message twice -> different signatures (PL rnd), both verify
 *  S5 full PS sweep of the 128 KiB scratchpad window after a signature: no word equals any s1_hat/s2_hat/t0_hat/K word,
 *     every word outside {h, c~, z} reads 0
 *  S6 ZEROIZE -> LOCK clear, full sweep all zero; re-provision; one more signature verifies
 *  S7 (phase-3 image, VERSION 0x0003_0003 only) ZEROIZE -> KEYGEN in the PL (xi from the PL TRNG; the host never has sk)
 *     -> 5 hedged signatures PQClean-verify under the PL-generated pk -> structural sweep (outside {h,c~,z}: all 0)
 * Prints one RESULT line; CSV wcore_selftest_v8.csv. NEVER prints key material. */
#define _GNU_SOURCE
#include "wcore_fpga.h"
#include "api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define REGW(o) w.sign[(0x10000u + (o)) / 4]
static wcore_t w;
static uint64_t spr64(int bank, int word) { unsigned off = ((unsigned)bank << 14 | (unsigned)word << 3) / 4;
    uint64_t lo = w.sign[off], hi = w.sign[off + 1]; return lo | (hi << 32); }
static int in_out(int b, int i) { return (b == 1 && i <= 511) || (b == 1 && i >= 1150 && i <= 1153) || (b == 3 && i >= 1400 && i <= 1911); }
static wcore_prep_t sec; static uint64_t Kw[4];
static int is_secret(uint64_t v) {
    if (!v) return 0;
    for (int i = 0; i < 512; i++) if (v == sec.s1[i] || v == sec.s2[i] || v == sec.t0[i]) return 1;
    for (int i = 0; i < 4; i++) if (v == Kw[i]) return 1;
    return 0;
}
static int sweep(const char *tag, int allow_out, int *hits) {
    int nz = 0; *hits = 0;
    for (int b = 0; b < 4; b++) for (int i = 0; i < 2048; i++) {
        uint64_t v = spr64(b, i);
        if (is_secret(v) && !(allow_out && in_out(b, i))) (*hits)++;
        if (v && !(allow_out && in_out(b, i))) nz++;
    }
    printf("S5 sweep %-14s 8192 words: secret_hits=%d unexpected_nonzero=%d seal=0x%08x\n", tag, *hits, nz, wcore_seal_reg(&w));
    return nz;
}
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 50; unsigned poll = argc > 2 ? (unsigned)atoi(argv[2]) : 100;
    uint8_t pk[1312], sk[2560], sig[2420], sig2[2420]; char msg[160]; int fail = 0, hits;
    int r = wcore_open(&w, poll); if (r) { fprintf(stderr, "wcore_open failed %d (image loaded? root?)\n", r); return 2; }
    uint32_t tr = wcore_trng_reg(&w);
    printf("S0 VERSION=0x%08x TRNG=0x%08x DET_RND=%u\n", w.version, tr, (tr >> 25) & 1);
    if (!wcore_is_v8(&w) || ((tr >> 25) & 1)) { printf("RESULT: FAIL (not a v8 phase-2 board image, or DET_RND build)\n"); return 1; }
    PQCLEAN_MLDSA44_AARCH64_crypto_sign_keypair(pk, sk);
    wcore_prepare_key(&sec, sk); for (int i = 0; i < 4; i++) { uint64_t v = 0; for (int j = 7; j >= 0; j--) v = (v << 8) | sk[32 + 8*i + j]; Kw[i] = v; }
    if (wcore_status(&w) & (1u << 10)) { r = wcore_zeroize(&w); printf("S1 pre-existing LOCK -> ZEROIZE rc=%d\n", r); if (r) fail++; }
    r = wcore_provision(&w, sk); printf("S1 provision+LOCK rc=%d status=0x%08x\n", r, wcore_status(&w)); if (r) { printf("RESULT: FAIL\n"); return 1; }
    uint32_t c0 = wcore_seal_reg(&w) >> 16;
    int leak = spr64(1, 512) != 0 || spr64(1, 1536) != 0 || spr64(2, 1536) != 0 || spr64(2, 1040) != 0;
    w.sign[(2u << 14 | 1536u << 3) / 4] = 0xDEADBEEF; w.sign[(2u << 14 | 1536u << 3) / 4 + 1] = 0x0BADF00D;   /* refused */
    int seedrd = 0; for (int i = 0; i < 16; i++) seedrd |= REGW(0x40 + 4*i) != 0;
    uint32_t c1 = wcore_seal_reg(&w) >> 16;
    printf("S2 locked probes: key words readable=%d seed regs readable=%d violations %u -> %u (expect +10)\n", leak, seedrd, c0, c1);
    if (leak || seedrd || c1 != c0 + 10) fail++;
    FILE *csv = fopen("wcore_selftest_v8.csv", "w");
    fprintf(csv, "i,attempts,cycles,wait_us,total_us,trng_apt,trng_run,trng_redraws,pqclean_verify,mut_rejected,fpga_verify\n");
    int bad = 0, sfail = 0;
    for (int i = 0; i < n; i++) {
        int ml = snprintf(msg, sizeof msg, "WCORE-V8|SEALED|SEQ=%d|hedged PL rnd", i); wcore_stats_t st;
        r = wcore_sign_sealed(&w, sig, (uint8_t*)msg, ml, &st);
        if (r) { fprintf(stderr, "sign %d rc=%d errors=0x%x trng=0x%x\n", i, r, st.errors, st.trng_reg); sfail++; continue; }
        int ok = PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig, 2420, (uint8_t*)msg, ml, pk) == 0;
        msg[0] ^= 1; int mut = PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig, 2420, (uint8_t*)msg, ml, pk) != 0; msg[0] ^= 1;
        int fv = 0; wcore_stats_t vs; if (wcore_verify(&w, &fv, pk, (uint8_t*)msg, ml, sig, &vs)) fv = -1;
        bad += !(ok && mut && fv == 1);
        fprintf(csv, "%d,%u,%u,%.1f,%.1f,%u,%u,%u,%d,%d,%d\n", i, st.attempts, st.cycles, st.wait_us, st.total_us,
                st.trng_apt_worst, st.trng_max_run, st.trng_redraws, ok, mut, fv);
        if (i < 3) printf("S3 sig %d: attempts=%u pl_cycles=%u wait=%.0fus total=%.0fus verify=%d mut_rej=%d fpga_verify=%d trng apt=%u run=%u\n",
                          i, st.attempts, st.cycles, st.wait_us, st.total_us, ok, mut, fv, st.trng_apt_worst, st.trng_max_run);
    }
    fclose(csv);
    printf("S3 %d hedged signatures: %d driver failures, %d verify failures\n", n, sfail, bad); if (sfail || bad) fail++;
    { wcore_stats_t a, b; const char *m = "WCORE-V8|same message twice";
      int r1 = wcore_sign_sealed(&w, sig, (const uint8_t*)m, strlen(m), &a), r2 = wcore_sign_sealed(&w, sig2, (const uint8_t*)m, strlen(m), &b);
      int v1 = PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig, 2420, (const uint8_t*)m, strlen(m), pk) == 0;
      int v2 = PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig2, 2420, (const uint8_t*)m, strlen(m), pk) == 0;
      int differ = memcmp(sig, sig2, 2420) != 0;
      printf("S4 same message twice: rc=%d/%d verify=%d/%d signatures_differ=%d\n", r1, r2, v1, v2, differ);
      if (r1 || r2 || !v1 || !v2 || !differ) fail++; }
    if (sweep("LOCKED_AFTER", 1, &hits) || hits) fail++;
    r = wcore_zeroize(&w); printf("S6 ZEROIZE rc=%d status=0x%08x seal=0x%08x\n", r, wcore_status(&w), wcore_seal_reg(&w)); if (r) fail++;
    if (sweep("AFTER_ZEROIZE", 0, &hits) || hits) fail++;
    r = wcore_provision(&w, sk); { wcore_stats_t st; const char *m = "WCORE-V8|after re-provision";
      int rs = wcore_sign_sealed(&w, sig, (const uint8_t*)m, strlen(m), &st);
      int v = rs == 0 && PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig, 2420, (const uint8_t*)m, strlen(m), pk) == 0;
      printf("S6 re-provision rc=%d sign rc=%d verify=%d\n", r, rs, v); if (r || !v) fail++; }
    memset(sk, 0, sizeof sk); memset(&sec, 0, sizeof sec); memset(Kw, 0, sizeof Kw);
    if (w.version == WCORE_VERSION_V8P3) {
        wcore_stats_t st; int zr = wcore_zeroize(&w); r = wcore_keygen(&w, pk, &st); int kbad = 0;
        printf("S7 PL KEYGEN zeroize=%d rc=%d cycles=%u errors=0x%x trng=0x%x\n", zr, r, st.cycles, st.errors, st.trng_reg);
        if (zr || r) fail++;
        else {
            for (int i = 0; i < 5; i++) { int ml = snprintf(msg, sizeof msg, "WCORE-V8|PL-KEYGEN|SEQ=%d", i);
                int rs = wcore_sign_sealed(&w, sig, (uint8_t*)msg, ml, &st);
                if (rs || PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig, 2420, (uint8_t*)msg, ml, pk) != 0) kbad++; }
            printf("S7 5 hedged signatures under the PL-generated pk: %d failures\n", kbad); if (kbad) fail++;
            if (sweep("AFTER_PL_KEYGEN", 1, &hits)) fail++;
        }
    }
    printf("NOTE: the test key stays SEALED in the PL; run with a fresh process or reset the PL to remove it.\n");
    printf("RESULT: %s (%d failing steps)\n", fail ? "FAIL" : "PASS", fail);
    wcore_close(&w);
    return fail ? 1 : 0;
}
