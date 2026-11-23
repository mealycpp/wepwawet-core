/* adcs_load -- real closed-loop spacecraft attitude determination & control workload (C99).
 *
 * Per control cycle (default 100 Hz):
 *   1) truth model: rigid body + 3 reaction wheels, RK4 (K substeps), circular LEO orbit,
 *      tilted-dipole geomagnetic field, inertial Sun vector with cylindrical eclipse;
 *   2) sensors: gyro (ARW + bias random walk, Farrenkopf model), coarse sun sensor, magnetometer;
 *   3) 6-state Multiplicative EKF (attitude error + gyro bias): Lefferts, Markley & Shuster 1982;
 *      Markley & Crassidis, "Fundamentals of Spacecraft Attitude Determination and Control", 2014, ch. 6;
 *   4) quaternion-feedback PD attitude control (Wie, "Space Vehicle Dynamics and Control", 2008; Wie,
 *      Weiss & Arapostathis 1989) commanding wheel torques with saturation.
 * Scheduling: absolute-time periodic release (clock_nanosleep TIMER_ABSTIME), optional SCHED_FIFO and
 * CPU pinning. Measures per-cycle execution time, release jitter and deadline misses.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <signal.h>
#include <sched.h>
#include <sys/mman.h>

typedef double v3[3];
static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

/* ---------------- small linear algebra ---------------- */
static void cross(const double *a, const double *b, double *c) {
    double t0 = a[1]*b[2]-a[2]*b[1], t1 = a[2]*b[0]-a[0]*b[2], t2 = a[0]*b[1]-a[1]*b[0];
    c[0]=t0; c[1]=t1; c[2]=t2;
}
static double dot(const double *a, const double *b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
static double norm3(const double *a) { return sqrt(dot(a,a)); }
static void unit3(double *a) { double n = norm3(a); if (n > 0) { a[0]/=n; a[1]/=n; a[2]/=n; } }
static void qnorm(double *q) { double n = sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3]); for (int i=0;i<4;i++) q[i]/=n; }
/* scalar-last quaternion, A(q) maps inertial -> body (Markley & Crassidis convention) */
static void attmat(const double *q, double A[3][3]) {
    double e0=q[0],e1=q[1],e2=q[2],s=q[3];
    A[0][0]=s*s+e0*e0-e1*e1-e2*e2; A[0][1]=2*(e0*e1+s*e2);      A[0][2]=2*(e0*e2-s*e1);
    A[1][0]=2*(e0*e1-s*e2);        A[1][1]=s*s-e0*e0+e1*e1-e2*e2; A[1][2]=2*(e1*e2+s*e0);
    A[2][0]=2*(e0*e2+s*e1);        A[2][1]=2*(e1*e2-s*e0);      A[2][2]=s*s-e0*e0-e1*e1+e2*e2;
}
static void mv3(double A[3][3], const double *x, double *y) { for (int i=0;i<3;i++) y[i]=A[i][0]*x[0]+A[i][1]*x[1]+A[i][2]*x[2]; }
/* q (x) p with A(q(x)p) = A(q)A(p) */
static void qmul(const double *q, const double *p, double *r) {
    double t[4];
    t[0] =  q[3]*p[0] + q[2]*p[1] - q[1]*p[2] + q[0]*p[3];
    t[1] = -q[2]*p[0] + q[3]*p[1] + q[0]*p[2] + q[1]*p[3];
    t[2] =  q[1]*p[0] - q[0]*p[1] + q[3]*p[2] + q[2]*p[3];
    t[3] = -q[0]*p[0] - q[1]*p[1] - q[2]*p[2] + q[3]*p[3];
    memcpy(r, t, sizeof t);
}
static double qangle_deg(const double *q, const double *p) {  /* angle of q (x) p^-1 */
    double pi[4] = {-p[0],-p[1],-p[2],p[3]}, d[4]; qmul(q, pi, d);
    double w = fabs(d[3]); if (w > 1) w = 1; return 2*acos(w)*180/M_PI;
}
/* exact quaternion propagation for constant rate over dt: q+ = [cos(|w|dt/2) I + sin(|w|dt/2)/|w| Omega(w)] q */
static void qprop(double *q, const double *w, double dt) {
    double wn = norm3(w), c, s;
    if (wn < 1e-12) { c = 1; s = 0.5*dt; } else { c = cos(0.5*wn*dt); s = sin(0.5*wn*dt)/wn; }
    double t[4];
    t[0] = c*q[0] + s*( w[2]*q[1] - w[1]*q[2] + w[0]*q[3]);
    t[1] = c*q[1] + s*(-w[2]*q[0] + w[0]*q[2] + w[1]*q[3]);
    t[2] = c*q[2] + s*( w[1]*q[0] - w[0]*q[1] + w[2]*q[3]);
    t[3] = c*q[3] + s*(-w[0]*q[0] - w[1]*q[1] - w[2]*q[2]);
    memcpy(q, t, sizeof t); qnorm(q);
}

