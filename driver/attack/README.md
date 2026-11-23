# seal_v8 board-side adversarial test (REVIEWER) — NOT RUN ON HARDWARE YET

`wcore_attack_v8.c` plays a hostile root process against the seal_v8 signer window (0xA000_0000, 128 KiB) via /dev/mem.

**Run only with a TEST key** (e.g. `04_WORK/vectors/vec_7/sk_TEST_ONLY.bin` + `msg.bin`). The test ZEROIZEs the core
before provisioning and again at the end.

```
./build_attack.sh
sudo ./wcore_attack_v8 --sk sk_TEST_ONLY.bin --pk pk.bin --msg msg.bin --out /tmp/attack   # known-key mode (phase-1 or phase-2 ABI, by VERSION)
sudo ./wcore_attack_v8 --msg msg.bin --out /tmp/attack                           # structural mode (PL-generated key)
```
PASS criteria (exit 0, `ATTACK_SUMMARY PASS`): no bus error during the dump; every scratchpad word outside the release
whitelist {h b1[0..511], c~ b1[1150..1153], z b3[1400..1911] (only after a successful SIGN)} reads 0; rho'' registers read
0; SEAL read/write violation bits sticky and counter increases; known-key mode: zero 64-bit / 32-bit / 16-byte hits of
s1_hat, s2_hat, t0_hat, packed sk (K, s1, s2, t0) and rho''; host overwrites of key words and of rho (register and SP word)
do not change a deterministic re-signature. Offline: verify `sig_det.bin` against the TEST pk (e.g. PQClean oracle in
`04_WORK/seal_v8/review/tools/pqclean_oracle`), and compare with `signature_REFERENCE_ONLY.bin` of the vector.

Register map: seal_v8 (VERSION 0x0003_0001 phase-1 ABI: host mu b2[1024], host rho'' regs, deterministic re-sign
comparison; VERSION 0x0003_0002 phase-2 ABI: K b2[1040..1043], mu b2[1048..], PL TRNG rnd + PL rho'', hedged -> the
refused-write check is "both signatures PL-verify under the TEST pk" (pass `--pk`), plus offline PQClean verify of
`sig_1.bin`/`sig_2.bin`). CTRL bit3 LOCK, bit4 ZEROIZE; STATUS bit10 locked, bit11 violation, bit13 sign_out_valid;
SEAL @0x1_001C. Build links `../wcore_drv/wcore_fpga.c` (falls back to `../../aup_kit_v7/wcore_drv`, which lacks the v8
verify ABI -> use the v8 driver).
`readback_probe.sh` (run while a TEST key is sealed): checks CRITICAL-6 — whether root can read PL configuration data
(BRAM included) through the PCAP/debugfs readback path; the v8 image sets BITSTREAM.READBACK.SECURITY=Level2, this is the
board check that Level2 actually blocks it on ZynqMP.

What this test cannot show: signing-oracle misuse by root, bitstream reload/DoS, timing/power/EM side channels,
JTAG/PCAP readback, physical attacks.
