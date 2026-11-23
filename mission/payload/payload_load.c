/* payload_load -- Earth-observation payload processor workload for the WEPWAWET mission-load experiment.
 *
 * Real algorithm, real data: each worker thread takes image frames (tiles of a real satellite scene,
 * prepared by tiff2raw.py) at a fixed frame rate and compresses every frame losslessly with
 * CCSDS 121.0-B (Rice / Adaptive Entropy Coding) via the vendored libaec. Optionally every Nth frame is
 * decompressed and compared bit-for-bit. Per frame we log the processing time and whether the frame met
 * its deadline (release + 1/rate, periodic releases; a late frame does not shift later releases).
 *
 * Input file format (written by tiff2raw.py): 32-byte header "WCRAW1\0\0" u32 width u32 height u32 bits
 * u32 nframes u32 flags(bit0 = synthetic) u32 reserved, then nframes * width*height samples
 * (uint8 for bits<=8, uint16 little-endian otherwise).
 *
 * usage: payload_load --input tiles.raw [--cpus 0,1,...] [--rate FPS_PER_THREAD] [--seconds S | --frames N]
 *                     [--verify-every N] [--csv out.csv] [--block 16] [--rsi 128]
 *        payload_load --synthetic ...   (explicit, logged: pseudo-random data, NOT a valid payload measurement)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "libaec.h"

typedef struct { uint32_t w, h, bits, n, flags; size_t frame_bytes; uint8_t *data; } scene_t;
typedef struct { uint32_t thread, cpu, frame, scene_idx; double release_s, start_s, proc_us, lateness_us;
                 size_t out_bytes; int miss, verified, verify_ok; } rec_t;
typedef struct { int id, cpu; double rate; long frames; double seconds; int verify_every;
                 rec_t *recs; long nrec, cap; int err; } worker_t;

static scene_t S; static volatile sig_atomic_t g_stop; static int g_block = 16, g_rsi = 128;
static struct timespec g_t0;

static void on_sig(int s) { (void)s; g_stop = 1; }
static double ts_s(const struct timespec *t) { return t->tv_sec + t->tv_nsec * 1e-9; }
static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return ts_s(&t) - ts_s(&g_t0); }
static void sleep_until(double t_rel) {
    double abs = ts_s(&g_t0) + t_rel; struct timespec t;
    t.tv_sec = (time_t)abs; t.tv_nsec = (long)((abs - (double)t.tv_sec) * 1e9);
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL) == EINTR && !g_stop) {}
}

static int load_scene(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); return -1; }
    char magic[8]; uint32_t hdr[6];
    if (fread(magic, 1, 8, f) != 8 || memcmp(magic, "WCRAW1", 6) || fread(hdr, 4, 6, f) != 6) {
        fprintf(stderr, "%s: not a WCRAW1 file (use tiff2raw.py)\n", path); fclose(f); return -1; }
    S.w = hdr[0]; S.h = hdr[1]; S.bits = hdr[2]; S.n = hdr[3]; S.flags = hdr[4];
    if (!S.w || !S.h || !S.n || S.bits < 1 || S.bits > 16) { fprintf(stderr, "bad header\n"); fclose(f); return -1; }
    S.frame_bytes = (size_t)S.w * S.h * (S.bits > 8 ? 2 : 1);
    S.data = malloc(S.frame_bytes * S.n);
    if (!S.data || fread(S.data, 1, S.frame_bytes * S.n, f) != S.frame_bytes * S.n) {
        fprintf(stderr, "%s: truncated\n", path); fclose(f); return -1; }
    fclose(f); return 0;
}
static void make_synthetic(uint32_t w, uint32_t h, uint32_t bits, uint32_t n) {
    S.w = w; S.h = h; S.bits = bits; S.n = n; S.flags = 1;
    S.frame_bytes = (size_t)w * h * (bits > 8 ? 2 : 1); S.data = malloc(S.frame_bytes * n);
    uint64_t x = 88172645463325252ULL;
    for (size_t i = 0; i < S.frame_bytes * n; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; S.data[i] = (uint8_t)x; }
    if (bits > 8) for (size_t i = 1; i < S.frame_bytes * n; i += 2) S.data[i] &= (uint8_t)((1u << (bits - 8)) - 1);
}

static void aec_setup(struct aec_stream *s) {
    memset(s, 0, sizeof *s);
    s->bits_per_sample = S.bits; s->block_size = g_block; s->rsi = g_rsi;
    s->flags = AEC_DATA_PREPROCESS;                    /* unsigned, little-endian samples, unit-delay predictor */
}

