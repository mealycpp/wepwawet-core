/* seal_v8 operator tool (C, no Python): seal a node key into the PL once at boot.
 *   sudo ./wcore_provision /path/node_sk.bin [tr_out]   provision + LOCK (ZEROIZEs first), write public tr = H(pk)
 *   sudo ./wcore_provision --zeroize              ZEROIZE (wipe all scratchpad banks, clear LOCK)
 *   sudo ./wcore_provision --status
 * After provisioning, protect or delete node_sk.bin (operator step; the PL cannot protect the SD card).
 * F' then only needs node_pk.bin (public) and calls wcore_attach_sealed(). */
#include "wcore_fpga.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    static wcore_t w; int r = wcore_open(&w, 100);
    if (r) { fprintf(stderr, "wcore_open failed %d\n", r); return 2; }
    if (!wcore_is_v8(&w)) { fprintf(stderr, "VERSION 0x%08x is not seal_v8 phase 2\n", w.version); return 2; }
    if (argc > 1 && !strcmp(argv[1], "--zeroize")) r = wcore_zeroize(&w);
    else if (argc > 1 && strcmp(argv[1], "--status")) {
        if (wcore_status(&w) & (1u << 10)) { r = wcore_zeroize(&w); if (r) { fprintf(stderr, "zeroize failed %d\n", r); return 1; } }
        r = wcore_provision_file(&w, argv[1]);
        if (r == 0) {                                     /* tr = H(pk) is public: F' attaches with it, never with sk */
            char p[1024]; snprintf(p, sizeof p, "%s", argc > 2 ? argv[2] : "/home/xilinx/wepwawet-core/firmware/identity/node_tr.bin");
            FILE *f = fopen(p, "wb"); if (!f || fwrite(w.tr, 1, 64, f) != 64) { fprintf(stderr, "cannot write %s\n", p); r = -47; }
            if (f) fclose(f); if (!r) printf("wrote public tr to %s\n", p);
        }
    } else r = 0;
    printf("WCORE_PROVISION rc=%d STATUS=0x%08x SEAL=0x%08x TRNG=0x%08x locked=%u\n", r, wcore_status(&w), wcore_seal_reg(&w),
           wcore_trng_reg(&w), (wcore_status(&w) >> 10) & 1);
    w.sign = w.sign; wcore_close(&w);
    return r ? 1 : 0;
}
