/* Ground certificate authority for seal_v8 node keys (runs on the PC / Linux VM; NEVER on a board).
 * PQClean ML-DSA-44 "clean" (randomized = hedged signing, FIPS 204 default), pure ML-DSA, empty context.
 *   ground_ca keygen  <dir>                     -> <dir>/ground_sk.bin (stays on the ground), <dir>/ground_pk.bin
 *   ground_ca issue   <dir> <NODE> node_pk.bin  -> <NODE>.cert (2420 B) = Sign(ground_sk, "WCORE-CERT-V1|<NODE>|" || SHAKE256(pk,32))
 *   ground_ca check   <dir> <NODE> node_pk.bin <NODE>.cert   (ground-side re-check, PQClean)                     */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "api.h"
#include "fips202.h"
static size_t rdf(const char *p, uint8_t *b, size_t n) { FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(2); } size_t r = fread(b, 1, n, f); int extra = fgetc(f) != EOF; fclose(f); if (extra) { fprintf(stderr, "%s: too long\n", p); exit(2); } return r; }
static void wrf(const char *p, const uint8_t *b, size_t n) { FILE *f = fopen(p, "wb"); if (!f || fwrite(b, 1, n, f) != n) { perror(p); exit(2); } fclose(f); }
static size_t certmsg(uint8_t *m, const char *node, const uint8_t pk[1312]) {
    size_t l = (size_t)snprintf((char*)m, 200, "WCORE-CERT-V1|%s|", node);
    shake256(m + l, 32, pk, 1312); return l + 32;
}
int main(int c, char **v) {
    static uint8_t pk[1312], sk[2560], npk[1312], sig[2420], m[256]; char p[1024];
    if (c >= 3 && !strcmp(v[1], "keygen")) {
        snprintf(p, sizeof p, "%s/ground_sk.bin", v[2]); FILE *t = fopen(p, "rb"); if (t) { fclose(t); fprintf(stderr, "%s exists: refusing to overwrite\n", p); return 1; }
        PQCLEAN_MLDSA44_CLEAN_crypto_sign_keypair(pk, sk);
        wrf(p, sk, sizeof sk); snprintf(p, sizeof p, "%s/ground_pk.bin", v[2]); wrf(p, pk, sizeof pk);
        memset(sk, 0, sizeof sk); printf("GROUND_CA keygen: %s/ground_pk.bin (public), ground_sk.bin (ground only)\n", v[2]); return 0;
    }
    if (c >= 5 && !strcmp(v[1], "issue")) {
        snprintf(p, sizeof p, "%s/ground_sk.bin", v[2]); if (rdf(p, sk, sizeof sk) != sizeof sk) return 2;
        if (rdf(v[4], npk, sizeof npk) != sizeof npk) { fprintf(stderr, "node pk must be 1312 B\n"); return 2; }
        size_t ml = certmsg(m, v[3], npk), sl = 0;
        if (PQCLEAN_MLDSA44_CLEAN_crypto_sign_signature(sig, &sl, m, ml, sk) || sl != 2420) { fprintf(stderr, "sign failed\n"); return 1; }
        memset(sk, 0, sizeof sk); snprintf(p, sizeof p, "%s.cert", v[3]); wrf(p, sig, sl);
        printf("GROUND_CA issued %s for %s (hedged ML-DSA-44, PQClean clean)\n", p, v[3]); return 0;
    }
    if (c >= 6 && !strcmp(v[1], "check")) {
        snprintf(p, sizeof p, "%s/ground_pk.bin", v[2]); rdf(p, pk, sizeof pk); rdf(v[4], npk, sizeof npk); rdf(v[5], sig, sizeof sig);
        size_t ml = certmsg(m, v[3], npk);
        int ok = PQCLEAN_MLDSA44_CLEAN_crypto_sign_verify(sig, 2420, m, ml, pk) == 0;
        printf("GROUND_CA check %s: %s (verifier: PQClean clean, ground)\n", v[3], ok ? "VALID" : "INVALID"); return !ok;
    }
    fprintf(stderr, "usage: ground_ca keygen <dir> | issue <dir> <NODE> node_pk.bin | check <dir> <NODE> node_pk.bin NODE.cert\n"); return 2;
}
