# aup_kit_v8_kg — seal_v8 phase 3 (KeyGen in the PL) board kit. Human-run; not yet run on hardware.

Image: `wepwawet_sign_v8.bit/.hwh` = 05_RESULTS/sign_v8_300/phase3 (src 04_WORK/seal_v8/src_p3, SHA256SUMS_src_p3.txt).
VERSION 0x0003_0003, 300 MHz routed WNS +0.011 / WHS +0.010 ns, 0 routing errors, DRC warnings only,
44,787 LUT / 7,945 CLB (90.08 %), BITSTREAM.READBACK.SECURITY=Level2 (READBACK_SECURITY.txt).
Build-time test paths OFF in this exact build (KAT_XI_PROOF.txt): the Vivado-generated synthesis wrapper instantiates
`wepwawet_sign_axil #(... .DET_RND(0), .KAT_XI(0))` and the .hwh records DET_RND=0, KAT_XI=0. DET_RND is also visible at
run time (TRNG register bit 25, checked by K0).

## One command
    sudo bash run_board_test_v8kg.sh 20 I-UNDERSTAND-LEVEL2
No key file, no test key, no host key generation: K1 runs KEYGEN in the PL (xi from the RO TRNG path), the host only
reads pk = rho||t1. PASS = K0..K8 all pass (see the header of wcore_drv/wcore_selftest_v8kg.c), RESULT ... PASS.

## Known risk before you run it (honest)
- Simulation status of this image's RTL (src_p3): Verilator PASS (KeyGen KAT vs dilithium-py, sealed key bit-exact,
  sign-after-keygen == oracle; hedged KeyGen + hedged signs verify). XSim: KeyGen KAT PASS, but SIGN/VERIFY FAILED in XSim
  because XSim evaluated the new two-page ROM output one fetch late (root-caused by trace; fixed RTL = src_p3b, not built).
  Vivado synthesis follows the IEEE semantics that Verilator implements, so the bitstream is expected to behave like
  Verilator, but that is NOT proven. If the hardware behaved like XSim, K4 would fail (signatures not produced or not
  verifying): this is fail-closed -- the wrapper releases outputs only after a correct-PC HALT and scrubs everything else --
  so the risk is a failed test, not a key leak.
- The reviewer's root attack (aup_kit_v8/attack) does not support VERSION 0x0003_0003; the structural sweeps in K2/K5/K6
  are the root-read check here (key unknown to the host -> any non-zero word outside the released window fails).
- Level2: power-cycle before loading any other image. A PL reset/reload/ZEROIZE destroys the PL-generated key (by design).
