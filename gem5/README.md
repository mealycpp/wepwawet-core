# WEPWAWET-CORE transaction and gem5 study

Prepared 2026-11-19 from the project hand-off archive of 2026-11-19.

**Nothing in this package is a measurement from AUP1.** Every CSV has a `basis` column. Three kinds of number appear:

| Label | Meaning |
|---|---|
| replay | The unmodified handoff driver code ran against a register model, and its accesses were counted. Exact and deterministic. |
| MODEL-PREDICTED | The proposed chaining behaviour. It is not implemented in RTL or on the FPGA. |
| SIMULATED | Produced by gem5 (step 3 below), with stand-in register blocks and a latency parameter. |

## 1. Audit: what is executable now

| Item | State |
|---|---|
| gem5 | 26.0.0.0, `build/ARM/gem5.opt`, built 2026-11-19 on WSL2 Ubuntu 24.04. The git commit was not recorded; get it with `git -C ~/gem5 rev-parse HEAD`. |
| Mode | Syscall emulation (SE). Full-system mode has not been run, so there is no kernel, device tree or root filesystem. |
| CPU models used | `TimingSimpleCPU` (in-order) so far. `O3` is available and untested here. One core. |
| Memory | Single-channel DDR3-1600, DDR4-2400 and LPDDR3-1600 models; private L1, or private L1 plus L2. |
| Accelerator model in gem5 | None. No WEPWAWET device model is compiled into gem5. |
| What ran on your machine | The hello-world sweep and the live monitor with a software NTT/Keccak program. Neither involves WEPWAWET. |
| New in this package | A register-level model of the Stage 8 interface (Python), a replay of the unmodified backend on it, a chaining model, and a gem5 SE configuration that uses stand-in register blocks. The gem5 part ran on 2026-11-19 (section 3). |

What the gem5 part can and cannot support:

- It can give the CPU-side cost of issuing the driver's bus sequence: cycles, instructions, cache misses and DDR traffic, with the register access latency as a parameter.
- It cannot give kernel compute time, fabric timing, or anything about the microsequencer. The stand-in blocks answer after a fixed delay and compute nothing.
- It runs a C replay of the bus sequence, so it is a lower bound on driver cost. The real backend is Python on PYNQ.

## 2. Reproduce the transaction results (runs anywhere, no gem5 needed)

```bash
pip install dilithium-py pytest
cd wcore_gem5
python3 -m pytest -q tests            # 37 tests
python3 analyze.py --signatures 200   # rewrites results/*.csv, about 25 s
```

### Definitions

- **Software call**: one `do_ntt`, `do_intt`, `do_polymul`, `do_shake128` or `do_shake256` call.
- **Kernel dispatch**: one start pulse accepted by the sequencer. Today one per software call.
- **Scratchpad word command**: one write of 1 or 2 to the host COMMAND register, which moves one 64-bit word. Split into load (input words), zero (zero-initialising output words before the start), read (output words) and scrub (zeroing input and output afterwards).
- **MMIO bus transaction**: one `MMIO.read` or `MMIO.write`, which is one AXI-Lite access.
- **Driver sleep**: a `time.sleep` in the backend. These are read from the source, not timed.

### Stage 8 as the backend drives it today (replay)

| Call | Word commands | MMIO transactions | Driver sleep |
|---|---|---|---|
| NTT | 640 | 3,856 | 4 ms |
| INTT | 640 | 3,856 | 4 ms |
| PolyMulAcc | 896 | 5,392 | 4 ms |
| SHAKE128, 34 bytes in, 1,024 out | 394 | 2,382 | 4 ms |
| SHAKE256, 66 bytes in, 576 out | 234 | 1,422 | 4 ms |

The handoff's expected 640 / 640 / 896 are confirmed. Each word command costs 6 bus transactions, plus 16 control transactions per job (18 for SHAKE). The closed form is `6 x (2 x tx + 3 x rx) + 16`, and it matches the replay for every kernel and for a full signature (762,440 transactions, `results/validation_full_stack.json`).

