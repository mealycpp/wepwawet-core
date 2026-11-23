# Mission-load experiment harness (CPU signer vs fabric signer under F')

Question: with the A53 cores busy with real mission software, does signing every crosslink frame on the CPU
(PQClean ML-DSA-44, in-process in F' HwAccelMgr) hurt the mission (ADCS deadlines, payload throughput, F' rate
groups), and does moving signing into the fabric (v6/v7 image) remove that interference?

## Files
- `fsw_driver.py`  rate-controlled PeerPing over ONE persistent GDS connection (reuses fprime-cli's own parser and
  CommandSendCommand pipeline; F' venv). `--mode open` fixed rate, `--mode closed` send_and_assert (waits).
- `mission_run.sh` one run on the sender: F' (WCORE_BACKEND=cpu|fpga) + adcs_load (SCHED_FIFO) + payload_load,
  /proc/stat per-core sampling, driver, collection, `run_summary.json`. Also `receiver` and `stop` modes.
- `sweep.sh`       backend x rate x load (backends interleaved per cell), then analyze.
- `analyze.py`     all run folders -> CSV + the CPU-vs-FPGA table.

## Why not CmdSequencer
This deployment's LinuxTimer runs at 1 Hz (Main.cpp `startRateGroups(Fw::TimeInterval(1,0))`) and `cmdSeq.schedIn`
is on rateGroup2 (divisor 2), so timed sequence records are only checked every 2 s; zero-delay records run
back-to-back (saturation only). fprime-cli costs ~1 s per call. The driver keeps one connection open instead.

## Board layout (assumed)
~/mission_v1/{harness,payload,adcs}; payload/payload_load, payload/data/scene.raw, adcs/adcs_load (other workstreams);
~/aup_kit_v6 (load_v6.py, wcore_check.c). Override with ADCS_BIN, PAYLOAD_BIN, PAYLOAD_INPUT, KIT.

## Commands
Windows:  scp -r <WORKDIR>\04_WORK\mission_v1 xilinx@aup1:~/   (and aup2)
AUP2 (receiver, constant across runs):   sudo bash ~/mission_v1/harness/mission_run.sh receiver
AUP1 (sender), one smoke run each:       sudo bash ~/mission_v1/harness/mission_run.sh fpga 5 0 30 smoke
                                         sudo bash ~/mission_v1/harness/mission_run.sh cpu  5 0 30 smoke
AUP1 full sweep (~ 2 backends x 4 rates x 5 loads x (60+~60) s ~= 80 min):
                                         sudo bash ~/mission_v1/harness/sweep.sh 60 "1 5 10 20" "0 1 2 3 4" 1
Analyze again any time:                  python3 ~/mission_v1/harness/analyze.py /home/xilinx/wepwawet-core/logs/mission_runs
Stop everything:                         sudo bash ~/mission_v1/harness/mission_run.sh stop

## Core map and load levels
F' pins dilithiumSign->cpu0, dilithiumVerify->cpu1, pqcTransport->cpu2, pqcSecurityGateway->cpu3 (instances.fpp).
PeerPing (and therefore the CPU signer's PQClean work) executes on the pqcTransport thread (cpu2).
CORE_ORDER default "1 3 0 2": L1 = adcs on cpu1; L2 += payload cpu3; L3 += cpu0; L4 += cpu2 (shares the signing core).
ADCS default SCHED_FIFO prio 80 (above F' threads, as flight ADCS would be); payload SCHED_OTHER. Both are run
parameters (ADCS_PRIO, CORE_ORDER) and are recorded in params.json; report them with the results.

## Untested / caveats (be explicit in the paper)
- Nothing here has run on a board yet. fsw_driver.py was import- and argument-tested against fprime-gds 4.4.1 on a
  Linux VM only (fails at dictionary lookup, as expected with no project); the board venv version may differ.
- Open-loop rates above what PeerPing can complete (sign + TCP + peer verify + 'A' reply, all synchronous in the
  pqcTransport handler) will fill pqcTransport's async command queue; F' may assert on queue full. Start with
  rates <= 10/s, check `queue_full` and `driver_late`, or use DRIVER_MODE=closed.
- F' rate groups here only run light framework work at 1 Hz, so `cycle_slips` is expected ~0; the decisive metrics are
  ADCS deadline misses/jitter, payload misses/throughput, sign latency, per-core utilisation.
- Load-program JSON keys are matched by candidate names in analyze.py FIELDS; if the payload/adcs programs use other
  names, add them there (raw JSON is kept in each run folder).
- The peer (receiver) verifies on its FPGA in every run; only the sender's signer changes.
- MOCK data (analyze.py prints a banner) was used only to test the scripts: /tmp/mock_runs on the VM, never in 04_WORK.
