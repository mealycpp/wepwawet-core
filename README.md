<p align="center"><img src="docs/img/rscl_logo_300.png" alt="Reconfigurable Space Computing Lab" width="180"></p>

# WEPWAWET-CORE

**A hardware-resident ML-DSA architecture with fabric-generated, fabric-sealed keys for post-quantum avionics.**

WEPWAWET-CORE puts ML-DSA-44 (FIPS 204) key generation, signing and verification in the FPGA fabric of a
Zynq UltraScale+ node. One ROM microsequencer drives a shared datapath (NTT, inverse NTT, SHAKE-128/256,
polynomial multiply-accumulate) over a four-bank scratchpad. The signing key is generated in the fabric from an
on-die entropy source and stays there: after LOCK the host reads zeros, writes are refused, and the host
sees only the public key. Two AUP-ZU3 boards run NASA F Prime as two CubeSats and exchange signed command
frames in both directions while an attitude-control loop and a CCSDS 121.0 imaging payload load the four A53 cores.

Source-available for research and evaluation. Reconfigurable Space Computing Lab, Cal Poly Pomona.

## Architecture

**One spacecraft node.** Four Cortex-A53 cores run Linux, F Prime, the attitude loop and the imaging payload. The signer, its key and every per-signature secret stay in the fabric behind one AXI4-Lite window, and the processor issues one job per signature.

<p align="center"><img src="docs/img/fig_node.png" alt="WEPWAWET-CORE spacecraft node" width="900"></p>

**The signing engine.** A 30-state microsequencer fetches 64-bit ROM words and issues either a stream kernel (NTT, inverse NTT, SHAKE, multiply-accumulate) or an RTL unit on the scratchpad banks. A retry manager closes the FIPS 204 rejection loop without the processor. Hatched regions hold the sealed key and seeds and are never readable from the host.

<p align="center"><img src="docs/img/fig_engine.png" alt="WEPWAWET-CORE signing engine: ROM, microsequencer, scratchpad, kernels" width="900"></p>

## Why one job per signature

The same kernels were studied under three control styles. Driving every kernel call from the processor, or chaining kernels per stage, leaves hundreds of milliseconds of bus traffic and waits per signature. Running the whole rejection loop in the fabric brings the total to 7.5 ms.

<p align="center">
<img src="docs/img/fig_control_granularity.png" alt="Time per signature for three control styles" width="430">
<img src="docs/img/fig_gem5.png" alt="Simulated processor-side cost versus register latency" width="430">
</p>

The left plot mixes a measured replay, a model and the board measurement, as labelled. The right plot is a gem5 simulation of the processor side only; the per-signature line is access count times latency, not a simulation.

**Where the cycles of one attempt go.** The coefficient unit and the transforms dominate, not data movement. The lighter bars are a projection for three circuit changes that were not built.

<p align="center"><img src="docs/img/fig_cycle_profile.png" alt="Cycle profile of one signing attempt" width="560"></p>

## Key certification protocol

<p align="center"><img src="docs/img/fig_protocol.png" alt="WEPWAWET-CORE key certification protocol" width="520"></p>

1. Each fabric generates its key pair from on-chip entropy, seals the secret key and releases only the public key.
2. The public key is downlinked to the ground.
3. The ground station signs a labelled statement binding the node name to a SHAKE-256 digest of that key.
4. The ground uplinks the peer's public key and certificate.
5. A node installs a peer key only after its fabric verifier accepts the certificate.
6. Crosslink frames are signed in the sender's fabric and verified by the receiver.

Steps 1 and 6 are measured on hardware under mission load. Steps 2 to 5 were exercised on the two boards with fabric-generated keys, including rejection of a key or certificate with one bit altered. See "Security scope and limits" for what this does and does not establish.

## Mission dashboard

<p align="center"><img src="docs/img/dashboard.jpg" alt="WEPWAWET-CORE mission dashboard replaying a recorded two-node run" width="900"></p>

The dashboard replays the recorded runs in `results/` on their real timestamps: both CubeSats, the signed frames in each direction, the verify verdict from the receiver, the four cores of each node, ADCS jitter, payload deadlines, and the key and certificate state. Every number on screen is read from a board log. The picture shows a recorded two-node run on the sealed image.

To see the same thing from a clone of this repository:

