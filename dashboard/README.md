# WEPWAWET-CORE ground-station dashboard

Launch from the repository root, in its own PowerShell window:

```
powershell -ExecutionPolicy Bypass -File .\dashboard\wcore_dash.ps1
```

It opens http://localhost:8088/ . Stop with Ctrl+C (this also closes the live ssh sessions).

## Modes
- **REPLAY** (default, needs no boards): plays a recorded run from `results\mission_runs\<run>` on its real
  timestamps (speed 1–20×, click the timeline to seek). Runs whose `fsw.log` contains an F′ `Assert:` are
  marked **✖ CRASHED — excluded**. Bidirectional F′ exchanges (`node_*` folders in `results\board_logs`)
  are listed too. **COMPARE** puts two mission runs side by side; every metric is computed from the run files.
- **DUPLEX** (first group in the run picker): a run recorded on **both** boards under the same name
  (`results\board_logs\aup1|aup2\wepwawet-core\logs\mission_runs\<run>`, filled by `wcore.ps1 collect`).
  Two arcs are drawn: gold AUP1→AUP2, blue AUP2→AUP1. Each CubeSat panel shows its own signed and verified counters,
  core bars, ADCS and payload numbers from its own run folder. A frame's verdict colour comes from the
  **receiver's** verify records. Pairing (stated on screen): each PeerPing is synchronous, so a verify on the
  receiver is matched to the sender's latest earlier sign within 2.5 s; a constant clock difference between the
  boards is estimated only if more than 2% of verifies fail to pair at zero difference, and the value used is shown.
  The panel also states each board's sending window and how long both were sending at once.
- **Excluded runs**: `excluded_runs.json` lists runs excluded for a documented reason (regex `match`, `tag`,
  `reason`). They are tagged in the picker and show a banner, like crashed runs. Edit the file to add one.
- **LIVE**: starts one ssh per board (`xilinx@aup1`, `xilinx@aup2`) running `board_probe.sh`, which is
  read-only: it reads `/proc/stat`, new lines of `fprime_hw_stats.csv`, the process list, the newest run
  folder name and, every 10 s, MAGIC/VERSION via `~/aup_kit_v8_duplex/wcore_check` if present, else `~/aup_kit_v7/wcore_check` (only when sudo
  needs no password). The sealed design (VERSION 0x00030002/0x00030003) is recognised and its lock bit shown. It never starts, stops or writes anything on the boards. Leaving LIVE (or Ctrl+C) ends both sessions.

## Where each number comes from
| On screen | Source |
|---|---|
| Core bars | `cpu_util.csv` (replay, 1 Hz /proc/stat) or the probe (live) |
| Sign events, PL cycles, attempts, TRNG flash, sign time | `hw_stats_run.csv` (AUP1); live: `fprime_hw_stats.csv` |
| AUP2 verify verdict and cycles | AUP2 `fprime_hw_stats.csv`, run matched by time and count |
| ADCS jitter and misses | `adcs.csv` (replay only; written by the board at end of run) |
| Imager deadline misses | `payload.csv` (replay only) |
| F′ assert | `fsw.log` |
| Run parameters | `params.json`, `run_summary.json`, `payload.json` |

Time alignment (stated on screen under the crosslink panel): time zero is the first 1 Hz CPU sample minus
one second (±0.5 s); AUP1 sign times are mapped from the monotonic clock to wall clock through the F′ EVENT
timestamps in `fsw.log`; AUP2 verifies are placed through AUP1's mapping (both boards report the same uptime).
For bidirectional `node_*` runs the console log has no timestamp on sign/verify lines, so those events are
placed at the next F′ EVENT timestamp (an upper bound). Packet travel along the crosslink is drawn for
visibility; the verdict colour appears at the recorded verify time.

## Key custody, ground station and certificate lane (shown only from evidence)
- **Key badge on a CubeSat** (padlock on the PL chip + green line): shown only if that board's `fsw.log` holds
  "signing key SEALED in the PL" **and** `check_before.txt` shows `key SEALED` or VERSION 0x0003000x.
  Image 0x00030003 is labelled "key generated + sealed in fabric". A v7 fabric run shows "key provisioned by host",
  a CPU run "key in host memory". In LIVE the badge comes from the lock bit read by the probe.
- **Public-key file line** (centre panel): SHA-256 of `results\aupN_node_pk_v8.bin`, shown only when the file is
  older than the run. The `.bin` files themselves, `ground_sk.bin`, `identity` and `node_sk` are never served.
- **Certificate lane**: greyed with "no certificate exchange recorded for this run" unless evidence exists.
  Evidence = the console output of `wcore_cert_check` saved as `cert_check*.log` in one of
  `results\ground_ca\evidence\cert_check_<board>.log`,
  `board_logs\<board>\wepwawet-core\logs\cert_check*.log` (picked up by `wcore.ps1 collect`). Save it on the board with
  `{ date -u +"DATE_EPOCH %s"; sudo ./wcore_drv/wcore_cert_check ground_pk.bin AUP2 aup2_node_pk_v8.bin AUP2.cert --install; } | tee ~/wepwawet-core/logs/cert_check_$(hostname).log`.
  The lane lights only for a board whose run is sealed and whose check is dated before the run started
  (`DATE_EPOCH` line, else file time). It then replays once: public keys down, peer key + certificate up, and the
  recorded `CERT_CHECK` result with the verifier names. The exchange itself took place before the run; the screen says so.

## Files
`wcore_dash.ps1` server · `board_probe.sh` read-only live probe · `index.html`, `style.css`, `app.js`,
`data.js`, `cubesat.js` page · `excluded_runs.json` exclusion list · `assets/` logo · `test/serve_test.py` Linux test harness (same routes).

## Visual layer (motion only; never changes a number on screen)
- **Earth drift**: the Earth surface texture is decorative and drifts at a steady rate (follows playback speed, capped at 5×; steady in LIVE). The satellites do not spin: the ADCS holds pointing.
- **Sunlight / eclipse**: AUP1 shading follows the `sunlit` column of the run's `adcs.csv`. Boards or modes without an ADCS log (AUP2 receiver, LIVE) stay lit and are captioned "lighting: illustrative".
- **Attitude wobble**: AUP1 sways with amplitude = logged `point_err_deg` ×50, clamped at 4°, captioned on screen with the logged value. The direction of the sway is illustrative. Replay only.
