/* seal_v8 phase-3 board self-test: KEY GENERATED IN THE PL. No sk file, no test key, no host keygen anywhere.
 * Image: VERSION 0x0003_0003 (05_RESULTS/sign_v8_300/phase3). usage: sudo ./wcore_selftest_v8kg N poll_us
 *  K0 open, VERSION 0x0003_0003, DET_RND bit 0 (KAT_XI=0 is a build property: see kit README / synth wrapper)
 *  K1 (ZEROIZE if LOCKED) KEYGEN: xi from the PL TRNG path, FIPS 204 Alg. 6 in the PL -> pk = rho||t1 read out
 *  K2 sweep after KEYGEN: every scratchpad word outside {rho b2[1028..1031], t1 b3[1536..2047]} reads 0; key homes read 0
 *  K3 KEYGEN while LOCKED is refused (violation counter +1, status/pk unchanged)
 *  K4 N hedged signatures with the sealed PL key: PQClean verify under the PL pk, mutated message rejected, FPGA verify
 *  K5 sweep after SIGN: every word outside {h, c~, z} reads 0
 *  K6 ZEROIZE -> LOCK clear, sweep all zero
 *  K7 second KEYGEN -> pk2 != pk1; a pk2 signature verifies under pk2 and NOT under pk1
 *  K8 ZEROIZE (leaves no key behind)
 * Sweep criterion (honest): the host never knows the PL key, so the check is STRUCTURAL -- any non-zero word outside
 * the released window fails. It cannot detect a leak that lands inside the released window itself (h/c~/z/rho/t1); those
 * are the FIPS 204 outputs, and their correctness is shown by PQClean verification.  */
#define _GNU_SOURCE
#include "wcore_fpga.h"
#include "api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static wcore_t w;
static uint64_t spr64(int bank, int word) { unsigned off = ((unsigned)bank << 14 | (unsigned)word << 3) / 4;
    uint64_t lo = w.sign[off], hi = w.sign[off + 1]; return lo | (hi << 32); }
