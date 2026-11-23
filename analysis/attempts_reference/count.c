#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "api.h"
#include "randombytes.h"
extern unsigned long g_attempts,g_rz,g_rr0,g_rct0,g_rh;
int main(int argc,char**argv){ int K=atoi(argv[1]), N=atoi(argv[2]);
 uint8_t pk[PQCLEAN_MLDSA44_CLEAN_CRYPTO_PUBLICKEYBYTES], sk[PQCLEAN_MLDSA44_CLEAN_CRYPTO_SECRETKEYBYTES], sig[PQCLEAN_MLDSA44_CLEAN_CRYPTO_BYTES], m[64]; size_t sl;
 unsigned long hist[64]={0}; double sum=0; long tot=0;
 for(int k=0;k<K;k++){ PQCLEAN_MLDSA44_CLEAN_crypto_sign_keypair(pk,sk);
  unsigned long ka=g_attempts;
  for(int i=0;i<N;i++){ randombytes(m,sizeof m); unsigned long a0=g_attempts;
   PQCLEAN_MLDSA44_CLEAN_crypto_sign_signature(sig,&sl,m,sizeof m,sk);
   unsigned long a=g_attempts-a0; sum+=a; tot++; hist[a<63?a:63]++; } }
 printf("signatures %ld mean_attempts %.4f  rejects: z %lu r0 %lu ct0 %lu hint %lu\n",tot,sum/tot,g_rz,g_rr0,g_rct0,g_rh);
 for(int i=1;i<40;i++) if(hist[i]) printf("%d:%lu ",i,hist[i]); printf("\n"); return 0;}