```
python3 dashboard/test/serve_test.py        # any OS, replay only, then open http://127.0.0.1:8088/
powershell -ExecutionPolicy Bypass -File .\dashboard\wcore_dash.ps1    # Windows, replay and live boards
```

Pick a run under **DUPLEX** in the run list and press play. Live mode needs the two boards on ssh as `aup1` and `aup2`; see `dashboard/README.md`.

## Results at a glance

| Item | Value |
|---|---|
| Device, clock | AUP-ZU3 (Zynq UltraScale+ ZU3EG), 300 MHz |
| Sealed image (KeyGen + Sign + Verify) | 44,787 LUT, 23 BRAM tiles, 42 DSP, WNS +0.011 ns |
| Unsealed reference image | 45,410 LUT, WNS +0.026 ns |
| KeyGen in fabric | 325,829 and 325,942 cycles on the two boards |
| Sign | 439,276 cycles per attempt + 35,345 fixed (fit over 5,350 signatures; every one within 306 cycles of the fit) |
| Verify | 214,161 to 214,197 cycles |
| Processor time per fabric signature | 0.53 ms median, at most 0.60 ms for 99%, independent of the rejection count |
| Board self-test, sealed image | 2,000 / 2,000 on both boards |
| Two-node duplex, sealed image, ground-certified keys | 1,791 + 1,784 signed; all 3,575 accepted; 0 rejected |
| ADCS deadlines under load | 0 missed in every run |
| Host attack after LOCK | every secret read returns 0 and sets the sticky violation flag |

Under the imaging-pass workload (10 signed commands per second, three runs each):

| Configuration | Signed of 600 | Sign median (ms) | Processor time, median / 99% (ms) | Worst ADCS delay (ms) | ADCS misses | Payload finish (s) |
|---|---|---|---|---|---|---|
| No signing | -- | -- | -- | 0.41--0.44 | 0 | 75.0 |
| Fabric | 594 / 584 / 597 | 5.12--5.13 | 0.53 / 0.60 | 0.52--0.85 | 0 | 75.0--76.9 |
| Neon (A53) | 596 / 597 / 594 | 0.91--1.04 | 0.94 / 3.9 | 0.47--1.18 | 0 | 75.0--75.3 |
| Neon, priority 70 | 596 / 593 / 593 | 0.93--0.94 | 0.93 / 3.8 | 0.29--0.53 | 0 | 75.0--75.6 |
| Two nodes, node 1 | 597 / 599 / 595 | 5.13--5.15 | 0.53 / 0.60 | 0.59--1.08 | 0 | 75.0--79.1 |
| Two nodes, node 2 | 596 / 597 / 591 | 5.11--5.16 | 0.53 / 0.59 | 0.30--0.72 | 0 | 75.1--75.5 |

The engine leaves the mission undisturbed: no ADCS deadline is missed, and the fabric's time per attempt does not move
under load. A fabric signature takes longer end to end than Neon software but holds the calling core for about half the
time, with no tail, and the key never leaves the fabric.

These runs are in `results/mission_runs_clean/` and the table is regenerated by `python3 analysis/clean_analysis.py`.
The folder also holds the runs with the F Prime components unpinned, which are not part of the table.
To reproduce the timing, keep run logs in memory during the measured window, as `mission/harness/mission_run.sh` does;
the earlier sessions under `results/mission_runs_v7_sweep/` wrote logs to the SD card during the run and are kept for the
dashboard only.

## Repository map

| Folder | Content | Reproduces |
|---|---|---|
| `rtl/sealed_v8/` | RTL of the sealed image as loaded on both boards | Architecture, resource and timing tables |
| `rtl/unsealed_v7/` | Unsealed reference image | Comparison rows |
| `rtl/simulation_only/` | Later variants verified in simulation only, never built or loaded | Forward-looking section |
| `sim/` | Testbenches, vectors (known-answer test keys, never used on a board), Verilator and XSim scripts, profiler | Functional and seal simulation, control-granularity profile |
| `build/` | Vivado batch scripts | Bitstream generation |
| `bitstreams/` | Bitstreams, hardware hand-off files, utilisation and timing reports, SHA-256 list | Resource and timing numbers |
| `driver/` | Userspace driver, self-tests, KeyGen and certificate tools, host attack program, board kit | Self-test, seal attack, certificate check |
| `fprime/` | F Prime components (hardware-accelerator manager, signed transport) and install scripts | Two-node runs |
| `mission/` | ADCS load, CCSDS 121.0 payload load, run harness | Mission workload |
| `ground_ca/` | Ground certificate tool (source only) | Certificate protocol |
| `analysis/` | Scripts that turn logs into the paper's tables | All tables from `results/` |
| `results/` | Board logs, mission runs, board tests, seal review, final CSV | Every measured number |
| `gem5/` | Transaction model and gem5 scripts | Design-space analysis (model, not a board measurement) |
| `dashboard/` | Live and replay dashboard | Visual replay of the runs |
| `tools/wcore.ps1` | Single control script used to drive both boards | Run procedure |

