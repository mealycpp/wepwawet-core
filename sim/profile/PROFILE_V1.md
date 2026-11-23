# PROFILE_V1 -- where the 439k cycles of one ML-DSA-44 SIGN attempt go (v5 board RTL, XSim)

RTL profiled: exactly the v5 board set (04_WORK/sign_v1/src + sign_v4 retry manager/wrapper), read-only.
Method: tb_profile.sv = tb_sign_multi + a TB-only monitor (hierarchical *reads*; no force/deposit; DUT
unchanged; signatures still captured). One record per ROM instruction (FETCH_REQ entry to next FETCH_REQ
entry), with sequencer-state histogram, AXI-Lite CFG transactions (bridge req/rsp), AXIS tx/rx beats and
first/last beat cycles, HLS ap_start..ap_done, polymul busy/beats, AUX scratchpad handshakes.
tb_profile_hls.sv adds HLS sub-pipeline call/busy counters.

| run | result | log / data |
|---|---|---|
| vec_7 (1 attempt) | 439,270 cycles (matches board 439,26x) | profile_v1/run_20261121_204530/vec_7/{03_sim.log, capture/profile_trace.csv, profile_summary.json} |
| vec_6 (3 attempts) | 1,317,953 = 439,353 + 439,339 + 439,261 | profile_v1/run_20261121_204818/vec_6/{...same} |
| vec_7 HLS sub-loops | see table 4 | profile_v1/run_20261121_205113/vec_7/capture/hls_subloops.txt |
Analysis: profile_v1/analyze_profile.py <run>/<vec>.

## 1. Per-signature vs per-attempt
vec_6: every attempt re-executes PC0..PC148 including ExpandA (34,584 cycles in each of the 3 attempts).
Retry restore (40 scratchpad writes by the retry manager) + ack = 87-90 cycles. Per-signature-only work: ~4 cycles.
=> today the whole 439.3k is per-attempt; ExpandA (7.9%) is per-signature work done per attempt.

## 2. Per category, one attempt (vec_7, 439,270 cycles)
| category | cycles | % |
|---|---|---|
| CONFIG (CFG executor + ap_start AXI-Lite; 345 AXI-Lite txns over 43 kernel calls) | 1,252 | 0.3 |
| TRANSPORT (AXIS scratchpad<->HLS kernel windows; 2,912 tx / 5,030 rx beats) | 20,160 | 4.6 |
| COMPUTE (HLS NTT/INTT/SHAKE tx-last..rx-first gaps + HLS polymul busy) | 195,363 | 44.5 |
| AUX RTL units (coefficient ops, RejNTT, Gamma1, w1Encode, SampleInBall, dot4 RTL) | 221,227 | 50.4 |
| CONTROL/GAP (fetch/decode/ack/branch) | 1,268 | 0.3 |

## 3. Per stage, one attempt (vec_7)
| stage | instr | cycles | % | dominant cost |
|---|---|---|---|---|
| INTT x16 (w, cs1, cs2, ct0) | 16 | 123,728 | 28.2 | HLS INTT internal: 7,185 of 7,733 cycles/call |
| coefficient-wise AUX (CENTER x16, ADD x8, SUB x4, MakeHint x4, HighBits/LowBits/FREEZE x4 each, NORM x12) | 56 | 178,000 | 40.5 | 7,168 words at 24.8 cycles/word, serial FSM |
| NTT x5 (y, c) | 5 | 34,765 | 7.9 | HLS NTT internal: 6,405 of 6,953 cycles/call |
| ExpandA (SHAKE128 x16 + RejNTT x16), redone each attempt | 48 | 34,592 | 7.9 | RejNTT aux 1,542/poly; SHAKE128 590/poly |
| dot4: A*y (4) + c*s1, c*s2, c*t0 | 7 | 52,366 | 11.9 | polymul busy 47,068; of that READ_A+READ_B operand feed 35,840 vs MULACC 9,996 |
| ExpandMask (SHAKE256 x4 + Gamma1 x4) | 8 | 10,416 | 2.4 | Gamma1 unpack 2,159/poly |
| w1Encode + mu||w1 + H() + SHAKE(c~) + SampleInBall | 5 | 5,388 | 1.2 | |
| control | 4 | 15 | 0.0 | |