static void *worker(void *arg) {
    worker_t *w = arg;
    if (w->cpu >= 0) { cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(w->cpu, &cs);
        if (pthread_setaffinity_np(pthread_self(), sizeof cs, &cs)) fprintf(stderr, "warn: pin cpu %d failed\n", w->cpu); }
    size_t cap = S.frame_bytes + S.frame_bytes / 2 + 4096;
    uint8_t *out = malloc(cap), *back = malloc(S.frame_bytes);
    double period = 1.0 / w->rate;
    for (long k = 0; !g_stop; k++) {
        double rel = k * period;
        if (w->frames > 0 && k >= w->frames) break;
        if (w->seconds > 0 && rel >= w->seconds) break;
        sleep_until(rel); if (g_stop) break;
        uint32_t si = (uint32_t)((k * 7 + (long)w->id * 3) % S.n);        /* walk the scene's tiles */
        const uint8_t *in = S.data + (size_t)si * S.frame_bytes;
        double t_start = now_s();
        struct aec_stream s; aec_setup(&s);
        s.next_in = in; s.avail_in = S.frame_bytes; s.next_out = out; s.avail_out = cap;
        int r = aec_buffer_encode(&s);
        if (r != AEC_OK) { fprintf(stderr, "encode error %d\n", r); w->err++; continue; }
        size_t ob = s.total_out; int ver = 0, vok = 1;
        if (w->verify_every > 0 && k % w->verify_every == 0) {
            struct aec_stream d; aec_setup(&d);
            d.next_in = out; d.avail_in = ob; d.next_out = back; d.avail_out = S.frame_bytes;
            ver = 1; vok = (aec_buffer_decode(&d) == AEC_OK && d.total_out == S.frame_bytes && !memcmp(back, in, S.frame_bytes));
            if (!vok) w->err++;
        }
        double t_end = now_s();
        if (w->nrec == w->cap) { w->cap = w->cap ? 2 * w->cap : 4096; w->recs = realloc(w->recs, w->cap * sizeof(rec_t)); }
        rec_t *rc = &w->recs[w->nrec++];
        rc->thread = w->id; rc->cpu = w->cpu; rc->frame = (uint32_t)k; rc->scene_idx = si; rc->release_s = rel;
        rc->start_s = t_start; rc->proc_us = (t_end - t_start) * 1e6; rc->lateness_us = (t_end - (rel + period)) * 1e6;
        rc->out_bytes = ob; rc->miss = t_end > rel + period; rc->verified = ver; rc->verify_ok = vok;
    }
    free(out); free(back); return NULL;
}

static int cmpd(const void *a, const void *b) { double x = *(const double*)a, y = *(const double*)b; return (x > y) - (x < y); }

