/* REVIEWER: PQClean ML-DSA-44 (clean) oracle for seal_v8 KATs.
 * PQClean commit 0586a824fc0d49df0b6b6e9179d8d15d06d0974f (crypto_sign/ml-dsa-44/clean + common/fips202.c).
 * randombytes() is replaced: it returns bytes from a caller-supplied hex string (deterministic KATs), else zeros.
 *   pqc_oracle sign   <sk.bin> <msg.bin> <rnd_hex64|zero> <out_sig.bin>     (pure ML-DSA, empty ctx)
 *   pqc_oracle verify <pk.bin> <msg.bin> <sig.bin>                          -> prints VERIFY_OK / VERIFY_FAIL
 *   pqc_oracle keygen <xi_hex64> <out_pk.bin> <out_sk.bin>                   (FIPS 204 KeyGen_internal(xi))   */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "api.h"
static uint8_t rb[64]; static size_t rb_len = 0, rb_pos = 0;
int PQCLEAN_randombytes(uint8_t *out, size_t n) { for (size_t i = 0; i < n; i++) out[i] = rb_pos < rb_len ? rb[rb_pos++] : 0; return 0; }
static void hexin(const char *h) { rb_len = 0; rb_pos = 0; if (!strcmp(h, "zero")) return;
    for (size_t i = 0; h[2*i] && h[2*i+1] && i < sizeof rb; i++) { unsigned v; sscanf(h + 2*i, "%2x", &v); rb[rb_len++] = (uint8_t)v; } }
static uint8_t *slurp(const char *f, size_t *n) { FILE *p = fopen(f, "rb"); if (!p) { perror(f); exit(2); }
    fseek(p, 0, SEEK_END); *n = (size_t)ftell(p); rewind(p); uint8_t *b = malloc(*n + 1); if (fread(b, 1, *n, p) != *n) exit(2); fclose(p); return b; }
static void spit(const char *f, const uint8_t *b, size_t n) { FILE *p = fopen(f, "wb"); fwrite(b, 1, n, p); fclose(p); }
int main(int c, char **v) {
    if (c >= 6 && !strcmp(v[1], "sign")) {
        size_t nsk, nm; uint8_t *sk = slurp(v[2], &nsk), *m = slurp(v[3], &nm); uint8_t sig[PQCLEAN_MLDSA44_CLEAN_CRYPTO_BYTES]; size_t sl;
        hexin(v[4]); if (nsk != PQCLEAN_MLDSA44_CLEAN_CRYPTO_SECRETKEYBYTES) return 3;
        PQCLEAN_MLDSA44_CLEAN_crypto_sign_signature_ctx(sig, &sl, m, nm, NULL, 0, sk); spit(v[5], sig, sl); printf("SIGNED %zu\n", sl); return 0;
    }
    if (c >= 5 && !strcmp(v[1], "verify")) {
        size_t npk, nm, ns; uint8_t *pk = slurp(v[2], &npk), *m = slurp(v[3], &nm), *s = slurp(v[4], &ns);
        int r = PQCLEAN_MLDSA44_CLEAN_crypto_sign_verify_ctx(s, ns, m, nm, NULL, 0, pk); puts(r ? "VERIFY_FAIL" : "VERIFY_OK"); return r ? 1 : 0;
    }
    if (c >= 5 && !strcmp(v[1], "keygen")) {
        uint8_t pk[PQCLEAN_MLDSA44_CLEAN_CRYPTO_PUBLICKEYBYTES], sk[PQCLEAN_MLDSA44_CLEAN_CRYPTO_SECRETKEYBYTES];
        hexin(v[2]); PQCLEAN_MLDSA44_CLEAN_crypto_sign_keypair(pk, sk); spit(v[3], pk, sizeof pk); spit(v[4], sk, sizeof sk); puts("KEYGEN_OK"); return 0;
    }
    fprintf(stderr, "usage: see header\n"); return 1;
}