static int win_sign(int b, int i) { return (b == 1 && i <= 511) || (b == 1 && i >= 1150 && i <= 1153) || (b == 3 && i >= 1400 && i <= 1911); }
static int win_kg(int b, int i)   { return (b == 2 && i >= 1028 && i <= 1031) || (b == 3 && i >= 1536); }
static int sweep(const char *tag, int mode) {        /* mode 0 none allowed, 1 sign window, 2 keygen window */
    int nz = 0;
    for (int b = 0; b < 4; b++) for (int i = 0; i < 2048; i++) {
        int allowed = (mode == 1 && win_sign(b, i)) || (mode == 2 && win_kg(b, i));
        if (spr64(b, i) && !allowed) { nz++; if (nz < 4) fprintf(stderr, "  nonzero b%d[%d]\n", b, i); }
    }
    printf("sweep %-14s 8192 words: unexpected_nonzero=%d seal=0x%08x\n", tag, nz, wcore_seal_reg(&w));
    return nz;
}
static int sign_check(const uint8_t *pk, const uint8_t *otherpk, int n, const char *tag, FILE *csv) {
    char msg[160]; uint8_t sig[2420]; int bad = 0;
    for (int i = 0; i < n; i++) {
        int ml = snprintf(msg, sizeof msg, "WCORE-V8|PL-KEYGEN|%s|SEQ=%d", tag, i); wcore_stats_t st;
        int r = wcore_sign_sealed(&w, sig, (uint8_t*)msg, ml, &st);
        int ok = !r && PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig, 2420, (uint8_t*)msg, ml, pk) == 0;
        msg[0] ^= 1; int mut = !r && PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig, 2420, (uint8_t*)msg, ml, pk) != 0; msg[0] ^= 1;
        int other = otherpk ? (PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sig, 2420, (uint8_t*)msg, ml, otherpk) != 0) : 1;
        int fv = 0; wcore_stats_t vs; if (r || wcore_verify(&w, &fv, pk, (uint8_t*)msg, ml, sig, &vs)) fv = -1;
        int good = ok && mut && other && fv == 1; bad += !good;
        if (csv) fprintf(csv, "%s,%d,%d,%u,%u,%.1f,%.1f,%u,%u,%d,%d,%d,%d\n", tag, i, r, st.attempts, st.cycles, st.wait_us, st.total_us,
                         st.trng_apt_worst, st.trng_max_run, ok, mut, other, fv);
        if (i < 2 || !good) printf("  %s sig %d: rc=%d attempts=%u cycles=%u pqclean_verify=%d mut_rej=%d other_pk_rej=%d fpga_verify=%d\n",
                                   tag, i, r, st.attempts, st.cycles, ok, mut, other, fv);
    }
    return bad;
}
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 20; unsigned poll = argc > 2 ? (unsigned)atoi(argv[2]) : 100; int fail = 0, r;
    static uint8_t pk1[1312], pk2[1312], pkx[1312]; wcore_stats_t st;
    r = wcore_open(&w, poll); if (r) { fprintf(stderr, "wcore_open failed %d\n", r); return 2; }
    uint32_t tr = wcore_trng_reg(&w);
    printf("K0 VERSION=0x%08x TRNG=0x%08x DET_RND=%u\n", w.version, tr, (tr >> 25) & 1);
    if (w.version != WCORE_VERSION_V8P3 || ((tr >> 25) & 1)) { printf("RESULT: FAIL (not the phase-3 board image)\n"); return 1; }
    if (wcore_status(&w) & (1u << 10)) { r = wcore_zeroize(&w); printf("K1 pre-existing LOCK -> ZEROIZE rc=%d\n", r); if (r) fail++; }
    r = wcore_keygen(&w, pk1, &st);
    printf("K1 KEYGEN rc=%d cycles=%u wait=%.0fus errors=0x%x trng=0x%x status=0x%08x\n", r, st.cycles, st.wait_us, st.errors, st.trng_reg, wcore_status(&w));
    if (r) { printf("RESULT: FAIL (KEYGEN)\n"); return 1; }
    FILE *pf = fopen("pl_pk1.bin", "wb"); if (pf) { fwrite(pk1, 1, 1312, pf); fclose(pf); }
    if (sweep("AFTER_KEYGEN", 2)) fail++;
    uint32_t c0 = wcore_seal_reg(&w) >> 16;
    int keyrd = spr64(1, 512) || spr64(1, 1536) || spr64(2, 1536) || spr64(2, 1040);
    w.sign[0x10000/4] = 0x20;                                     /* KEYGEN while LOCKED: must be refused */
    uint32_t c1 = wcore_seal_reg(&w) >> 16;
    memset(pkx, 0, sizeof pkx); for (int i = 0; i < 4; i++) { uint64_t v = spr64(2, 1028 + i); for (int j = 0; j < 8; j++) pkx[8*i+j] = (uint8_t)(v >> (8*j)); }
    int same_rho = !memcmp(pkx, pk1, 32);
    printf("K2/K3 key words readable=%d; KEYGEN-while-LOCKED violations %u -> %u (expect +9: 8 probe halves + 1), rho unchanged=%d\n", keyrd, c0, c1, same_rho);
    if (keyrd || c1 != c0 + 9 || !same_rho) fail++;
    FILE *csv = fopen("wcore_selftest_v8kg.csv", "w");
    fprintf(csv, "key,i,rc,attempts,cycles,wait_us,total_us,trng_apt,trng_run,pqclean_verify,mut_rejected,other_pk_rejected,fpga_verify\n");
    int b1 = sign_check(pk1, NULL, n, "pk1", csv);
    printf("K4 %d hedged signatures under the PL key: %d failures\n", n, b1); if (b1) fail++;
    { uint8_t s[2420]; const char *m = "WCORE-V8|PL-KEYGEN|last"; if (wcore_sign_sealed(&w, s, (const uint8_t*)m, strlen(m), &st)) fail++; }
    if (sweep("AFTER_SIGN", 1)) fail++;
    r = wcore_zeroize(&w); printf("K6 ZEROIZE rc=%d status=0x%08x\n", r, wcore_status(&w)); if (r) fail++;
    if (sweep("AFTER_ZEROIZE", 0)) fail++;
    r = wcore_keygen(&w, pk2, &st); int differ = memcmp(pk1, pk2, 1312) != 0;
    printf("K7 second KEYGEN rc=%d pk_differs=%d\n", r, differ); if (r || !differ) fail++;
    if (!r) { int b2 = sign_check(pk2, pk1, 3, "pk2", csv); printf("K7 3 signatures under pk2 (must not verify under pk1): %d failures\n", b2); if (b2) fail++; }
    fclose(csv);
    r = wcore_zeroize(&w); printf("K8 final ZEROIZE rc=%d\n", r); if (r) fail++;
    printf("RESULT: %s (%d failing steps)\n", fail ? "FAIL" : "PASS", fail);
    wcore_close(&w); return fail ? 1 : 0;
}
