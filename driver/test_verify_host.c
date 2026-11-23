/* Host test of wcore_verify_prepare against the verify_v1 dilithium-py oracle vectors (no hardware). */
#include "wcore_fpga.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static size_t rd(const char*d,const char*f,uint8_t*b,size_t n){char p[600];snprintf(p,sizeof p,"%s/%s",d,f);FILE*x=fopen(p,"rb");if(!x){perror(p);exit(2);}size_t r=fread(b,1,n,x);fclose(x);return r;}
static int mem(const char*d,const char*f,uint64_t*w,int n){char p[600];snprintf(p,sizeof p,"%s/%s",d,f);FILE*x=fopen(p,"r");if(!x){perror(p);exit(2);}int i=0;unsigned long long v;while(i<n&&fscanf(x,"%llx",&v)==1)w[i++]=v;fclose(x);return i;}
static int cmp(const char*name,const uint64_t*a,const uint64_t*b,int n){int ok=!memcmp(a,b,8*(size_t)n);printf("  %-4s %s\n",name,ok?"MATCH":"MISMATCH");return ok;}
int main(int argc,char**argv){
  int all=1;
  for(int a=1;a<argc;a++){
    const char*d=argv[a]; static uint8_t pk[1312],msg[4096],sig[2420]; static uint64_t w[512]; static wcore_vprep_t v; int ok=1;
    rd(d,"pk.bin",pk,1312); size_t ml=rd(d,"msg.bin",msg,4096); rd(d,"sig.bin",sig,2420);
    uint64_t zr[1]; mem(d,"zrej.mem",zr,1); int expect = zr[0] ? 2 : 0;
    int r=wcore_verify_prepare(&v,pk,msg,ml,sig);
    printf("%s: prepare=%d (expect %d) %s\n",d,r,expect,r==expect?"OK":"WRONG"); ok&=(r==expect);
    mem(d,"ctilde_4x64.mem",w,4); ok&=cmp("ct",v.ct,w,4);
    mem(d,"z_512x64.mem",w,512); ok&=cmp("z",v.z,w,512);
    mem(d,"h_512x64.mem",w,512); ok&=cmp("h",v.h,w,512);
    if(r==0){
      mem(d,"rho_4x64.mem",w,4); ok&=cmp("rho",v.rho,w,4);
      mem(d,"mu_8x64.mem",w,8); ok&=cmp("mu",v.mu,w,8);
      mem(d,"t1hat2d_512x64.mem",w,512); ok&=cmp("t1h",v.t1h,w,512);
    }
    all&=ok;
  }
  /* malformed-hint negative tests on the first vector: decreasing index, unused slot non-zero, end > omega */
  { static uint8_t pk[1312],msg[4096],sig[2420]; static wcore_vprep_t v; const char*d=argv[1];
    rd(d,"pk.bin",pk,1312); size_t ml=rd(d,"msg.bin",msg,4096); rd(d,"sig.bin",sig,2420);
    uint8_t *hb=sig+32+2304; uint8_t s[2420]; int r1,r2,r3;
    memcpy(s,sig,2420); { uint8_t *h=s+32+2304; if(h[80]>=2){uint8_t t=h[0];h[0]=h[1];h[1]=t;} } r1=wcore_verify_prepare(&v,pk,msg,ml,s);
    memcpy(s,sig,2420); { uint8_t *h=s+32+2304; int used=h[83]; if(used<80) h[79]=1; } r2=wcore_verify_prepare(&v,pk,msg,ml,s);
    memcpy(s,sig,2420); { uint8_t *h=s+32+2304; h[83]=81; } r3=wcore_verify_prepare(&v,pk,msg,ml,s);
    (void)hb; printf("malformed hint: swap-order=%d unused-slot=%d end>omega=%d (expect 1 1 1) %s\n",r1,r2,r3,(r1==1&&r2==1&&r3==1)?"OK":"WRONG");
    all&=(r1==1&&r2==1&&r3==1);
  }
  printf(all?"VERIFY HOST PASS\n":"VERIFY HOST FAIL\n"); return !all;
}
