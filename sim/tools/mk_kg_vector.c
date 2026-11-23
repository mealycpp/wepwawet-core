/* dev tool: sk -> s1_hat/s2_hat/t0_hat/K .mem (driver's wcore_prepare_key, already checked vs the oracle mems) */
#include "wcore_fpga.h"
#include <stdio.h>
int main(int c, char **v) { static uint8_t sk[2560]; FILE *f = fopen(v[1], "rb"); fread(sk, 1, 2560, f); fclose(f);
  static wcore_prep_t p; wcore_prepare_key(&p, sk); char n[600]; const char *nm[3] = {"s1_hat", "s2_hat", "t0_hat"}; uint64_t *a[3] = {p.s1, p.s2, p.t0};
  for (int k = 0; k < 3; k++) { snprintf(n, sizeof n, "%s/%s_512x64.mem", v[2], nm[k]); f = fopen(n, "w"); for (int i = 0; i < 512; i++) fprintf(f, "%016llx\n", (unsigned long long)a[k][i]); fclose(f); }
  return 0; }