/* ---------------- RNG (xorshift128+, Box-Muller) ---------------- */
static unsigned long long rs0 = 0x9E3779B97F4A7C15ULL, rs1 = 0xD1B54A32D192ED03ULL;
static double urand(void) { unsigned long long x = rs0, y = rs1; rs0 = y; x ^= x << 23; rs1 = x ^ y ^ (x >> 17) ^ (y >> 26);
                            return ((rs1 + y) >> 11) * (1.0/9007199254740992.0); }
static double grand(void) { double u1 = urand(), u2 = urand(); if (u1 < 1e-300) u1 = 1e-300; return sqrt(-2*log(u1))*cos(2*M_PI*u2); }

/* ---------------- spacecraft / environment parameters (documented in README) ---------------- */
static const double J[3] = {0.0300, 0.0350, 0.0100};   /* 3U CubeSat principal inertia, kg m^2 */
static const double UMAX = 2.0e-3;                     /* wheel torque limit, N m */
static const double HMAX = 30e-3;                      /* wheel momentum limit, N m s */
static const double TDIST[3] = {1e-7, -2e-7, 1.5e-7};  /* residual disturbance torque, N m */
static const double RE = 6378137.0, MU = 3.986004418e14, ALT = 500e3, INC = 97.4*M_PI/180;
static const double SIG_V = 4.4e-5;                    /* gyro ARW 0.15 deg/sqrt(h) -> rad/sqrt(s) */
static const double SIG_U = 1.0e-6;                    /* gyro rate random walk, rad/s^1.5 */
static const double SIG_SUN = 0.5*M_PI/180;            /* coarse sun sensor 1-sigma, rad */
static const double SIG_MAG = 0.6*M_PI/180;            /* magnetometer direction 1-sigma, rad */