## 4. HLS sub-loop evidence (vec_7, one attempt)
| kernel | top calls | READ busy | BUTTERFLY calls / busy | SCALE | WRITE |
|---|---|---|---|---|---|
| NTT | 5 | 1,315 | 1,275 (=255/transform) / 12,790 | - | 1,240 |
| INTT | 16 | 4,208 | 4,080 (=255/transform) / 40,928 | 4,112 | 3,968 |
| polymul | 28 | READ_A 17,976, READ_B 17,864 | MULACC 9,996 | | |
The butterfly is a pipelined (II=2) loop invoked once per butterfly group: 255 invocations per transform,
~4 butterflies each. Butterfly execution = 2,558 cycles/transform; the remaining ~3,350 cycles/transform are
per-invocation start/finish overhead in the parent FSM. polymul spends 76% of its time ingesting operands.

## 5. Bounds and projections (derived from the measured cycles above; NOT results)
- Lower bound with today's kernels, if every non-kernel cycle vanished: HLS NTT/INTT/SHAKE compute gaps
  148,295 + polymul MULACC 9,996 = 158,291 cycles/attempt (0.528 ms); counting full polymul busy: 195,363 (0.651 ms).
  PQClean NEON measured on the same A53: 0.26 ms/attempt -> today's HLS kernels alone cannot match it.
- (a) CFG once per signature: saves <= 1,252/attempt -> 438,018 (-0.3%).
- (b) kernel transport removed/overlapped (operands resident): saves <= 20,160 -> 419,110 (-4.6%);
  also removing the dot4 operand feed (35,840): ~383,270 (-12.7%).
- (c) both: 417,858 (-4.9%); with dot4 feed: ~382,018 (-13.0%).
  => configuration and transport are NOT the bottleneck. NTT/INTT internals (36.1%) and the serial
  coefficient-wise AUX unit (40.5%) are.

## 6. Three most promising RTL changes (ranked by cycles saved / risk)
1. Hoist ExpandA out of the retry loop -- LOW risk. On retry, restart the sequencer at PC48 instead of 0
   (the start_pc port already exists in verify_v1/src; bank0 Ahat is never written after PC47 in the sign ROM;
   retry manager no longer needs to rewrite rho). Saves 34,584 per retry = 113k cycles (0.38 ms) at the
   measured mean of 4.28 attempts; first attempt unchanged. Validate with vec_6/vec_3/vec_23 byte-exact.
2. Pipeline wcore_mldsa44_coeff_aux -- MEDIUM risk, largest saving. Today 24.8 cycles/word over 7,168
   words/attempt. A read->canon->op->write pipeline at II<=3 (bank-port limited: binary ops read src and dst,
   often in the same bank) gives ~21.5k cycles; at II=1 ~9k. Saves ~156k-169k/attempt (35-38%). Fusing the 16
   CENTER passes into their consumers and deleting the 4 FREEZE copies removes another 59k of passes outright.
3. Re-synthesise HLS NTT/INTT with a flattened butterfly loop (one pipelined loop over 1,024 butterflies,
   computed indices) -- MEDIUM-HIGH risk (new HLS run, 300 MHz re-closure, bit-exact re-verification).
   Removes ~3,350 cycles/transform of invocation overhead now; at II=2 ~2,600 cycles/transform total
   (saves ~92k/attempt), at II=1 ~1,650 (saves ~124k/attempt).
   Next after these: burst/pipelined operand feed for the dot4 polymul (35.8k/attempt).
Projection for 1 (II=3) + 2 (II=2) + 3: ~191k cycles first attempt, ~156k per retry -> ~0.70M cycles
(2.3 ms) per mean signature vs 6.27 ms measured. Beating PQClean NEON (1.10 ms) additionally needs II=1
NTT and coefficient units plus overlapped polymul feed. All of these are projections, not measurements.
