#define _GNU_SOURCE
#include "wcore_fpga.h"
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define Q 8380417
#define REG (0x10000u / 4u)
#define MAGIC 0x57435331u
#define SIGN_BASE 0xA0000000u
#define TRNG_BASE 0xA0020000u

/* ---------------- Keccak / SHAKE256 (FIPS 202) ---------------- */
static const uint64_t RC[24] = {
 0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,0x000000000000808bULL,
 0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,0x000000000000008aULL,0x0000000000000088ULL,
 0x0000000080008009ULL,0x000000008000000aULL,0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,
 0x8000000000008003ULL,0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,
 0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL};
static const int ROT[25] = {0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14};
#define ROL(x,n) ((n)?(((x)<<(n))|((x)>>(64-(n)))):(x))
static void keccakf(uint64_t s[25]) {
    for (int r = 0; r < 24; r++) {
        uint64_t C[5], D[5], B[25];
        for (int x = 0; x < 5; x++) C[x] = s[x]^s[x+5]^s[x+10]^s[x+15]^s[x+20];
        for (int x = 0; x < 5; x++) D[x] = C[(x+4)%5] ^ ROL(C[(x+1)%5],1);
        for (int i = 0; i < 25; i++) s[i] ^= D[i%5];
        for (int x = 0; x < 5; x++) for (int y = 0; y < 5; y++)
            B[y + 5*((2*x+3*y)%5)] = ROL(s[x+5*y], ROT[x+5*y]);
        for (int x = 0; x < 5; x++) for (int y = 0; y < 5; y++)
            s[x+5*y] = B[x+5*y] ^ ((~B[(x+1)%5+5*y]) & B[(x+2)%5+5*y]);
        s[0] ^= RC[r];
    }
}
void wcore_shake256(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen) {
    uint64_t s[25] = {0}; const size_t R = 136; uint8_t blk[136];
    while (inlen >= R) { for (size_t i = 0; i < R; i++) s[i/8] ^= (uint64_t)in[i] << (8*(i%8)); keccakf(s); in += R; inlen -= R; }
    memset(blk, 0, R); memcpy(blk, in, inlen); blk[inlen] ^= 0x1F; blk[R-1] ^= 0x80;
    for (size_t i = 0; i < R; i++) s[i/8] ^= (uint64_t)blk[i] << (8*(i%8));
    keccakf(s);
    while (outlen) {
        size_t n = outlen < R ? outlen : R;
        for (size_t i = 0; i < n; i++) out[i] = (uint8_t)(s[i/8] >> (8*(i%8)));
        out += n; outlen -= n; if (outlen) keccakf(s);
    }
}

