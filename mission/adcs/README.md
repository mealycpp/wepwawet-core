# adcs_load — real closed-loop ADCS workload (mission-load experiment)

Deadline-critical spacecraft task for the "4 busy A53 cores, CPU signer vs fabric signer" experiment.
Not a synthetic spin load: each cycle runs a real attitude determination and control loop.

## What one control cycle does (default 100 Hz)
1. **Truth model**: rigid 3U CubeSat (J = diag(0.030, 0.035, 0.010) kg m²) + 3 reaction wheels
   (±2 mN·m torque, ±30 mN·m·s momentum), Euler's equations with wheel coupling, RK4 with `--substeps K`
   steps per period; circular 500 km, 97.4° LEO; tilted (11°) geomagnetic dipole; inertial Sun with
   cylindrical eclipse; small residual disturbance torque.
2. **Sensors**: gyro with angle random walk 0.15 °/√h (σv = 4.4e-5 rad/√s) and rate random walk
   σu = 1e-6 rad/s^1.5 (Farrenkopf model), true bias (0.10, −0.07, 0.05) °/s; coarse sun sensor 0.5° (1σ);
   magnetometer direction 0.6° (1σ) — typical CubeSat-class MEMS / coarse sensors.
3. **6-state Multiplicative EKF** (attitude error + gyro bias), exact quaternion propagation, Farrenkopf
   discrete process noise, sequential vector-measurement updates (Joseph form), multiplicative reset.
   Refs: E. J. Lefferts, F. L. Markley, M. D. Shuster, "Kalman Filtering for Spacecraft Attitude Estimation",
   JGCD 5(5), 1982; F. L. Markley, J. L. Crassidis, *Fundamentals of Spacecraft Attitude Determination and
   Control*, Springer 2014, ch. 6 (eq. 6.93 for the discrete noise).
4. **Quaternion-feedback PD control** τ = −Kp·sgn(q₄)·q_e − Kd·ω̂ with Kp = 2ωn²J, Kd = 2ζωnJ
   (ωn = 0.3 rad/s, ζ = 0.9) on the *estimated* state, wheel torque/momentum saturation.
   Refs: B. Wie, H. Weiss, A. Arapostathis, "Quaternion Feedback Regulator for Spacecraft Eigenaxis
   Rotations", JGCD 12(3), 1989; B. Wie, *Space Vehicle Dynamics and Control*, 2nd ed., AIAA 2008.

The scenario: 30° initial pointing error with a small tumble, estimator initialised 5° off with unknown bias;
the loop must converge (inertial hold), so a run also proves the algorithm works.

## Timing instrumentation
Absolute-time periodic release (`clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)`), optional CPU pinning and
SCHED_FIFO. Per cycle: execution time, release jitter (wake − scheduled release), **deadline miss** = cycle
finished after the next release (releases are then re-aligned and counted as skipped).

## Build / run (board: AUP-ZU3, Ubuntu 22.04 aarch64, gcc 11)
```bash
bash build_adcs.sh
./adcs_load --rate 100 --seconds 30                         # quick functional check (JSON summary)
sudo ./adcs_load --rate 100 --seconds 300 --cpu 1 --prio 80 --csv adcs_cpu1.csv   # experiment run
```
Options: `--rate Hz` (100), `--seconds s` (30), `--cpu N`, `--prio P` (SCHED_FIFO, needs root),
`--substeps K` (10; scales truth-propagation compute, e.g. higher-fidelity dynamics), `--csv file`
(per-cycle: exec_us, jitter_us, miss, pointing/estimation/bias errors, sunlit), `--seed n`. SIGINT/SIGTERM
stop cleanly and still print the summary.

JSON summary fields: cycles, deadline_misses, skipped_releases, miss_rate, exec_us p50/p99/max,
release_jitter_us p50/p99/max, final_pointing_error_deg, attitude_estimation_error_deg,
gyro_bias_estimation_error_deg_per_h, body_rate_deg_s.

## Verified (x86 VM, 2 vCPU, not RT) — `vm_test_30s.log`, `vm_test_30s.csv`
100 Hz, 30 s: pointing error 30.0° → 0.033°, attitude-estimation error 0.83° → 0.041°, gyro-bias error
475 → 9.2 °/h; exec p50 9.4 µs, p99 24.1 µs; 1 deadline miss in 3000 cycles (VM scheduling, 15 ms jitter spike).
Board (A53) numbers not yet measured.

Note: one cycle is light (~10 µs on x86) — by design; ADCS is the *deadline-critical victim*, not the heavy load.
The experiment measures its deadline misses/jitter while payload processing + F' + ML-DSA signing load the cores.