typedef struct { double q[4], w[3], h[3]; } truth_t;
static void deriv(const truth_t *x, const double *u, truth_t *dx) {
    double Jw[3] = {J[0]*x->w[0], J[1]*x->w[1], J[2]*x->w[2]}, Hb[3], g[3];
    for (int i=0;i<3;i++) Hb[i] = Jw[i] + x->h[i];
    cross(x->w, Hb, g);
    for (int i=0;i<3;i++) { dx->w[i] = (-g[i] - u[i] + TDIST[i]) / J[i]; dx->h[i] = u[i]; }
    const double *q = x->q, *w = x->w;
    dx->q[0] = 0.5*( w[2]*q[1] - w[1]*q[2] + w[0]*q[3]);
    dx->q[1] = 0.5*(-w[2]*q[0] + w[0]*q[2] + w[1]*q[3]);
    dx->q[2] = 0.5*( w[1]*q[0] - w[0]*q[1] + w[2]*q[3]);
    dx->q[3] = 0.5*(-w[0]*q[0] - w[1]*q[1] - w[2]*q[2]);
}
static void axpy(truth_t *y, const truth_t *x, double a, const truth_t *d) {
    for (int i=0;i<4;i++) y->q[i] = x->q[i] + a*d->q[i];
    for (int i=0;i<3;i++) { y->w[i] = x->w[i] + a*d->w[i]; y->h[i] = x->h[i] + a*d->h[i]; }
}
static void rk4(truth_t *x, const double *u, double dt) {
    truth_t k1, k2, k3, k4, t;
    deriv(x, u, &k1); axpy(&t, x, 0.5*dt, &k1); deriv(&t, u, &k2); axpy(&t, x, 0.5*dt, &k2); deriv(&t, u, &k3);
    axpy(&t, x, dt, &k3); deriv(&t, u, &k4);
    for (int i=0;i<4;i++) x->q[i] += dt/6*(k1.q[i]+2*k2.q[i]+2*k3.q[i]+k4.q[i]);
    for (int i=0;i<3;i++) { x->w[i] += dt/6*(k1.w[i]+2*k2.w[i]+2*k3.w[i]+k4.w[i]);
                            x->h[i] += dt/6*(k1.h[i]+2*k2.h[i]+2*k3.h[i]+k4.h[i]); }
    qnorm(x->q);
}
static void orbit_env(double t, double *rhat, double *bref, double *sref, int *sunlit) {
    double R = RE + ALT, n = sqrt(MU/(R*R*R)), a = n*t;
    double r[3] = {R*cos(a), R*sin(a)*cos(INC), R*sin(a)*sin(INC)};
    memcpy(rhat, r, sizeof r); unit3(rhat);
    const double tilt = 11.0*M_PI/180;                        /* geomagnetic dipole tilt */
    double m[3] = {sin(tilt)*cos(1.2), sin(tilt)*sin(1.2), -cos(tilt)}; /* dipole axis (south-pointing moment) */
    double md = dot(m, rhat);
    for (int i=0;i<3;i++) bref[i] = 3*md*rhat[i] - m[i];     /* direction of B, |B| ~ 1/r^3 irrelevant for unit vector */
    unit3(bref);
    double s[3] = {1.0, 0.30, 0.15}; unit3(s); memcpy(sref, s, sizeof s);
    double along = dot(r, s), perp[3] = {r[0]-along*s[0], r[1]-along*s[1], r[2]-along*s[2]};
    *sunlit = !(along < 0 && norm3(perp) < RE);              /* cylindrical Earth shadow */
}
static void noisy_unit(const double *v, double sig, double *out) {
    for (int i=0;i<3;i++) out[i] = v[i] + sig*grand();
    unit3(out);
}