/* ---------------- NTT (FIPS 204 Alg. 41, same convention as dilithium-py) ---------------- */
static int32_t zetas[256]; static int zinit;
static int64_t modq(int64_t a) { a %= Q; return a < 0 ? a + Q : a; }
static void init_zetas(void) {
    if (zinit) return;
    for (int k = 0; k < 256; k++) {
        int br = 0; for (int b = 0; b < 8; b++) br |= ((k >> b) & 1) << (7 - b);
        int64_t z = 1; for (int e = 0; e < br; e++) z = (z * 1753) % Q;
        zetas[k] = (int32_t)z;
    }
    zinit = 1;
}
static void ntt(int64_t c[256]) {
    init_zetas(); int k = 0;
    for (int l = 128; l > 0; l >>= 1)
        for (int start = 0; start < 256; start += 2*l) {
            int64_t z = zetas[++k];
            for (int j = start; j < start + l; j++) {
                int64_t t = modq(z * c[j+l]); c[j+l] = modq(c[j] - t); c[j] = modq(c[j] + t);
            }
        }
}
static uint32_t getbits(const uint8_t *b, size_t bit, int n) {
    uint32_t v = 0; for (int i = 0; i < n; i++) v |= (uint32_t)((b[(bit+i)>>3] >> ((bit+i)&7)) & 1) << i; return v;
}
static void words_from_poly(uint64_t *w, const int64_t c[256]) {
    for (int i = 0; i < 128; i++) w[i] = (uint64_t)(uint32_t)c[2*i] | ((uint64_t)(uint32_t)c[2*i+1] << 32);
}
static void le64(uint64_t *w, const uint8_t *b, int nw) {
    for (int i = 0; i < nw; i++) { uint64_t v = 0; for (int j = 7; j >= 0; j--) v = (v << 8) | b[8*i+j]; w[i] = v; }
}
void wcore_prepare_key(wcore_prep_t *p, const uint8_t sk[WCORE_SK_BYTES]) {
    const uint8_t *s1 = sk + 128, *s2 = s1 + 4*96, *t0 = s2 + 4*96;
    int64_t c[256];
    le64(p->rho, sk, 4);
    for (int q = 0; q < 4; q++) {
        for (int i = 0; i < 256; i++) c[i] = 2 - (int64_t)getbits(s1 + 96*q, 3*i, 3);
        ntt(c); words_from_poly(p->s1 + 128*q, c);
        for (int i = 0; i < 256; i++) c[i] = 2 - (int64_t)getbits(s2 + 96*q, 3*i, 3);
        ntt(c); words_from_poly(p->s2 + 128*q, c);
        for (int i = 0; i < 256; i++) c[i] = 4096 - (int64_t)getbits(t0 + 416*q, 13*i, 13);
        ntt(c); words_from_poly(p->t0 + 128*q, c);
    }
}
void wcore_prepare_msg(wcore_prep_t *p, const uint8_t sk[WCORE_SK_BYTES], const uint8_t *msg, size_t mlen,
                       const uint8_t rnd[32]) {
    static uint8_t buf[64 + 2 + 65536]; uint8_t mu[64], kr[32+32+64], rp[64];
    size_t n = mlen > 65536 ? 65536 : mlen;
    memcpy(buf, sk + 64, 64); buf[64] = 0; buf[65] = 0; memcpy(buf + 66, msg, n);   /* pure ML-DSA, empty ctx */
    wcore_shake256(mu, 64, buf, 66 + n);
    memcpy(kr, sk + 32, 32); memcpy(kr + 32, rnd, 32); memcpy(kr + 64, mu, 64);
    wcore_shake256(rp, 64, kr, sizeof kr);
    le64(p->mu, mu, 8); le64(p->rhop, rp, 8);
}
int wcore_pack_sig(uint8_t sig[WCORE_SIG_BYTES], const uint8_t ctilde[32], const uint32_t zc[1024], const uint32_t hc[1024]) {
    const int32_t G1 = 1 << 17; memset(sig, 0, WCORE_SIG_BYTES); memcpy(sig, ctilde, 32);
    uint8_t *zb = sig + 32;
    for (int i = 0; i < 1024; i++) {
        int64_t x = zc[i], v = x >= 0x80000000LL ? x - (1LL << 32) : (x <= Q/2 ? x : x - Q);
        if (!(-G1 < v && v < G1)) return -1;
        uint32_t u = (uint32_t)(G1 - v); size_t bit = 18*(size_t)i;
        for (int b = 0; b < 18; b++) if ((u >> b) & 1) zb[(bit+b)>>3] |= (uint8_t)(1u << ((bit+b)&7));
    }
    uint8_t *h = sig + 32 + 2304; int cnt = 0;
    for (int q = 0; q < 4; q++) {
        for (int i = 0; i < 256; i++) if (hc[256*q + i]) { if (cnt >= 80) return -2; h[cnt++] = (uint8_t)i; }
        h[80 + q] = (uint8_t)cnt;
    }
    return 0;
}