### ML-DSA-44, 200 signatures with one key (`results/case_comparison.csv`)

| Per signature | B: Stage 8 today | C: chaining, conservative | C: chaining, optimistic |
|---|---|---|---|
| Basis | replay | MODEL-PREDICTED | MODEL-PREDICTED |
| Kernel dispatches, mean | 252 | 252 | 252 |
| Start/ack sequences, mean | 252 | 190 | 190 |
| Word commands, mean | 155,242 | 47,307 | 39,253 |
| MMIO transactions, mean | 935,635 | 287,286 | 238,959 |
| MMIO transactions, median | 725,448 | 223,104 | 183,936 |
| MMIO transactions, 95th percentile | 2,423,840 | 744,200 | 632,840 |
| Driver sleep, mean | 1.01 s | 0.76 s | 0.76 s |

- Rejection iterations: mean 4.2, median 3, maximum 28 (`results/mldsa_rejection_distribution.csv`).
- Where case B's word commands go: load 23%, zero-init 18%, read 18%, scrub 41%.
- SHAKE full-prefix regeneration: of 41,025 bytes produced per signature, 12,288 are repeats that incremental streaming would avoid.
- Key generation and verification rows are in the same CSV.

### What case C assumes

Case C is a parameterised model in `chain_model.py`, not existing hardware.

- Operands stay in the scratchpad. The CPU loads an operand only if it is not already there.
- The fabric writes whole outputs and scrubs itself, so the CPU does no zero-init and no scrub.
- A program ends when the next kernel needs data the CPU has not loaded, because that data may depend on a result the CPU must read first.
- Conservative: the CPU still reads every kernel output. Optimistic: it reads an output only if no later kernel consumes it unchanged. The optimistic figure is a lower bound.
- Defaults: 16 polynomial slots, up to 16 instructions per program. `results/chain_sensitivity.csv` sweeps both.
- Every operand must have a recorded source (CPU load or a producing kernel); otherwise the model raises `GhostTransfer`.

Most of the saving comes from removing zero-init and scrub and from not reloading operands. Longer programs matter less under the conservative rule: 252 start/ack sequences become 190.

### Case A: DASC shared-DMA (`results/case_A_dasc_structure.csv`)

Structure only, counted from `wp_hw.py`: 7 kernel-IP register writes per call (9 for SHAKE), 2 DMA transfers and 2 DMA waits. The register traffic inside the PYNQ DMA driver and all timings are missing, so case A is not placed in the comparison table.

## 3. Run the gem5 comparison (from `~/gem5`)

Copy this folder into `~/gem5/`, then from `~/gem5`:

```bash
python3 wcore_gem5/gem5/run_gem5.py --quick    # 3 runs, checks the setup
python3 wcore_gem5/gem5/run_gem5.py            # 3 cases x 3 register latencies
```

Output: `wcore_gem5/results/gem5_case_comparison.csv` with simulated time, CPU cycles, instructions, DDR requests and bytes, DDR access and queueing latency, and L1/L2 misses per case.

- The workload is one signature (3 rejection iterations, 211 dispatches), replayed by `gem5/wcore_replay.c`.
- Before gem5 is involved, the C replay was checked on the host: for case B it issues the recorded bus sequence exactly (300,680 reads, 461,760 writes, identical order and addresses).
- Each gem5 run then checks that the bus saw the same number of uncached reads and writes.
- Register latency is a parameter (50, 200, 1,000 ns). No AXI-Lite round-trip measurement was supplied.
- Driver sleeps are not simulated; they are listed in a separate column.

### Live comparison in the browser

```bash
python3 wcore_gem5/gem5/wcore_live.py     # then open http://localhost:8766
```

Runs the three cases one after another and draws register accesses, instructions and DDR requests as each gem5 simulation advances. Options: `--mmio-latency 1000ns`, `--interval-us 2000`, `--cpu o3`.