int main(int argc, char **argv) {
    const char *input = NULL, *csv = NULL, *cpus = NULL; double rate = 2.0, seconds = 0; long frames = 0;
    int verify_every = 0, synthetic = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--input") && v) { input = v; i++; }
        else if (!strcmp(a, "--cpus") && v) { cpus = v; i++; }
        else if (!strcmp(a, "--cpu") && v) { cpus = v; i++; }
        else if (!strcmp(a, "--rate") && v) { rate = atof(v); i++; }
        else if (!strcmp(a, "--seconds") && v) { seconds = atof(v); i++; }
        else if (!strcmp(a, "--frames") && v) { frames = atol(v); i++; }
        else if (!strcmp(a, "--verify-every") && v) { verify_every = atoi(v); i++; }
        else if (!strcmp(a, "--csv") && v) { csv = v; i++; }
        else if (!strcmp(a, "--block") && v) { g_block = atoi(v); i++; }
        else if (!strcmp(a, "--rsi") && v) { g_rsi = atoi(v); i++; }
        else if (!strcmp(a, "--synthetic")) synthetic = 1;
        else { fprintf(stderr, "unknown/incomplete option %s (see header of payload_load.c)\n", a); return 2; }
    }
    if (rate <= 0 || (!input && !synthetic)) { fprintf(stderr, "need --input tiles.raw (or explicit --synthetic) and --rate > 0\n"); return 2; }
    if (!frames && seconds <= 0) seconds = 10;
    if (input) { if (load_scene(input)) return 1; } else make_synthetic(1024, 1024, 12, 8);
    if (S.flags & 1) fprintf(stderr, "WARNING: SYNTHETIC pseudo-random data -- not a payload measurement\n");
    int cpu_list[64], nt = 0;
    if (cpus) { char *dup = strdup(cpus), *tok = strtok(dup, ","); while (tok && nt < 64) { cpu_list[nt++] = atoi(tok); tok = strtok(NULL, ","); } free(dup); }
    else cpu_list[nt++] = -1;
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig; sigaction(SIGINT, &sa, NULL); sigaction(SIGTERM, &sa, NULL);
    clock_gettime(CLOCK_MONOTONIC, &g_t0);
    worker_t *W = calloc(nt, sizeof *W); pthread_t *T = calloc(nt, sizeof *T);
    for (int t = 0; t < nt; t++) { W[t].id = t; W[t].cpu = cpu_list[t]; W[t].rate = rate; W[t].frames = frames;
        W[t].seconds = seconds; W[t].verify_every = verify_every; pthread_create(&T[t], NULL, worker, &W[t]); }
    for (int t = 0; t < nt; t++) pthread_join(T[t], NULL);
    double wall = now_s();
    long n = 0, miss = 0, ver = 0, verok = 0, err = 0; double in_b = 0, out_b = 0, busy = 0;
    for (int t = 0; t < nt; t++) { n += W[t].nrec; err += W[t].err; }
    double *pt = malloc(sizeof(double) * (n ? n : 1)); long j = 0;
    FILE *fc = csv ? fopen(csv, "w") : NULL;
    if (fc) setvbuf(fc, NULL, _IOFBF, 8u << 20);   /* RAM-buffered CSV: no disk I/O inside the measured loop */
    if (fc) fprintf(fc, "thread,cpu,frame,tile,release_s,start_s,proc_us,lateness_us,in_bytes,out_bytes,deadline_miss,verified,verify_ok\n");
    for (int t = 0; t < nt; t++) for (long i = 0; i < W[t].nrec; i++) {
        rec_t *r = &W[t].recs[i]; pt[j++] = r->proc_us; miss += r->miss; ver += r->verified; verok += r->verified && r->verify_ok;
        in_b += S.frame_bytes; out_b += r->out_bytes; busy += r->proc_us * 1e-6;
        if (fc) fprintf(fc, "%u,%d,%u,%u,%.6f,%.6f,%.1f,%.1f,%zu,%zu,%d,%d,%d\n", r->thread, (int)r->cpu, r->frame, r->scene_idx,
                        r->release_s, r->start_s, r->proc_us, r->lateness_us, S.frame_bytes, r->out_bytes, r->miss, r->verified, r->verify_ok);
    }
    if (fc) fclose(fc);
    qsort(pt, n, sizeof(double), cmpd);
    printf("{\"tool\":\"payload_load\",\"algorithm\":\"CCSDS 121.0-B (libaec %s) lossless, preprocess, block=%d rsi=%d\","
           "\"data\":\"%s\",\"frame\":\"%ux%u x %u-bit\",\"frame_bytes\":%zu,\"tiles\":%u,\"threads\":%d,\"cpus\":\"%s\","
           "\"rate_fps_per_thread\":%.3f,\"wall_s\":%.3f,\"frames\":%ld,\"deadline_ms\":%.3f,\"deadline_misses\":%ld,"
           "\"miss_rate\":%.5f,\"proc_ms_p50\":%.3f,\"proc_ms_p99\":%.3f,\"proc_ms_max\":%.3f,\"compression_ratio\":%.4f,"
           "\"throughput_MBps_busy\":%.2f,\"cpu_busy_fraction_per_thread\":%.4f,\"verified_frames\":%ld,\"verify_ok\":%ld,\"errors\":%ld}\n",
           AEC_VERSION_STR, g_block, g_rsi, (S.flags & 1) ? "SYNTHETIC" : (input ? input : "?"), S.w, S.h, S.bits, S.frame_bytes, S.n,
           nt, cpus ? cpus : "unpinned", rate, wall, n, 1000.0 / rate, miss, n ? (double)miss / n : 0.0,
           n ? pt[n / 2] / 1e3 : 0.0, n ? pt[(long)(0.99 * (n - 1))] / 1e3 : 0.0, n ? pt[n - 1] / 1e3 : 0.0,
           out_b > 0 ? in_b / out_b : 0.0, busy > 0 ? in_b / busy / 1e6 : 0.0, wall > 0 ? busy / wall / nt : 0.0, ver, verok, err);
    return err ? 1 : 0;
}