/* ---------------- hardware ---------------- */
static double now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec*1e6 + t.tv_nsec/1e3; }
int wcore_open(wcore_t *w, unsigned poll_us) {
    memset(w, 0, sizeof *w); w->poll_us = poll_us;
    w->fd = open("/dev/mem", O_RDWR | O_SYNC); if (w->fd < 0) return -1;
    void *a = mmap(NULL, 0x20000, PROT_READ|PROT_WRITE, MAP_SHARED, w->fd, SIGN_BASE);
    void *b = mmap(NULL, 0x1000,  PROT_READ|PROT_WRITE, MAP_SHARED, w->fd, TRNG_BASE);
    if (a == MAP_FAILED || b == MAP_FAILED) return -2;
    w->sign = a; w->trng = b;
    if (w->sign[REG + 0x14/4] != MAGIC) return -3;
    w->version = w->sign[REG + 0x18/4];
    w->trng[0] = 0; w->trng[0x08/4] = 16; w->trng[0] = 1;
    return 0;
}
void wcore_close(wcore_t *w) {
    if (w->sign) munmap((void*)w->sign, 0x20000);
    if (w->trng) munmap((void*)w->trng, 0x1000);
    if (w->fd > 0) close(w->fd); memset(w, 0, sizeof *w);
}
static int trng_words(wcore_t *w, uint32_t *out, int n, uint32_t *hwfail) {
    double t0 = now_us(); int got = 0;
    while (got < n) {
        uint32_t st = w->trng[0x0C/4];
        if (st & 2) (*hwfail)++;
        if (st & 1) out[got++] = w->trng[0x10/4];
        if (now_us() - t0 > 2e6) return -1;
    }
    return 0;
}
static void health(const uint32_t *wd, int n, uint32_t *maxrun, uint32_t *aptworst) {
    int prev = -1, run = 0, mx = 0, worst = 0, ones = 0;
    for (int i = 0; i < 32*n; i++) {
        int b = (wd[i>>5] >> (i & 31)) & 1;
        run = (b == prev) ? run + 1 : 1; prev = b; if (run > mx) mx = run;
        ones += b;
        if ((i & 1023) == 1023) { int d = ones > 512 ? ones : 1024 - ones; if (d > worst) worst = d; ones = 0; }
    }
    *maxrun = (uint32_t)mx; *aptworst = (uint32_t)worst;
}
int wcore_trng_rnd(wcore_t *w, uint8_t rnd[32], wcore_stats_t *st) {
    /* Gate = SP 800-90B RCT (C=41) and APT (W=1024, C=793) at assumed H=0.5 (measured H_original=0.743).
     * The Stage-8 hardware flag uses 32-sample windows with bring-up thresholds (false alarm ~1e-3 per draw
     * on this source): a draw during which it fires is discarded and redrawn (max 3), counted in trng_redraws. */
    uint32_t warm[32], raw[32], mr = 0, aw = 0, mr2 = 0, aw2 = 0; double t0 = now_us();
    st->trng_redraws = 0; st->trng_rc = 0; st->trng_hw_fail = 0;
    for (int tries = 0; ; tries++) {
        uint32_t f = 0;
        if (trng_words(w, warm, 32, &f) || trng_words(w, raw, 32, &f)) { st->trng_rc = -1; return -1; }
        st->trng_hw_fail += f;
        if (!f) break;
        st->trng_redraws++;
        if (tries >= 3) { st->trng_rc = -2; return -2; }
    }
    health(warm, 32, &mr, &aw); health(raw, 32, &mr2, &aw2);
    st->trng_max_run = mr2 > mr ? mr2 : mr; st->trng_apt_worst = aw2 > aw ? aw2 : aw;
    if (st->trng_max_run >= 41) { st->trng_rc = -3; return -3; }
    if (st->trng_apt_worst >= 793) { st->trng_rc = -4; return -4; }
    wcore_shake256(rnd, 32, (const uint8_t*)raw, sizeof raw);
    st->trng_us = now_us() - t0;
    return 0;
}
static void spw(wcore_t *w, int bank, int word, uint64_t v) {
    unsigned off = ((unsigned)bank << 14 | (unsigned)word << 3) / 4;
    w->sign[off] = (uint32_t)v; w->sign[off + 1] = (uint32_t)(v >> 32);   /* low half first, high half commits */
}
static uint64_t spr(wcore_t *w, int bank, int word) {
    unsigned off = ((unsigned)bank << 14 | (unsigned)word << 3) / 4;
    uint64_t lo = w->sign[off], hi = w->sign[off + 1]; return lo | (hi << 32);
}
static int wcore_sign_once(wcore_t *w, uint8_t sig[WCORE_SIG_BYTES], const uint8_t sk[WCORE_SK_BYTES],
               const uint8_t *msg, size_t mlen, int hedged, wcore_stats_t *st) {
    uint8_t rnd[32] = {0}, h[32]; double t0 = now_us(), t;
    memset(st, 0, sizeof *st);
    if (hedged && wcore_trng_rnd(w, rnd, st)) return -10;
    t = now_us();
    /* key cache: compare the full sk (cheap memcmp) instead of hashing 2560 B every signature */
    (void)h;
    if (!w->cache_valid || memcmp(sk, w->cached_sk, WCORE_SK_BYTES)) { wcore_prepare_key(&w->prep, sk); memcpy(w->cached_sk, sk, WCORE_SK_BYTES); w->cache_valid = 1; }
    wcore_prepare_msg(&w->prep, sk, msg, mlen, rnd);
    st->prep_us = now_us() - t;
    for (t = now_us(); (w->sign[REG + 1] & 0x1) || !(w->sign[REG + 1] & 0x8); ) if (now_us() - t > 2e6) return -11;
    t = now_us(); wcore_prep_t *p = &w->prep;
    for (int i = 0; i < 4; i++) spw(w, 2, 512 + i, p->rho[i]);
    for (int i = 0; i < 8; i++) spw(w, 2, 1024 + i, p->mu[i]);
    for (int i = 0; i < 512; i++) { spw(w, 1, 512 + i, p->s1[i]); spw(w, 1, 1536 + i, p->s2[i]); spw(w, 2, 1536 + i, p->t0[i]); }
    for (int i = 0; i < 36; i++) spw(w, 2, i, (i % 9 == 8) ? (uint64_t)(i / 9) : p->rhop[i % 9]);
    for (int i = 0; i < 8; i++) { w->sign[REG + (0x40 + 8*i)/4] = (uint32_t)p->rhop[i]; w->sign[REG + (0x44 + 8*i)/4] = (uint32_t)(p->rhop[i] >> 32); }
    for (int i = 0; i < 4; i++) { w->sign[REG + (0x80 + 8*i)/4] = (uint32_t)p->rho[i];  w->sign[REG + (0x84 + 8*i)/4] = (uint32_t)(p->rho[i] >> 32); }
    st->preload_us = now_us() - t;
    t = now_us(); w->sign[REG] = 1;                                  /* LAUNCH (Sign program) */
    while (!(w->sign[REG + 1] & 0x2)) {                              /* sleep-poll: the ARM core is free */
        if (w->poll_us) { struct timespec ts = {0, (long)w->poll_us * 1000}; nanosleep(&ts, NULL); }
        if (now_us() - t > 5e6) return -12;
    }
    st->wait_us = now_us() - t;
    uint32_t s = w->sign[REG + 1], k = w->sign[REG + 2];
    st->errors = w->sign[REG + 3]; st->cycles = w->sign[REG + 4]; st->kappa = k & 0xffff; st->attempts = k >> 16;
    w->sign[REG] = 2;                                                 /* clear IRQ */
    if (!(s & 0x4)) return -13;
    t = now_us(); uint8_t ct[32]; static uint32_t zc[1024], hc[1024];
    for (int i = 0; i < 4; i++) { uint64_t v = spr(w, 1, 1150 + i); for (int j = 0; j < 8; j++) ct[8*i+j] = (uint8_t)(v >> (8*j)); }
    for (int i = 0; i < 512; i++) {
        uint64_t v = spr(w, 3, 1400 + i); zc[2*i] = (uint32_t)v; zc[2*i+1] = (uint32_t)(v >> 32);
        v = spr(w, 1, i); hc[2*i] = (uint32_t)v; hc[2*i+1] = (uint32_t)(v >> 32);
    }
    int r = wcore_pack_sig(sig, ct, zc, hc);
    st->pack_rc = r;
    st->readback_us = now_us() - t; st->total_us = now_us() - t0;
    return r == -2 ? -15 : (r ? -14 : 0);
}