First results on the professor's machine (2026-11-19, gem5 26.0.0.0, 200 ns register latency, in-order core at 1.2 GHz), all SIMULATED:

| Case | Simulated time | CPU cycles | Bus check |
|---|---|---|---|
| B: Stage 8 today | 171.7 ms | 206.1 million | 300,680 reads and 461,760 writes, as recorded |
| C: chaining, conservative (MODEL-PREDICTED) | 52.5 ms | 63.1 million | match |
| C: chaining, optimistic (MODEL-PREDICTED) | 43.0 ms | 51.6 million | match |

In case B, 762,440 register accesses at 200 ns account for 152 ms of the 172 ms. The memory bus saw about 3,500 cache-line fetches for the whole signature, so DDR traffic is negligible in the per-word AXI-Lite design. The driver's 0.84 s of sleep for this signature is not simulated.

To rebuild the scenarios and ARM binaries: `sudo apt install gcc-aarch64-linux-gnu`, then `python3 wcore_gem5/gem5/gen_scenarios.py`.

## 4. Findings in the handoff code

1. **The ML-DSA bridge cannot offload as shipped.** `stage8_mldsa_bridge.py` compares offload names (`'ntt'`) with method names (`'do_ntt'`). With the default it patches nothing, so signing runs in software. With the selection `stage8_pqc_lab.py` passes (`['ntt', 'intt', ...]`) it raises `ValueError`. The workload here sets the names and calls the bridge's own patch methods; the reference file is unchanged.
2. **The backend sleeps 4 ms per job.** `_pulse` sleeps 2 ms and runs twice per job. At 252 jobs that is about 1 s per mean signature before any register access or kernel time.
3. **Zero-init and scrub are 59% of the word commands.** Both are done one word at a time by the CPU.
4. **The descriptor path is single-instruction.** The exported ROM is one kernel then HALT, as the handoff says. Nothing here treats it as a chained system.

## 5. What the register model takes from where

- Host interface register map, status bits and error codes: `rtl_export_baseline/wcore_host_mem_axi.v`.
- Sequencer and descriptor GPIO bit meanings: inferred from the checks the backend performs. The block-design wiring is not in the archive.
- Descriptor format and lane numbers: `wcore_stage8_descriptor.py`.
- SHAKE128 at `0x80050000`, SHAKE256 at `0x80070000`.
- Kernel results: software stand-ins that satisfy the bridge's Montgomery-domain contract, with INTT scale 1. They are not the HLS kernels. Signatures produced through the full stack are accepted by an unpatched `dilithium_py`.
- Number of busy polls per word command and per job: parameters, default 0.

## 6. Smallest additional inputs that would improve this

1. The matching Stage 8 `wepwawet.hwh` or address report, to confirm the descriptor GPIO at `0xA0050000` and the sequencer status bits.
2. A measured AXI-Lite register round-trip time from the A53, and the kernel-bench JSON with `trace_samples`, to replace the latency parameter.
3. The DASC DMA driver trace or timings, to make case A comparable.
4. The current `wcore_mem_arbiter.v` and deployed microcode, to check the chaining model's program rule against what the sequencer can do.

## Files

| Path | Contents |
|---|---|
| `wcore_model.py` | Register model, transaction recorder, loader for the unmodified backend |
| `workload.py` | ML-DSA-44 through the unmodified bridge; functional kernel stand-ins |
| `chain_model.py` | Accounting for cases A, B and C |
| `analyze.py` | Writes every CSV in `results/` |
| `tests/` | 37 regression tests |
| `gem5/` | C replay, scenario generator, gem5 configuration, runner, prebuilt ARM binaries |
| `reference_from_handoff/` | Unmodified copies of the four handoff files used, with their checksums |
| `results/` | CSV and JSON outputs, including full MMIO traces for one NTT and one PolyMulAcc call |
