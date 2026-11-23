/* WEPWAWET-CORE FPGA driver (C99, no Python, no PYNQ). v5/v6/v7 image: SIGN @0xA000_0000, TRNG @0xA002_0000.
 * seal_v8 (VERSION 0x0003_0002): the signing key is provisioned once into the PL, LOCKed (sealed: never readable
 * or writable from the PS again until ZEROIZE or PL reset), rnd comes from the PL TRNG path and rho'' is computed
 * in the PL. Per signature the PS writes only mu (b2[1048..1055]) and reads back c~, z, h.
 * PS work: skDecode, NTT(s1,s2,t0) (cached per key), mu, rho'', TRNG conditioning, preload, sigEncode.
 * PL work: ExpandA and every Sign attempt incl. reject->retry (or the Verify program on v6). */
#ifndef WCORE_FPGA_H
#define WCORE_FPGA_H
#include <stdint.h>
#include <stddef.h>
#define WCORE_PK_BYTES 1312
#define WCORE_SK_BYTES 2560
#define WCORE_SIG_BYTES 2420
typedef struct {
    uint64_t rho[4], mu[8], rhop[8];
    uint64_t s1[512], s2[512], t0[512];   /* NTT domain, 2 x 32-bit coeffs per word, canonical mod q */
} wcore_prep_t;
typedef struct {                          /* VERIFY preload (v6 image), see verify_v1/RESULT_VERIFY_V1.md */
    uint64_t rho[4], mu[8], ct[4];
    uint64_t z[512];                      /* signed 32-bit pairs (two's complement), b3[0..511]      */
    uint64_t h[512];                      /* 0/1 pairs, b3[512..1023]                                 */
    uint64_t t1h[512];                    /* NTT(t1 * 2^13) canonical mod q, b2[1536..2047]           */
} wcore_vprep_t;
typedef struct {
    uint32_t cycles, kappa, attempts, errors;
    double trng_us, prep_us, preload_us, wait_us, readback_us, total_us;
    uint32_t trng_hw_fail, trng_max_run, trng_apt_worst;
    uint32_t omega_restarts;              /* hedged restarts because the PL accepted ||h||_1 > omega (PL check missing) */
    uint32_t trng_redraws;                /* draws discarded because the Stage-8 32-sample window flag fired */
    int trng_rc;                          /* 0 ok, -1 timeout, -2 hw flag after 3 redraws, -3 RCT, -4 APT */
    int pack_rc;                          /* 0 ok, -1 z out of range, -2 hint weight > omega */
    uint32_t seal, trng_reg;              /* v8: SEAL (0x1_001C) and TRNG (0x1_0020) registers after the job */
} wcore_stats_t;
typedef struct {
    volatile uint32_t *sign, *trng;
    int fd;
    uint8_t cached_sk[WCORE_SK_BYTES]; int cache_valid;   /* zeroized by wcore_close */
    wcore_prep_t prep;                    /* key-dependent part cached across signatures */
    unsigned poll_us;                     /* sleep between STATUS polls while the PL signs */
    uint32_t version;                     /* VERSION register at open */
    int provisioned;                      /* v8: a key is sealed in the PL (this process provisioned it) */
    uint8_t tr[64];                       /* v8: tr = H(pk) of the sealed key (public) */
    uint8_t sk_hash[32];                  /* v8: SHAKE256(sk) of the key this process provisioned (change detection only) */
} wcore_t;

/* pure host-side helpers (testable without hardware) */
void wcore_shake256(uint8_t *out, size_t outlen, const uint8_t *in, size_t inlen);
void wcore_prepare_key(wcore_prep_t *p, const uint8_t sk[WCORE_SK_BYTES]);
void wcore_prepare_msg(wcore_prep_t *p, const uint8_t sk[WCORE_SK_BYTES], const uint8_t *msg, size_t mlen,
                       const uint8_t rnd[32]);
int  wcore_pack_sig(uint8_t sig[WCORE_SIG_BYTES], const uint8_t ctilde[32], const uint32_t zc[1024], const uint32_t hc[1024]);
/* VERIFY host side. Returns 0 = launch the PL, 1 = PS reject (bad lengths / malformed hint / weight > omega),
 * 2 = PS reject (||z||inf >= gamma1 - beta; the PL also checks this). Pure, no hardware. */
int  wcore_verify_prepare(wcore_vprep_t *v, const uint8_t pk[WCORE_PK_BYTES], const uint8_t *msg, size_t mlen,
                          const uint8_t sig[WCORE_SIG_BYTES]);
