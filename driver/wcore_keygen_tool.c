/* seal_v8 phase 3 operator tool (C, no Python): generate this node's ML-DSA-44 key INSIDE THE PL, once per boot/load.
 *   sudo ./wcore_keygen_tool [identity_dir]      (default /home/xilinx/wepwawet-core/firmware/identity)
 * 1) backs up node_pk.bin, node_tr.bin, trusted_peer_pk.bin (copied) and node_sk.bin (MOVED, so F' cannot open it) into
 *    identity_dir/backup_<YYYYmmdd_HHMMSS>/ -- nothing is deleted
 * 2) ZEROIZE if a key is already sealed (that key is destroyed), then KEYGEN in the PL (xi from the PL TRNG path)
 * 3) writes the PUBLIC node_pk.bin (1312 B = rho || SimpleBitPack(t1,10)) and node_tr.bin (64 B = SHAKE256(pk,64))
 * The private key never exists outside the PL. A PL reload/reset or ZEROIZE destroys it: run this tool again and
 * redo the peer pk exchange. Requires VERSION 0x0003_0003 (phase-3 image). */
#define _GNU_SOURCE
#include "wcore_fpga.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
static int copyf(const char *a, const char *b) {
    FILE *i = fopen(a, "rb"); if (!i) return errno == ENOENT ? 1 : -1;
    FILE *o = fopen(b, "wb"); if (!o) { fclose(i); return -1; }
    char buf[4096]; size_t n; int r = 0;
    while ((n = fread(buf, 1, sizeof buf, i)) > 0) if (fwrite(buf, 1, n, o) != n) r = -1;
    fclose(i); if (fclose(o)) r = -1; return r;
}
static int writef(const char *p, const void *d, size_t n) {
    char t[1100]; snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "wb"); if (!f) return -1;
    int ok = fwrite(d, 1, n, f) == n; if (fclose(f)) ok = 0;
    if (!ok || rename(t, p)) return -1;
    chmod(p, 0644); return 0;
}
int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "/home/xilinx/wepwawet-core/firmware/identity";
    static wcore_t w; static uint8_t pk[WCORE_PK_BYTES]; uint8_t tr[64], fp[32]; wcore_stats_t st; char p[1024], q[1024], bdir[1024];
    int r = wcore_open(&w, 100); if (r) { fprintf(stderr, "wcore_open failed %d (image loaded? root?)\n", r); return 2; }
    if (w.version != WCORE_VERSION_V8P3) { fprintf(stderr, "VERSION 0x%08x: not the phase-3 KeyGen image (0x00030003)\n", w.version); return 2; }
    if ((wcore_trng_reg(&w) >> 25) & 1) { fprintf(stderr, "DET_RND build: refusing\n"); return 2; }
    time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm); char ts[32]; strftime(ts, sizeof ts, "%Y%m%d_%H%M%S", &tm);
    snprintf(bdir, sizeof bdir, "%s/backup_%s", dir, ts);
    if (mkdir(bdir, 0700) && errno != EEXIST) { perror(bdir); return 1; }
    const char *cp[3] = {"node_pk.bin", "node_tr.bin", "trusted_peer_pk.bin"};
    for (int i = 0; i < 3; i++) { snprintf(p, sizeof p, "%s/%s", dir, cp[i]); snprintf(q, sizeof q, "%s/%s", bdir, cp[i]);
        r = copyf(p, q); if (r < 0) { fprintf(stderr, "backup of %s failed\n", p); return 1; }
        printf("backup %-20s %s\n", cp[i], r ? "(absent)" : q); }
    snprintf(p, sizeof p, "%s/node_sk.bin", dir); snprintf(q, sizeof q, "%s/node_sk.bin", bdir);
    if (!access(p, F_OK)) { if (rename(p, q)) { perror("move node_sk.bin"); return 1; } chmod(q, 0600); printf("moved  node_sk.bin          -> %s (F' cannot open it any more)\n", q); }
    else printf("backup node_sk.bin          (absent)\n");
    if (wcore_status(&w) & (1u << 10)) { r = wcore_zeroize(&w); printf("previous sealed key ZEROIZED rc=%d\n", r); if (r) return 1; }
    r = wcore_keygen(&w, pk, &st);
    printf("WCORE_KEYGEN rc=%d cycles=%u wait=%.0fus errors=0x%08x trng=0x%08x status=0x%08x\n", r, st.cycles, st.wait_us, st.errors, st.trng_reg, wcore_status(&w));
    if (r) { fprintf(stderr, "KEYGEN failed (fail closed). Previous identity files are in %s\n", bdir); return 1; }
    wcore_shake256(tr, 64, pk, WCORE_PK_BYTES); wcore_shake256(fp, 32, pk, WCORE_PK_BYTES);
    snprintf(p, sizeof p, "%s/node_pk.bin", dir); if (writef(p, pk, sizeof pk)) { perror(p); return 1; }
    snprintf(p, sizeof p, "%s/node_tr.bin", dir); if (writef(p, tr, sizeof tr)) { perror(p); return 1; }
    printf("wrote %s/node_pk.bin (1312 B) and node_tr.bin (64 B); pk SHAKE256-256 fingerprint ", dir);
    for (int i = 0; i < 32; i++) printf("%02x", fp[i]); printf("\n");
    printf("NEXT: copy node_pk.bin to the PEER as trusted_peer_pk.bin (see STEPS_DUPLEX_V8.md), then start F'.\n");
    wcore_close(&w); return 0;
}