/* KNOWN PL GAP (found on AUP1, 21:19 Nov 21): the PL Sign program does not apply the FIPS 204
 * Alg. 7 check ||h||_1 <= omega, so ~1-2% of accepted attempts carry 81+ hints. Such an (z,h) is
 * not a valid signature and is never released (fail closed). In hedged mode the driver restarts the
 * whole signing with fresh TRNG randomness (a new independent rejection-sampling run); this is
 * counted in st->omega_restarts and must be reported. Deterministic mode returns -15. The real fix is
 * the omega check in the PL (pending RTL change). */
int wcore_sign(wcore_t *w, uint8_t sig[WCORE_SIG_BYTES], const uint8_t sk[WCORE_SK_BYTES],
               const uint8_t *msg, size_t mlen, int hedged, wcore_stats_t *st) {
    uint32_t restarts = 0; double t0 = now_us(); int r;
    if (wcore_is_v8(w)) {                 /* v7 API on a v8 image: provision once (sealed), then PL-hedged sign */
        if (!hedged) { memset(st, 0, sizeof *st); memset(sig, 0, WCORE_SIG_BYTES); return -30; }  /* board build is hedged only */
        /* reviewer HIGH-9: no copy of sk is kept; only SHAKE256(sk) for key-change detection. Prefer
         * wcore_provision_file()/wcore_attach_sealed() + wcore_sign_sealed(), which never take sk at all. */
        uint8_t hh[32]; wcore_shake256(hh, 32, sk, WCORE_SK_BYTES);
        if (!w->provisioned || memcmp(hh, w->sk_hash, 32)) {
            if (w->sign[REG + 1] & (1u << 10)) { if ((r = wcore_zeroize(w))) return r; }
            if ((r = wcore_provision(w, sk))) return r;
            memcpy(w->sk_hash, hh, 32);
        }
        return wcore_sign_sealed(w, sig, msg, mlen, st);
    }
    for (;;) {
        r = wcore_sign_once(w, sig, sk, msg, mlen, hedged, st);
        if (r != -15 || !hedged || restarts >= 8) break;
        restarts++;
    }
    st->omega_restarts = restarts; st->total_us = now_us() - t0;
    if (r) memset(sig, 0, WCORE_SIG_BYTES);
    return r;
}