/* ---------------- MEKF ---------------- */
typedef struct { double q[4], b[3], P[6][6]; } mekf_t;
static void mat6mul(double A[6][6], double B[6][6], double C[6][6]) {
    double T[6][6]; for (int i=0;i<6;i++) for (int j=0;j<6;j++) { double s=0; for (int k=0;k<6;k++) s+=A[i][k]*B[k][j]; T[i][j]=s; }
    memcpy(C, T, sizeof T);
}
static void mekf_propagate(mekf_t *f, const double *wm, double dt, double *what) {
    for (int i=0;i<3;i++) what[i] = wm[i] - f->b[i];
    qprop(f->q, what, dt);
    /* Phi = I + F dt + 0.5 F^2 dt^2,  F = [[-[w x], -I],[0, 0]] */
    double F[6][6] = {{0}}, F2[6][6], Phi[6][6], PhiT[6][6], T[6][6];
    F[0][1] =  what[2]; F[0][2] = -what[1]; F[1][0] = -what[2]; F[1][2] =  what[0]; F[2][0] =  what[1]; F[2][1] = -what[0];
    for (int i=0;i<3;i++) F[i][3+i] = -1;
    mat6mul(F, F, F2);
    for (int i=0;i<6;i++) for (int j=0;j<6;j++) Phi[i][j] = (i==j) + F[i][j]*dt + 0.5*F2[i][j]*dt*dt;
    for (int i=0;i<6;i++) for (int j=0;j<6;j++) PhiT[i][j] = Phi[j][i];
    mat6mul(Phi, f->P, T); mat6mul(T, PhiT, f->P);
    /* discrete process noise (Farrenkopf): Markley & Crassidis 2014, eq. 6.93 */
    double q11 = SIG_V*SIG_V*dt + SIG_U*SIG_U*dt*dt*dt/3, q12 = -SIG_U*SIG_U*dt*dt/2, q22 = SIG_U*SIG_U*dt;
    for (int i=0;i<3;i++) { f->P[i][i] += q11; f->P[i][3+i] += q12; f->P[3+i][i] += q12; f->P[3+i][3+i] += q22; }
}
static int inv3(double M[3][3], double R[3][3]) {
    double d = M[0][0]*(M[1][1]*M[2][2]-M[1][2]*M[2][1]) - M[0][1]*(M[1][0]*M[2][2]-M[1][2]*M[2][0]) + M[0][2]*(M[1][0]*M[2][1]-M[1][1]*M[2][0]);
    if (fabs(d) < 1e-300) return -1;
    R[0][0]=(M[1][1]*M[2][2]-M[1][2]*M[2][1])/d; R[0][1]=(M[0][2]*M[2][1]-M[0][1]*M[2][2])/d; R[0][2]=(M[0][1]*M[1][2]-M[0][2]*M[1][1])/d;
    R[1][0]=(M[1][2]*M[2][0]-M[1][0]*M[2][2])/d; R[1][1]=(M[0][0]*M[2][2]-M[0][2]*M[2][0])/d; R[1][2]=(M[0][2]*M[1][0]-M[0][0]*M[1][2])/d;
    R[2][0]=(M[1][0]*M[2][1]-M[1][1]*M[2][0])/d; R[2][1]=(M[0][1]*M[2][0]-M[0][0]*M[2][1])/d; R[2][2]=(M[0][0]*M[1][1]-M[0][1]*M[1][0])/d;
    return 0;
}
/* sequential vector-measurement update, Joseph form */
static void mekf_update(mekf_t *f, const double *bmeas, const double *ref, double sig) {
    double A[3][3], bp[3]; attmat(f->q, A); mv3(A, ref, bp);
    double H[3][6] = {{0}};                        /* H = [ [A r x], 0 ] */
    H[0][1] = -bp[2]; H[0][2] =  bp[1]; H[1][0] =  bp[2]; H[1][2] = -bp[0]; H[2][0] = -bp[1]; H[2][1] =  bp[0];
    double PHt[6][3], S[3][3], Si[3][3], K[6][3], r2 = sig*sig;
    for (int i=0;i<6;i++) for (int j=0;j<3;j++) { double s=0; for (int k=0;k<6;k++) s += f->P[i][k]*H[j][k]; PHt[i][j]=s; }
    for (int i=0;i<3;i++) for (int j=0;j<3;j++) { double s=0; for (int k=0;k<6;k++) s += H[i][k]*PHt[k][j]; S[i][j] = s + (i==j)*r2; }
    if (inv3(S, Si)) return;
    for (int i=0;i<6;i++) for (int j=0;j<3;j++) { double s=0; for (int k=0;k<3;k++) s += PHt[i][k]*Si[k][j]; K[i][j]=s; }
    double y[3] = {bmeas[0]-bp[0], bmeas[1]-bp[1], bmeas[2]-bp[2]}, dx[6];
    for (int i=0;i<6;i++) dx[i] = K[i][0]*y[0] + K[i][1]*y[1] + K[i][2]*y[2];
    double IKH[6][6], T[6][6], T2[6][6], IKHt[6][6];
    for (int i=0;i<6;i++) for (int j=0;j<6;j++) { double s=0; for (int k=0;k<3;k++) s += K[i][k]*H[k][j]; IKH[i][j] = (i==j) - s; }
    for (int i=0;i<6;i++) for (int j=0;j<6;j++) IKHt[i][j] = IKH[j][i];
    mat6mul(IKH, f->P, T); mat6mul(T, IKHt, T2);
    for (int i=0;i<6;i++) for (int j=0;j<6;j++) { double s=0; for (int k=0;k<3;k++) s += K[i][k]*K[j][k]*r2; f->P[i][j] = T2[i][j] + s; }
    /* multiplicative reset: q+ = q- + 0.5 Xi(q-) dtheta, renormalised */
    const double *q = f->q; double d0 = dx[0], d1 = dx[1], d2 = dx[2], t[4];
    t[0] = q[0] + 0.5*( q[3]*d0 - q[2]*d1 + q[1]*d2);
    t[1] = q[1] + 0.5*( q[2]*d0 + q[3]*d1 - q[0]*d2);
    t[2] = q[2] + 0.5*(-q[1]*d0 + q[0]*d1 + q[3]*d2);
    t[3] = q[3] + 0.5*(-q[0]*d0 - q[1]*d1 - q[2]*d2);
    memcpy(f->q, t, sizeof t); qnorm(f->q);
    for (int i=0;i<3;i++) f->b[i] += dx[3+i];
}

