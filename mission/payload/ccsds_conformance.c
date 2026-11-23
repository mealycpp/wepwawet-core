/* CCSDS 121.0-B-2 conformance check of the vendored libaec (same procedure as libaec's tests/sampledata.sh,
 * "All Options" set, 256-byte packets, n = 1..16 bits): encode the reference .dat and compare with the
 * reference .rz (bit-exact for n=1..4 basic/restricted, size-exact for n=5..16), and decode every .rz back
 * to the .dat. usage: ccsds_conformance <dir with test_p256nXX.*>   exit 0 = all pass */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libaec.h"
static unsigned char *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL; fseek(f, 0, SEEK_END); *n = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(*n + 1); if (fread(b, 1, *n, f) != *n) { fclose(f); free(b); return NULL; } fclose(f); return b; }
static void setup(struct aec_stream *s, int bits, int restricted) {
    memset(s, 0, sizeof *s); s->bits_per_sample = bits; s->block_size = 16; s->rsi = 16;
    s->flags = AEC_DATA_PREPROCESS | (restricted ? AEC_RESTRICTED : 0); }
int main(int argc, char **argv) {
    const char *d = argc > 1 ? argv[1] : "ccsds_testdata"; int fails = 0, checks = 0; char p[512];
    for (int n = 1; n <= 16; n++) {
        size_t dl; snprintf(p, sizeof p, "%s/test_p256n%02d.dat", d, n); unsigned char *dat = slurp(p, &dl);
        if (!dat) { printf("missing %s\n", p); fails++; continue; }
        const char *var[2] = { n <= 4 ? "-basic" : "", "-restricted" };
        for (int v = 0; v < (n <= 4 ? 2 : 1); v++) {
            size_t rl; snprintf(p, sizeof p, "%s/test_p256n%02d%s.rz", d, n, var[v]); unsigned char *rz = slurp(p, &rl);
            if (!rz) { printf("missing %s\n", p); fails++; continue; }
            struct aec_stream s; unsigned char *out = malloc(dl * 2 + 4096); setup(&s, n, v == 1);
            s.next_in = dat; s.avail_in = dl; s.next_out = out; s.avail_out = dl * 2 + 4096;
            int re = aec_buffer_encode(&s); size_t ol = s.total_out;
            int enc_ok = re == AEC_OK && (n <= 4 ? (ol == rl && !memcmp(out, rz, rl)) : ol == rl);
            unsigned char *back = malloc(dl + 64); setup(&s, n, v == 1);
            s.next_in = rz; s.avail_in = rl; s.next_out = back; s.avail_out = dl + 64;
            int rd = aec_buffer_decode(&s);
            int dec_ok = (rd == AEC_OK || rd == AEC_DATA_ERROR) && s.total_out >= dl && !memcmp(back, dat, dl);
            printf("n=%2d %-11s encode %s (%zu/%zu B) | decode %s\n", n, v ? "restricted" : (n <= 4 ? "basic" : "default"),
                   enc_ok ? (n <= 4 ? "BIT-EXACT" : "SIZE-EXACT") : "FAIL", ol, rl, dec_ok ? "EXACT" : "FAIL");
            checks += 2; fails += !enc_ok + !dec_ok; free(out); free(back); free(rz);
        }
        free(dat);
    }
    printf("CCSDS 121.0-B-2 conformance (libaec %s): %d/%d checks pass -> %s\n", AEC_VERSION_STR, checks - fails, checks, fails ? "FAIL" : "PASS");
    return fails != 0;
}