/* ---------------- VERIFY (v6 image: same datapath, ROM program at PC150, CTRL bit2) ---------------- */
#define VERSION_V6 0x00020001u
int wcore_verify_prepare(wcore_vprep_t *v, const uint8_t pk[WCORE_PK_BYTES], const uint8_t *msg, size_t mlen,
                         const uint8_t sig[WCORE_SIG_BYTES]) {
    const int32_t G1 = 1 << 17, BOUND = (1 << 17) - 78;       /* gamma1, gamma1 - beta */
    const int OMEGA = 80; int64_t c[256];
    if (!pk || !sig || (!msg && mlen)) return 1;
    memset(v, 0, sizeof *v);
    /* sigDecode: c~ | z (4 x 576 B, 18-bit, z = gamma1 - u) | h (omega + k bytes, FIPS 204 Alg. 21) */
    le64(v->ct, sig, 4);
    const uint8_t *zb = sig + 32, *hb = sig + 32 + 2304;
    int zbad = 0;
    for (int i = 0; i < 1024; i++) {
        int32_t z = G1 - (int32_t)getbits(zb, 18 * (size_t)i, 18);
        if (z >= BOUND || z <= -BOUND) zbad = 1;
        uint64_t u = (uint32_t)z;
        if (i & 1) v->z[i >> 1] |= u << 32; else v->z[i >> 1] = u;
    }
    int idx = 0;
    for (int q = 0; q < 4; q++) {
        int end = hb[OMEGA + q];
        if (end < idx || end > OMEGA) return 1;
        for (int j = idx; j < end; j++) {
            if (j > idx && hb[j] <= hb[j - 1]) return 1;            /* strictly increasing within a poly */
            int k = 256 * q + hb[j];
            v->h[k >> 1] |= (uint64_t)1 << (32 * (k & 1));
        }
        idx = end;
    }
    for (int j = idx; j < OMEGA; j++) if (hb[j]) return 1;          /* unused slots must be zero */
    if (zbad) return 2;
    /* pkDecode: rho | t1 (4 x 320 B, 10-bit) ; t1_hat' = NTT(t1 * 2^13) */
    le64(v->rho, pk, 4);
    for (int q = 0; q < 4; q++) {
        for (int i = 0; i < 256; i++) c[i] = modq((int64_t)getbits(pk + 32 + 320 * q, 10 * (size_t)i, 10) << 13);
        ntt(c); words_from_poly(v->t1h + 128 * q, c);
    }
    /* mu = H(H(pk, 64) || 0 || 0 || M, 64)  (pure ML-DSA, empty context) */
    static uint8_t buf[64 + 2 + 65536]; uint8_t mu[64];
    size_t n = mlen > 65536 ? 65536 : mlen;
    wcore_shake256(buf, 64, pk, WCORE_PK_BYTES); buf[64] = 0; buf[65] = 0;
    if (n) memcpy(buf + 66, msg, n);
    wcore_shake256(mu, 64, buf, 66 + n);
    le64(v->mu, mu, 8);
    return 0;
}
int wcore_has_verify(wcore_t *w) { return w && w->sign && (w->sign[REG + 0x18/4] == VERSION_V6 || wcore_is_v8(w)); }
int wcore_verify(wcore_t *w, int *valid, const uint8_t pk[WCORE_PK_BYTES], const uint8_t *msg, size_t mlen,
                 const uint8_t sig[WCORE_SIG_BYTES], wcore_stats_t *st) {
    static wcore_vprep_t v; double t0 = now_us(), t;
    memset(st, 0, sizeof *st); *valid = 0;
    if (!wcore_has_verify(w)) return -20;
    t = now_us(); int pr = wcore_verify_prepare(&v, pk, msg, mlen, sig); st->prep_us = now_us() - t;
    if (pr) { st->errors = pr == 2 ? 0x06u : 0xFEu; st->total_us = now_us() - t0; return 0; }   /* PS reject, no launch */
    for (t = now_us(); (w->sign[REG + 1] & 0x1) || !(w->sign[REG + 1] & 0x8); ) if (now_us() - t > 2e6) return -21;
    t = now_us();
    int v8 = wcore_is_v8(w);              /* v8 ABI: mu b2[1048..], t1'_hat b3[1536..]; never touches the sealed key */
    for (int i = 0; i < 4; i++) spw(w, 2, 512 + i, v.rho[i]);
    for (int i = 0; i < 8; i++) spw(w, 2, (v8 ? 1048 : 1024) + i, v.mu[i]);
    for (int i = 0; i < 4; i++) spw(w, 1, 1150 + i, v.ct[i]);
    for (int i = 0; i < 512; i++) { spw(w, 3, i, v.z[i]); spw(w, 3, 512 + i, v.h[i]); spw(w, v8 ? 3 : 2, 1536 + i, v.t1h[i]); }
    if (!v8) for (int i = 0; i < 4; i++) { w->sign[REG + (0x80 + 8*i)/4] = (uint32_t)v.rho[i]; w->sign[REG + (0x84 + 8*i)/4] = (uint32_t)(v.rho[i] >> 32); }
    st->preload_us = now_us() - t;
    t = now_us(); w->sign[REG] = 0x5;                               /* LAUNCH | MODE_VERIFY */
    while (!(w->sign[REG + 1] & 0x2)) {
        if (w->poll_us) { struct timespec ts = {0, (long)w->poll_us * 1000}; nanosleep(&ts, NULL); }
        if (now_us() - t > 2e6) return -22;
    }
    st->wait_us = now_us() - t;
    uint32_t s = w->sign[REG + 1]; st->errors = w->sign[REG + 3]; st->cycles = w->sign[REG + 4]; st->attempts = 1;
    w->sign[REG] = 2;                                                /* clear IRQ */
    if ((st->errors & 0xff) == 0x06) { st->total_us = now_us() - t0; return 0; }   /* PL z-norm reject */
    if (!(s & 0x4)) return -23;
    t = now_us(); int ok = 1;
    for (int i = 0; i < 4; i++) if (spr(w, 1, 1150 + i) != v.ct[i]) ok = 0;
    st->readback_us = now_us() - t; st->total_us = now_us() - t0;
    *valid = ok; return 0;
}