/* hardware */
int  wcore_open(wcore_t *w, unsigned poll_us);          /* 0 ok; checks MAGIC */
void wcore_close(wcore_t *w);
int  wcore_trng_rnd(wcore_t *w, uint8_t rnd[32], wcore_stats_t *st);
int  wcore_sign(wcore_t *w, uint8_t sig[WCORE_SIG_BYTES], const uint8_t sk[WCORE_SK_BYTES],
                const uint8_t *msg, size_t mlen, int hedged, wcore_stats_t *st);   /* 0 ok */
int  wcore_has_verify(wcore_t *w);                      /* VERSION @0x1_0018 == 0x00020001 (v6 Sign+Verify image) */
/* FPGA ML-DSA-44 Verify (pure, empty ctx). *valid = 1 accept / 0 reject. Returns 0, or <0 on driver/hardware fault. */
int  wcore_verify(wcore_t *w, int *valid, const uint8_t pk[WCORE_PK_BYTES], const uint8_t *msg, size_t mlen,
                  const uint8_t sig[WCORE_SIG_BYTES], wcore_stats_t *st);
/* ---------------- seal_v8 (VERSION 0x0003_0002) ---------------- */
#define WCORE_VERSION_V7   0x00020001u
#define WCORE_VERSION_V8P1 0x00030001u
#define WCORE_VERSION_V8P2 0x00030002u
#define WCORE_VERSION_V8P3 0x00030003u   /* phase 2 ABI + PL KeyGen (CTRL bit5) */
int  wcore_is_v8(wcore_t *w);                            /* VERSION 0x0003_0002 or 0x0003_0003 */
/* Phase 3 image only: generate the node key IN THE PL (xi from the PL TRNG), seal it, return the public key
 * pk = rho || SimpleBitPack(t1,10) (1312 B); tr = H(pk) is kept for signing. 0 ok, -48 not a phase-3 image,
 * -41 already LOCKED (ZEROIZE first), -13 PL KeyGen failed (st->errors: 0x08 TRNG, 0x09 program). */
int  wcore_keygen(wcore_t *w, uint8_t pk[WCORE_PK_BYTES], wcore_stats_t *st);
/* Provision sk into the PL and LOCK: writes NTT(s1), NTT(s2), NTT(t0), K, rho; then sets SEAL_LOCK and checks that the
 * key region reads back as 0. The PS-side copies of the key-derived data are wiped before returning; the caller must
 * wipe sk itself. Returns 0, -40 not v8, -41 already locked (ZEROIZE first), -42 lock/readback check failed. */
int  wcore_provision(wcore_t *w, const uint8_t sk[WCORE_SK_BYTES]);
/* Provision from a key file (read, provision+LOCK, wipe the buffer). The file itself is the operator's to protect/delete. */
int  wcore_provision_file(wcore_t *w, const char *sk_path);
/* Attach to a key already sealed in the PL (e.g. by the wcore_provision tool at boot): needs only the PUBLIC key
 * (tr = H(pk)). Returns 0, -40 not v8, -45 PL not LOCKED (nothing sealed). */
int  wcore_attach_sealed(wcore_t *w, const uint8_t pk[WCORE_PK_BYTES]);
int  wcore_attach_sealed_tr(wcore_t *w, const uint8_t tr[64]);     /* same, given tr = H(pk) directly */
int  wcore_zeroize(wcore_t *w);                          /* ZEROIZE: scrub all scratchpad banks, clear LOCK. 0 ok */
uint32_t wcore_status(wcore_t *w);                      /* STATUS: bit10 locked, bit11 violation, bit12 zeroizing */
uint32_t wcore_seal_reg(wcore_t *w);                    /* SEAL: [0] locked [1] rd viol [2] wr viol [31:16] count */
uint32_t wcore_trng_reg(wcore_t *w);                    /* TRNG: [10:0] APT worst [16:11] RCT run [20:17] redraws [24:21] code [25] DET */
/* Hedged ML-DSA-44 Sign (pure, empty ctx) with the sealed key; tr = H(pk) of the provisioned key (public).
 * 0 ok; -13 PL reported failure (see st->errors: 0x08 TRNG health/timeout, 0x03 retry bound, 0x07 prologue). */
int  wcore_sign_sealed(wcore_t *w, uint8_t sig[WCORE_SIG_BYTES], const uint8_t *msg, size_t mlen, wcore_stats_t *st);
#endif