## Requirements

- Two AUP-ZU3 boards with PYNQ Linux, reachable over ssh as `aup1` and `aup2`
- Vivado 2022.2 and Vitis HLS to rebuild; Verilator 5 or XSim to simulate
- F Prime with its GDS, PQClean (ML-DSA-44 clean) and gcc on the boards
- Python 3 for analysis; PowerShell 5.1 or later for `tools/wcore.ps1`
- gem5 (ARM) for the optional transaction study

Board addresses appear as `<AUP1_IP>` and `<AUP2_IP>` and the workstation path as `<WORKDIR>`; set them
for the local setup (see `fprime/PqcTransport.cpp`, `tools/wcore.ps1`, `build/*.tcl`). Absolute host paths
and board addresses in scripts and logs were normalised to these placeholders; nothing else in the logs was changed.

## Security scope and limits

Three things are kept apart.

1. **Fabric-enforced secret isolation: measured.** Seed, expanded key, per-signature randomness and rejected
   intermediates are generated and held in the fabric. After LOCK, host reads of the secret window return zero and
   raise a sticky violation; writes are refused; residue is scrubbed after each signature; zeroize clears the key.
   Tested in simulation and by an attack program run as root on the board.
2. **Authenticated public-key distribution: demonstrated.** A ground key signs each node's public-key digest;
   each node checks the peer certificate with both the fabric and the software verifier. The ground public key is
   a file on the host.
3. **Hardware-rooted identity and attestation: not established.** A root user can load a different bitstream,
   request signatures from the sealed key, or replace the ground public-key file. There is no secure boot, the
   bitstream is not encrypted or authenticated, and side channels and fault injection are untested. The entropy
   source has no NIST SP 800-90B qualification.

The AUP-ZU3 is a commercial board with no radiation tolerance. It is a prototype of the architecture, not flight hardware.

No private key is in this repository. The sealed images generate their own; the ground signing key is kept offline.
The certificates and public keys under `results/certificates/` belong to the test campaign and identify nothing else.

## Licence

PolyForm Noncommercial License 1.0.0 for everything written for this project (RTL, driver, F Prime components,
scripts, documents); see `LICENSE` and `NOTICE`. Commercial use needs a separate licence: mealy@cpp.edu.
Third-party parts keep their own licences; see `THIRD_PARTY_NOTICES.md`.

## Citation

M. El-Hadedy and W.-M. Hwu, "WEPWAWET-CORE: A Hardware-Resident ML-DSA Architecture with Fabric-Generated,
Fabric-Sealed Keys for Post-Quantum Avionics," submitted to IEEE Journal on Emerging and Selected Topics in
Circuits and Systems (JETCAS), 2026.

## Acknowledgments

This work was supported by the Air Force Research Laboratory under Agreement FA8650-24-2-2403, the U.S.
Department of Defense under Award W911NF-24-1-0265, and the U.S. Navy Naval Engineering Education Consortium
(NEEC) under Grant N00174-23-1-0002, and the Office of Naval Research Summer Faculty Research Program. The views and conclusions are those of the authors and do not represent
the official policies of the sponsors or the U.S. Government.

<p align="center">
<img src="docs/img/sponsors/afrl.png" alt="AFRL" width="200">
<img src="docs/img/sponsors/dod.png" alt="U.S. DoD" width="200">
<img src="docs/img/sponsors/navy_neec.png" alt="U.S. Navy NEEC" width="200">
<img src="docs/img/sponsors/onr_sfrp.png" alt="ONR SFRP" width="200">
</p>

Contact: Mohamed El-Hadedy, mealy@cpp.edu