/* ---------------- seal_v8 ---------------- */
int wcore_is_v8(wcore_t *w) { return w && w->sign && (w->sign[REG + 0x18/4] == WCORE_VERSION_V8P2 || w->sign[REG + 0x18/4] == WCORE_VERSION_V8P3); }
uint32_t wcore_status(wcore_t *w)   { return w->sign[REG + 1]; }
uint32_t wcore_seal_reg(wcore_t *w) { return w->sign[REG + 0x1C/4]; }
uint32_t wcore_trng_reg(wcore_t *w) { return w->sign[REG + 0x20/4]; }
static int wait_idle(wcore_t *w, double us) {       /* sp_init_done, !sp_busy, !busy, !zeroizing */
    double t = now_us();
    for (;;) { uint32_t s = w->sign[REG + 1]; if ((s & 0x8) && !(s & 0x10) && !(s & 0x1) && !(s & (1u << 12))) return 0;
               if (now_us() - t > us) return -1; }
}
int wcore_zeroize(wcore_t *w) {
    if (!wcore_is_v8(w)) return -40;
    if (wait_idle(w, 2e6)) return -43;
    w->sign[REG] = 0x10;                              /* ZEROIZE */
    if (wait_idle(w, 2e6)) return -43;
    if (w->sign[REG + 1] & (1u << 10)) return -44;    /* still locked */
    w->provisioned = 0; memset(w->cached_sk, 0, sizeof w->cached_sk); memset(w->sk_hash, 0, 32);
    return 0;
}
int wcore_provision_file(wcore_t *w, const char *sk_path) {
    static uint8_t sk[WCORE_SK_BYTES]; int r = -46;
    FILE *f = fopen(sk_path, "rb"); if (!f) return -46;
    if (fread(sk, 1, sizeof sk, f) == sizeof sk && fgetc(f) == EOF) r = wcore_provision(w, sk);
    fclose(f);
    if (r == 0) wcore_shake256(w->sk_hash, 32, sk, sizeof sk);
    volatile uint8_t *p = sk; for (size_t i = 0; i < sizeof sk; i++) p[i] = 0;
    return r;
}
int wcore_attach_sealed(wcore_t *w, const uint8_t pk[WCORE_PK_BYTES]) {
    if (!wcore_is_v8(w)) return -40;
    if (!(w->sign[REG + 1] & (1u << 10))) return -45;
    wcore_shake256(w->tr, 64, pk, WCORE_PK_BYTES);
    w->provisioned = 1;
    return 0;
}
int wcore_provision(wcore_t *w, const uint8_t sk[WCORE_SK_BYTES]) {
    if (!wcore_is_v8(w)) return -40;
    if (wait_idle(w, 2e6)) return -43;
    if (w->sign[REG + 1] & (1u << 10)) return -41;
    static wcore_prep_t p; uint64_t K[4];
    wcore_prepare_key(&p, sk);
    le64(K, sk + 32, 4);
    for (int i = 0; i < 512; i++) { spw(w, 1, 512 + i, p.s1[i]); spw(w, 1, 1536 + i, p.s2[i]); spw(w, 2, 1536 + i, p.t0[i]); }
    for (int i = 0; i < 4; i++) spw(w, 2, 1040 + i, K[i]);
    for (int i = 0; i < 4; i++) { w->sign[REG + (0x80 + 8*i)/4] = (uint32_t)p.rho[i]; w->sign[REG + (0x84 + 8*i)/4] = (uint32_t)(p.rho[i] >> 32); }
    memcpy(w->tr, sk + 64, 64);
    w->sign[REG] = 0x8;                               /* SEAL_LOCK */
    int ok = (w->sign[REG + 1] & (1u << 10)) != 0;
    if (ok && (spr(w, 1, 512) || spr(w, 2, 1536) || spr(w, 2, 1040))) ok = 0;   /* sealed: must read 0 */
    memset(&p, 0, sizeof p); memset(K, 0, sizeof K);
    if (!ok) return -42;
    w->provisioned = 1; w->cache_valid = 0;
    return 0;
}
int wcore_sign_sealed(wcore_t *w, uint8_t sig[WCORE_SIG_BYTES], const uint8_t *msg, size_t mlen, wcore_stats_t *st) {
    static uint8_t buf[64 + 2 + 65536]; uint8_t mu8[64]; uint64_t mu[8]; double t0 = now_us(), t;
    memset(st, 0, sizeof *st); memset(sig, 0, WCORE_SIG_BYTES);
    if (!wcore_is_v8(w) || !w->provisioned) return -40;
    size_t n = mlen > 65536 ? 65536 : mlen;
    t = now_us();
    memcpy(buf, w->tr, 64); buf[64] = 0; buf[65] = 0; if (n) memcpy(buf + 66, msg, n);   /* pure ML-DSA, empty ctx */
    wcore_shake256(mu8, 64, buf, 66 + n); le64(mu, mu8, 8);
    st->prep_us = now_us() - t;
    if (wait_idle(w, 2e6)) return -11;
    t = now_us(); for (int i = 0; i < 8; i++) spw(w, 2, 1048 + i, mu[i]); st->preload_us = now_us() - t;
    t = now_us(); w->sign[REG] = 1;                    /* LAUNCH: TRNG draw + rho'' prologue + attempts, all in PL */
    while (!(w->sign[REG + 1] & 0x2)) {
        if (w->poll_us) { struct timespec ts = {0, (long)w->poll_us * 1000}; nanosleep(&ts, NULL); }
        if (now_us() - t > 5e6) return -12;
    }
    st->wait_us = now_us() - t;
    uint32_t s = w->sign[REG + 1], k = w->sign[REG + 2];
    st->errors = w->sign[REG + 3]; st->cycles = w->sign[REG + 4]; st->kappa = k & 0xffff; st->attempts = k >> 16;
    st->seal = w->sign[REG + 0x1C/4]; st->trng_reg = w->sign[REG + 0x20/4];
    st->trng_max_run = (st->trng_reg >> 11) & 0x3f; st->trng_apt_worst = st->trng_reg & 0x7ff;
    st->trng_redraws = (st->trng_reg >> 17) & 0xf; st->trng_rc = -(int)((st->trng_reg >> 21) & 0xf);
    w->sign[REG] = 2;
    if (!(s & 0x4) || !(s & (1u << 13))) return -13;
    t = now_us(); uint8_t ct[32]; static uint32_t zc[1024], hc[1024];
    for (int i = 0; i < 4; i++) { uint64_t v = spr(w, 1, 1150 + i); for (int j = 0; j < 8; j++) ct[8*i+j] = (uint8_t)(v >> (8*j)); }
    for (int i = 0; i < 512; i++) {
        uint64_t v = spr(w, 3, 1400 + i); zc[2*i] = (uint32_t)v; zc[2*i+1] = (uint32_t)(v >> 32);
        v = spr(w, 1, i); hc[2*i] = (uint32_t)v; hc[2*i+1] = (uint32_t)(v >> 32);
    }
    int r = wcore_pack_sig(sig, ct, zc, hc); st->pack_rc = r;
    st->readback_us = now_us() - t; st->total_us = now_us() - t0;
    if (r) memset(sig, 0, WCORE_SIG_BYTES);
    return r == -2 ? -15 : (r ? -14 : 0);
}
int wcore_attach_sealed_tr(wcore_t *w, const uint8_t tr[64]) {
    if (!wcore_is_v8(w)) return -40;
    if (!(w->sign[REG + 1] & (1u << 10))) return -45;
    memcpy(w->tr, tr, 64); w->provisioned = 1; return 0;
}
int wcore_keygen(wcore_t *w, uint8_t pk[WCORE_PK_BYTES], wcore_stats_t *st) {
    double t0 = now_us(), t; memset(st, 0, sizeof *st); memset(pk, 0, WCORE_PK_BYTES);
    if (!w->sign || w->sign[REG + 0x18/4] != WCORE_VERSION_V8P3) return -48;
    if (wait_idle(w, 2e6)) return -43;
    if (w->sign[REG + 1] & (1u << 10)) return -41;
    t = now_us(); w->sign[REG] = 0x20;                  /* KEYGEN: TRNG xi + FIPS 204 Alg. 6 in the PL, LOCK */
    while (!(w->sign[REG + 1] & 0x2)) {
        if (w->poll_us) { struct timespec ts = {0, (long)w->poll_us * 1000}; nanosleep(&ts, NULL); }
        if (now_us() - t > 5e6) return -12;
    }
    st->wait_us = now_us() - t;
    uint32_t s = w->sign[REG + 1]; st->errors = w->sign[REG + 3]; st->cycles = w->sign[REG + 4];
    st->seal = w->sign[REG + 0x1C/4]; st->trng_reg = w->sign[REG + 0x20/4];
    w->sign[REG] = 2;
    if (!(s & 0x4) || !(s & (1u << 15))) return -13;
    for (int i = 0; i < 4; i++) { uint64_t v = spr(w, 2, 1028 + i); for (int j = 0; j < 8; j++) pk[8*i+j] = (uint8_t)(v >> (8*j)); }
    memset(pk + 32, 0, WCORE_PK_BYTES - 32);
    for (int i = 0; i < 512; i++) {                     /* t1: 2 x 10-bit coefficients per 64-bit word */
        uint64_t v = spr(w, 3, 1536 + i);
        for (int k = 0; k < 2; k++) { uint32_t c = (uint32_t)(v >> (32*k)) & 1023; size_t bit = 10*(size_t)(2*i+k);
            for (int b = 0; b < 10; b++) if ((c >> b) & 1) pk[32 + ((bit+b)>>3)] |= (uint8_t)(1u << ((bit+b)&7)); }
    }
    wcore_shake256(w->tr, 64, pk, WCORE_PK_BYTES); w->provisioned = 1; memset(w->sk_hash, 0, 32);
    st->total_us = now_us() - t0;
    return 0;
}
