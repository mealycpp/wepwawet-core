/* Prints the WCORE MAGIC/VERSION/STATUS/SEAL/TRNG registers via /dev/mem (no PYNQ/XRT). Exit 0 only for seal_v8 phase 2. */
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
int main(void) {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC); if (fd < 0) { perror("/dev/mem"); return 2; }
    volatile uint32_t *p = mmap(NULL, 0x20000, PROT_READ, MAP_SHARED, fd, 0xA0000000u);
    if (p == MAP_FAILED) { perror("mmap"); return 2; }
    uint32_t magic = p[0x10014/4], ver = p[0x10018/4], st = p[0x10004/4], seal = p[0x1001C/4], trng = p[0x10020/4];
    int ok = magic == 0x57435331u && (ver == 0x00030002u || ver == 0x00030003u) && !((trng >> 25) & 1);
    printf("WCORE_CHECK MAGIC=0x%08x VERSION=0x%08x STATUS=0x%08x locked=%u SEAL=0x%08x TRNG=0x%08x DET_RND=%u -> %s\n",
           magic, ver, st, (st >> 10) & 1, seal, trng, (trng >> 25) & 1, ok ? "seal_v8 ALIVE" : "NOT seal_v8 phase 2 board image");
    return ok ? 0 : 1;
}
