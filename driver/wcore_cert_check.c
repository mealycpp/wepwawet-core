/* Board tool: accept a peer's PL-generated public key only if the ground CA certified it.
 *   sudo ./wcore_cert_check ground_pk.bin <PEER> peer_pk.bin <PEER>.cert [--install]
 * cert = ML-DSA-44 signature by the ground key over "WCORE-CERT-V1|<PEER>|" || SHAKE256(peer_pk, 32).
 * Verifier: the FABRIC ML-DSA-44 Verify program (wcore_verify, seal_v8 image); with -DWITH_PQCLEAN also PQClean (CPU).
 * Self-test always run first: the same cert must be REJECTED for a tampered pk (1 bit) and for a tampered cert (1 bit).
 * --install: back up identity/trusted_peer_pk.bin to identity/backup_cert_<ts>/ and install peer_pk.bin (only if valid).
 * Stop F' first (one PL user at a time). LIMIT: ground_pk.bin is a host file, so root can substitute it -- this is a
 * protocol demonstration; the root-resistant anchor is the bitstream-constant pin (simulation only). */
#define _GNU_SOURCE
#include "wcore_fpga.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <sys/stat.h>
#ifdef WITH_PQCLEAN
#include "api.h"
#endif
static size_t rdf(const char *p, uint8_t *b, size_t n) { FILE *f = fopen(p, "rb"); if (!f) { perror(p); exit(2); } size_t r = fread(b, 1, n, f); int x = fgetc(f) != EOF; fclose(f); if (x || r != n) { fprintf(stderr, "%s: wrong size\n", p); exit(2); } return r; }
static size_t certmsg(uint8_t *m, const char *node, const uint8_t pk[1312]) {
    size_t l = (size_t)snprintf((char*)m, 200, "WCORE-CERT-V1|%s|", node); wcore_shake256(m + l, 32, pk, 1312); return l + 32;
}
static wcore_t w;
static int fabric(const uint8_t *gpk, const char *node, const uint8_t *pk, const uint8_t *cert) {
    uint8_t m[256]; size_t ml = certmsg(m, node, pk); int valid = 0; wcore_stats_t st;
    int r = wcore_verify(&w, &valid, gpk, m, ml, cert, &st);
    return r ? -1 : valid;
}
#ifdef WITH_PQCLEAN
static int cpu(const uint8_t *gpk, const char *node, const uint8_t *pk, const uint8_t *cert) {
    uint8_t m[256]; size_t ml = certmsg(m, node, pk);
    return PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(cert, 2420, m, ml, gpk) == 0;
}
#endif
int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: wcore_cert_check ground_pk.bin PEER peer_pk.bin PEER.cert [--install]\n"); return 2; }
    static uint8_t gpk[1312], pk[1312], cert[2420], bad_pk[1312], bad_cert[2420];
    rdf(argv[1], gpk, sizeof gpk); rdf(argv[3], pk, sizeof pk); rdf(argv[4], cert, sizeof cert);
    int r = wcore_open(&w, 100); if (r || !wcore_has_verify(&w)) { fprintf(stderr, "fabric verifier unavailable (rc=%d VERSION=0x%08x)\n", r, w.version); return 2; }
    memcpy(bad_pk, pk, sizeof pk); bad_pk[100] ^= 1; memcpy(bad_cert, cert, sizeof cert); bad_cert[40] ^= 1;
    int ok = fabric(gpk, argv[2], pk, cert), t1 = fabric(gpk, argv[2], bad_pk, cert), t2 = fabric(gpk, argv[2], pk, bad_cert);
    printf("CERT_CHECK verifier=FABRIC(ML-DSA-44 Verify program, VERSION 0x%08x) peer=%s valid=%d tampered_pk_rejected=%d tampered_cert_rejected=%d\n",
           w.version, argv[2], ok, t1 == 0, t2 == 0);
    int pass = ok == 1 && t1 == 0 && t2 == 0;
#ifdef WITH_PQCLEAN
    int c0 = cpu(gpk, argv[2], pk, cert), c1 = cpu(gpk, argv[2], bad_pk, cert), c2 = cpu(gpk, argv[2], pk, bad_cert);
    printf("CERT_CHECK verifier=CPU(PQClean ML-DSA-44 aarch64) valid=%d tampered_pk_rejected=%d tampered_cert_rejected=%d\n", c0, !c1, !c2);
    pass = pass && c0 && !c1 && !c2;
#endif
    wcore_close(&w);
    if (!pass) { printf("CERT_CHECK RESULT: REJECT (peer pk NOT installed)\n"); return 1; }
    if (argc > 5 && !strcmp(argv[5], "--install")) {
        const char *dir = "/home/xilinx/wepwawet-core/firmware/identity"; char b[1024], p[1024], q[1024], ts[32];
        time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm); strftime(ts, sizeof ts, "%Y%m%d_%H%M%S", &tm);
        snprintf(b, sizeof b, "%s/backup_cert_%s", dir, ts); if (mkdir(b, 0700) && errno != EEXIST) { perror(b); return 1; }
        snprintf(p, sizeof p, "%s/trusted_peer_pk.bin", dir); snprintf(q, sizeof q, "%s/trusted_peer_pk.bin", b);
        FILE *i = fopen(p, "rb"); if (i) { uint8_t t[1312]; size_t n = fread(t, 1, sizeof t, i); fclose(i); FILE *o = fopen(q, "wb"); if (!o || fwrite(t, 1, n, o) != n) { perror(q); return 1; } fclose(o); }
        snprintf(q, sizeof q, "%s.tmp", p); FILE *o = fopen(q, "wb"); if (!o || fwrite(pk, 1, sizeof pk, o) != sizeof pk || fclose(o) || rename(q, p)) { perror(p); return 1; }
        chmod(p, 0644); printf("installed %s (previous one in %s)\n", p, b);
    }
    printf("CERT_CHECK RESULT: ACCEPT\n");
    return 0;
}
