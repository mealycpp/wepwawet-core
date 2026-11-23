# MERGE_NOTES — seal_v8 phase 4
Base: `04_WORK/seal_v8/src_p2` (verified against `SHA256SUMS_src_p2.txt`, 94 files OK before copy). Work copy: `pin/src`.
Full unified diff: `pin/MERGE.diff` (`diff -ru src_p2 pin/src`). No change to the core, ROM, sequencer, retry manager,
TRNG filler, HLS IP or any `rtl/` file -> no overlap with the KeyGen/ROM-width work in `seal_v8/keygen/`.

## Files
| file | change |
|---|---|
| `src/wpin_gate.v` | **NEW** (287 lines): pin register (write-once) / hard-wired constant, dedicated Keccak-f[1600] (1 round/clk), FSM that hashes the verifier pk image, latches c~, optional PL mu = SHAKE256(TR_CONST‖M'), post-job c~'==c~ compare. |
| `src/wepwawet_sign_axil.v` | 12 hunks, all additive except 6 one-line edits (marked *edit*). |
| `tb/tb_pin.sv` | NEW TB (tb copies of p2 TBs are unchanged). |
| `tools/wpin_fp.py` | NEW provisioning tool: FP, PIN words, tr, `PIN_CONST`/`TR_CONST` hex. |
| `sim/build_any.sh`, `sim/vl_run_pin.sh`, `sim/rc_pin.sh`, `sim/regress_pin.sh` | sim scripts (copies/variants of `seal_v8/sim`, `~/vb/rc.sh`). |
| `vectors/` | trusted (=verify_v1 valid), attacker (=valid_vec3), mixed, bad_*, tamper_msg + `pins/`. |

## Hunks in `wepwawet_sign_axil.v` (line numbers = src_p2)
1. @53 header: phase-4 register map comment + `` `ifndef WPIN_*_DEFAULT`` macro defaults (MODE 2, ALLOW_UNSET 0, CONST 0, MU_PL 1, TR 0).
2. @121 module params: `PIN_MODE, PIN_ALLOW_UNSET, PIN_CONST[255:0], MU_PL, TR_CONST[511:0]` (after `DET_RND`).
3. @121 (after `reg [255:0] public_rho;`): phase-4 reg/wire declarations (`pin_job, pin_post, pg_*`, `msg_len_r`, verdict regs).
4. @135 *edit*: the three `h_wr_req_*` muxes get `: (pg_busy ? pg_wr_* : ps_wr_*)` in the `!running` arm (PL-mu write port).
5. @145 (after `host_mode` wire): `generate` block instantiating `wpin_gate` (or tie-offs when `PIN_MODE==0`).
6. @145 *edit*: core instance `.h_rd_req_valid/.h_rd_req_addr/.h_rd_rsp_ready` get `pg_busy ? pg_* :` muxes.
7. @193 *edit*: `eng_busy` += `|| pin_job`; `w_win_ok` += b2[1304..1535] (M' window, only `MU_PL && PIN_MODE`).
8. @220 *edit*: STATUS bit0 = `running | pin_job`.
9. @231 `reg_read`: 0xA0..0xBC PIN, 0xC0 PIN_STAT, 0xC4 VERDICT, 0xC8 PIN_CYC, 0xD0..0xEC FP, 0xF0 MSG_LEN.
10. @251/@279 reset values; per-cycle pulse clears; *edit*: `if (running || pin_job) cycles <= cycles + 1`.
11. @296 after the job-finished block: pin_job post-compare start / z-reject verdict; pre-done (launch core or fail-closed reject); post-done verdict.
12. @350 *edit*: LAUNCH: VERIFY with `PIN_MODE!=0` sets `pin_job` + `pg_start_pre` instead of `running/launch_p`; ZEROIZE guard `&& !pin_job`.
13. @372 register writes 0xA0..0xBC / 0xC0 / 0xF0 (SLVERR while busy).

## Merge hazards (read before merging)
- **CONFLICT with BUILDER `seal_v8/src` (seen 15:30 PT, file mtime 15:15 PT):** `src/wepwawet_sign_axil.v` already carries a
  different, ROM-based phase-4 (VERSION 0x0003_0004, `pin_rho`/`pin_dig` at 0x1_00C0..0x1_00FC, write-once *software* pin,
  `pin_armed` CTRL bit6, D' = SHAKE256(t1'_hat) landing at **b2[1310..1313]**, retry-manager `pin_mode/pin_cmp_req`).
  Same register addresses (0xC0..0xFC) and b2[1310..1313] lies inside this design's M' window b2[1304..1535]. The two cannot both
  go in; pick one design. This design differs in: anchor is a bitstream constant by default (software register = sim only), anchor
  covers rho AND t1'_hat in one digest, the hash is taken at LAUNCH before the core runs (no ROM/retry-manager change), PL-side
  c~'==c~ verdict, PL-side mu. If BUILDER's version is kept, at minimum port: hard-wired constant default, PL verdict, PL mu.
- VERSION register deliberately NOT bumped (p2 TBs check 0x0003_0002); bump at merge and update TBs.
- `build_sign_image_v8.tcl` (not touched): must set `CONFIG.PIN_MODE 2`, `CONFIG.PIN_ALLOW_UNSET 0`, `CONFIG.MU_PL 1`,
  `CONFIG.PIN_CONST`, `CONFIG.TR_CONST` from `tools/wpin_fp.py <peer pk.bin>` and abort if PIN_CONST == 0 (an unprovisioned
  build rejects every VERIFY — fail-closed but useless).
- M' window b2[1304..1535]: unused by the p2 Sign/Verify ROM (checked against `review/tools/p2wip_rom_listing.txt`); the KeyGen
  page (phase 3) must be checked against it. It is host-writable while LOCKED (public data) and zeroed by the post-SIGN scrub.
- Driver (`wcore_drv`) ABI change for VERIFY in board builds: write M' (= 0x00 ‖ |ctx| ‖ ctx ‖ M) to b2[1304..], MSG_LEN to
  0x1_00F0; the mu window is ignored; read VERDICT 0x1_00C4 (code 1 = accept) instead of comparing c~' itself.