/* ---------------- timing ---------------- */
static double ts2us(const struct timespec *t) { return t->tv_sec*1e6 + t->tv_nsec/1e3; }
static void ts_add_ns(struct timespec *t, long ns) { t->tv_nsec += ns; while (t->tv_nsec >= 1000000000L) { t->tv_nsec -= 1000000000L; t->tv_sec++; } }
static int cmpd(const void *a, const void *b) { double x = *(const double*)a, y = *(const double*)b; return (x > y) - (x < y); }
static double pct(double *v, long n, double p) { if (n <= 0) return 0; long i = (long)(p*(n-1)); return v[i]; }

int main(int argc, char **argv) {
    double rate = 100, seconds = 30; int cpu = -1, prio = 0, substeps = 10; const char *csv = NULL; unsigned long long seed = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--rate") && i+1 < argc) rate = atof(argv[++i]);
        else if (!strcmp(argv[i], "--seconds") && i+1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--cpu") && i+1 < argc) cpu = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--prio") && i+1 < argc) prio = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--substeps") && i+1 < argc) substeps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--csv") && i+1 < argc) csv = argv[++i];
        else if (!strcmp(argv[i], "--seed") && i+1 < argc) seed = strtoull(argv[++i], NULL, 10);
        else { fprintf(stderr, "usage: %s [--rate Hz] [--seconds s] [--cpu N] [--prio P] [--substeps K] [--csv file] [--seed n]\n", argv[0]); return 2; }
    }
    if (rate <= 0 || seconds <= 0 || substeps < 1) { fprintf(stderr, "bad arguments\n"); return 2; }
    rs0 ^= seed * 0x9E3779B97F4A7C15ULL; rs1 ^= seed * 0xBF58476D1CE4E5B9ULL; for (int i = 0; i < 20; i++) urand();
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    if (cpu >= 0) { cpu_set_t s; CPU_ZERO(&s); CPU_SET(cpu, &s); if (sched_setaffinity(0, sizeof s, &s)) perror("sched_setaffinity"); }
    if (prio > 0) { struct sched_param sp = { .sched_priority = prio }; if (sched_setscheduler(0, SCHED_FIFO, &sp)) perror("SCHED_FIFO (needs root)"); }
    mlockall(MCL_CURRENT | MCL_FUTURE);

    const double dt = 1.0 / rate; const long period_ns = (long)(1e9 / rate);
    long ncap = (long)(seconds * rate) + 16;
    double *exec = malloc(sizeof(double) * ncap), *jit = malloc(sizeof(double) * ncap);
    if (!exec || !jit) { fprintf(stderr, "oom\n"); return 2; }
    FILE *fc = csv ? fopen(csv, "w") : NULL;
    /* Measurement must not perturb the loop: keep the whole CSV in a RAM buffer (locked by mlockall) and
     * write it only at exit, so no write()/SD-card writeback can block the real-time thread mid-run. */
    /* glibc ignores the size when the buffer pointer is NULL and keeps a 4 KiB buffer, which made this real-time
     * thread call write() about once a second; the buffer must be supplied explicitly. */
    if (fc) { size_t bs = (size_t)ncap * 96 + 4096; char *fb = malloc(bs); if (fb) { memset(fb, 0, bs); setvbuf(fc, fb, _IOFBF, bs); } }
    if (fc) fprintf(fc, "cycle,t_s,exec_us,jitter_us,miss,point_err_deg,est_err_deg,bias_err_degph,sunlit\n");

    /* initial conditions: 30 deg off target, small tumble; estimator 5 deg off, bias unknown */
    truth_t x; memset(&x, 0, sizeof x); double ax[3] = {0.48, -0.60, 0.64}; unit3(ax); double th = 30*M_PI/180;
    for (int i=0;i<3;i++) x.q[i] = ax[i]*sin(th/2);
    x.q[3] = cos(th/2);
    x.w[0] = 0.010; x.w[1] = -0.008; x.w[2] = 0.006;
    double bias[3] = {0.10*M_PI/180, -0.07*M_PI/180, 0.05*M_PI/180};           /* true gyro bias, rad/s */
    mekf_t f; memset(&f, 0, sizeof f);
    { double eax[3] = {0.2, 0.9, -0.4}; unit3(eax); double e = 5*M_PI/180, dq[4] = {eax[0]*sin(e/2), eax[1]*sin(e/2), eax[2]*sin(e/2), cos(e/2)};
      qmul(dq, x.q, f.q); qnorm(f.q); }
    for (int i=0;i<3;i++) { f.P[i][i] = pow(10*M_PI/180, 2); f.P[3+i][3+i] = pow(0.2*M_PI/180, 2); }
    const double qc[4] = {0, 0, 0, 1};                                          /* commanded attitude (inertial hold) */
    const double wn = 0.3, zeta = 0.9;                                          /* closed-loop bandwidth, damping */
    double u[3] = {0}, what[3] = {0}, t = 0;
    long cycles = 0, misses = 0, skipped = 0, nsamp = 0;

    struct timespec rel, now, end;
    clock_gettime(CLOCK_MONOTONIC, &rel); ts_add_ns(&rel, 10 * period_ns);
    const long total = (long)(seconds * rate);
    while (!g_stop && cycles < total) {
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &rel, NULL);
        clock_gettime(CLOCK_MONOTONIC, &now);
        double jitter = ts2us(&now) - ts2us(&rel);
        /* ---- 1) truth propagation over one control period (K RK4 substeps) ---- */
        for (int k = 0; k < substeps; k++) {
            rk4(&x, u, dt / substeps);
            for (int i=0;i<3;i++) bias[i] += SIG_U * sqrt(dt / substeps) * grand();
        }
        t += dt;
        /* ---- 2) sensors ---- */
        double rhat[3], bref[3], sref[3], A[3][3], btrue[3], strue[3], bm[3], sm[3], wm[3]; int sunlit;
        orbit_env(t, rhat, bref, sref, &sunlit);
        attmat(x.q, A); mv3(A, bref, btrue); mv3(A, sref, strue);
        noisy_unit(btrue, SIG_MAG, bm); noisy_unit(strue, SIG_SUN, sm);
        for (int i=0;i<3;i++) wm[i] = x.w[i] + bias[i] + SIG_V / sqrt(dt) * grand();
        /* ---- 3) MEKF ---- */
        mekf_propagate(&f, wm, dt, what);
        mekf_update(&f, bm, bref, SIG_MAG);
        if (sunlit) mekf_update(&f, sm, sref, SIG_SUN);
        /* ---- 4) quaternion-feedback PD control on the estimate, wheel torque + momentum limits ---- */
        double qci[4] = {-qc[0], -qc[1], -qc[2], qc[3]}, qe[4]; qmul(f.q, qci, qe);
        double sgn = qe[3] < 0 ? -1 : 1;
        for (int i=0;i<3;i++) {
            double tau = -(2*wn*wn*J[i]) * sgn * qe[i] - (2*zeta*wn*J[i]) * what[i];   /* body control torque (Wie) */
            double ui = -tau;                              /* wheel motor torque; body receives -u */
            if (ui > UMAX) ui = UMAX;
            if (ui < -UMAX) ui = -UMAX;
            if ((x.h[i] >= HMAX && ui > 0) || (x.h[i] <= -HMAX && ui < 0)) ui = 0;
            u[i] = ui;
        }
        clock_gettime(CLOCK_MONOTONIC, &end);
        double ex = ts2us(&end) - ts2us(&now);
        ts_add_ns(&rel, period_ns);
        int miss = 0;
        if (ts2us(&end) > ts2us(&rel)) {               /* finished after the next release: deadline miss */
            miss = 1; misses++;
            while (ts2us(&end) > ts2us(&rel)) { ts_add_ns(&rel, period_ns); skipped++; }  /* re-align, count skipped releases */
        }
        exec[nsamp] = ex; jit[nsamp] = jitter; nsamp++; cycles++;
        if (fc) {
            double be = 0; for (int i=0;i<3;i++) be += pow(f.b[i] - bias[i], 2);
            fprintf(fc, "%ld,%.3f,%.2f,%.2f,%d,%.4f,%.4f,%.3f,%d\n", cycles, t, ex, jitter, miss,
                    qangle_deg(x.q, qc), qangle_deg(f.q, x.q), sqrt(be)*180/M_PI*3600, sunlit);
        }
    }
    if (fc) fclose(fc);
    double be = 0; for (int i=0;i<3;i++) be += pow(f.b[i] - bias[i], 2);
    double pe = qangle_deg(x.q, qc), ee = qangle_deg(f.q, x.q), wnorm = norm3(x.w)*180/M_PI;
    qsort(exec, nsamp, sizeof(double), cmpd); qsort(jit, nsamp, sizeof(double), cmpd);
    printf("{\"tool\":\"adcs_load\",\"rate_hz\":%.1f,\"substeps\":%d,\"cpu\":%d,\"prio\":%d,\"cycles\":%ld,\"deadline_misses\":%ld,"
           "\"skipped_releases\":%ld,\"miss_rate\":%.6f,\"exec_us\":{\"p50\":%.1f,\"p99\":%.1f,\"max\":%.1f},"
           "\"release_jitter_us\":{\"p50\":%.1f,\"p99\":%.1f,\"max\":%.1f},\"final_pointing_error_deg\":%.4f,"
           "\"attitude_estimation_error_deg\":%.4f,\"gyro_bias_estimation_error_deg_per_h\":%.3f,\"body_rate_deg_s\":%.5f}\n",
           rate, substeps, cpu, prio, cycles, misses, skipped, cycles ? (double)misses / cycles : 0,
           pct(exec, nsamp, .5), pct(exec, nsamp, .99), nsamp ? exec[nsamp-1] : 0,
           pct(jit, nsamp, .5), pct(jit, nsamp, .99), nsamp ? jit[nsamp-1] : 0, pe, ee, sqrt(be)*180/M_PI*3600, wnorm);
    free(exec); free(jit);
    return 0;
}
