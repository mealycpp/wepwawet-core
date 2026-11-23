#include "wcore_fpga.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static size_t rd(const char*d,const char*f,uint8_t*b,size_t n){char p[512];snprintf(p,sizeof p,"%s/%s",d,f);FILE*x=fopen(p,"rb");if(!x){perror(p);exit(2);}size_t r=fread(b,1,n,x);fclose(x);return r;}
static int mem(const char*d,const char*f,uint64_t*w,int n){char p[512];snprintf(p,sizeof p,"%s/%s",d,f);FILE*x=fopen(p,"r");int i=0;unsigned long long v;while(i<n&&fscanf(x,"%llx",&v)==1)w[i++]=v;fclose(x);return i;}
static int cmp(const char*name,const uint64_t*a,const uint64_t*b,int n){int ok=!memcmp(a,b,8*n);printf("%-6s %s\n",name,ok?"MATCH":"MISMATCH");return ok;}
int main(int c,char**v){
  const char*d=v[1]; static uint8_t sk[2560],msg[4096],ref[2420],sig[2420],rho_p[64]; static uint64_t w[512]; wcore_prep_t p; int ok=1;
  rd(d,"sk_TEST_ONLY.bin",sk,2560); size_t ml=rd(d,"msg.bin",msg,4096); rd(d,"signature_REFERENCE_ONLY.bin",ref,2420);
  uint8_t rnd[32]={0}; wcore_prepare_key(&p,sk); wcore_prepare_msg(&p,sk,msg,ml,rnd);
  mem(d,"rho_4x64.mem",w,4); ok&=cmp("rho",p.rho,w,4);
  mem(d,"mu_8x64.mem",w,8); ok&=cmp("mu",p.mu,w,8);
  mem(d,"candidate_mask_seed_nonce_36x64.mem",w,36); ok&=cmp("rhop",p.rhop,w,8);
  mem(d,"s1_hat_512x64.mem",w,512); ok&=cmp("s1",p.s1,w,512);
  mem(d,"s2_hat_512x64.mem",w,512); ok&=cmp("s2",p.s2,w,512);
  mem(d,"t0_hat_512x64.mem",w,512); ok&=cmp("t0",p.t0,w,512);
  static uint32_t zc[1024],hc[1024]; uint8_t ct[32];
  mem(d,"ctilde_4x64.mem",w,4); for(int i=0;i<32;i++) ct[i]=(uint8_t)(w[i/8]>>(8*(i%8)));
  mem(d,"z_512x64.mem",w,512); for(int i=0;i<512;i++){zc[2*i]=(uint32_t)w[i];zc[2*i+1]=(uint32_t)(w[i]>>32);}
  mem(d,"h_512x64.mem",w,512); for(int i=0;i<512;i++){hc[2*i]=(uint32_t)w[i];hc[2*i+1]=(uint32_t)(w[i]>>32);}
  int r=wcore_pack_sig(sig,ct,zc,hc); int sm=(r==0)&&!memcmp(sig,ref,2420); printf("pack   %s\n",sm?"MATCH reference signature":"MISMATCH"); ok&=sm;
  (void)rho_p; printf(ok?"HOST PASS\n":"HOST FAIL\n"); return !ok;
}
