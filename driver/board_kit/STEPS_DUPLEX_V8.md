# STEPS_DUPLEX_V8 — two-board F′ duplex on the sealed design (seal_v8 phase 3: key generated IN THE PL)
Delivered: the **phase-3 KeyGen path** (image 05_RESULTS/sign_v8_300/phase3, VERSION 0x0003_0003, KAT_XI=0/DET_RND=0
proven in KAT_XI_PROOF.txt; KeyGen board test aup_kit_v8_kg PASSED on AUP2). No node_sk.bin is used or opened anywhere.
Fallback if anything below fails at step 4/5: phase 2r + provision-once (aup_kit_v8, wcore_provision) — not needed by
these steps. Everything is run from ONE PowerShell window on the PC.

!!! Level2 readback security: once this image is loaded, loading another PL image (v7) may need a POWER CYCLE.
!!! Every PL load/reset destroys the sealed key -> redo steps 4–6 (new pk each time; the peers must re-exchange).
!!! sudo pitfalls (bit us twice): sudo sets HOME=/root and strips the XRT/PYNQ env. All scripts here use absolute
    /home/xilinx paths and source /etc/profile.d/{xrt_setup,pynq_venv}.sh themselves; pass env vars INSIDE sudo
    (`sudo KIT=... bash ...`), never `KIT=... sudo ...`. Build F′ as xilinx (no sudo).

## 1. Copy the kit to both boards
    $R="<WORKDIR>\05_RESULTS"
    foreach ($h in "aup1","aup2") { ssh "xilinx@$h" "rm -rf ~/aup_kit_v8_duplex" }    # board-side kit copy only (scp -r would nest)
    scp -r -q "$R\aup_kit_v8_duplex" "xilinx@aup1:~/aup_kit_v8_duplex"
    scp -r -q "$R\aup_kit_v8_duplex" "xilinx@aup2:~/aup_kit_v8_duplex"
    ssh xilinx@aup1 "cd ~/aup_kit_v8_duplex && sha256sum -c SHA256SUMS.txt | grep -v ': OK' ; echo SHA_DONE"
    ssh xilinx@aup2 "cd ~/aup_kit_v8_duplex && sha256sum -c SHA256SUMS.txt | grep -v ': OK' ; echo SHA_DONE"
(SHA_DONE with no other line = all files intact.)

## 2. Build the sealed F′ on AUP1 (has the build tree; keeps the queue fix; backs everything up)
    ssh xilinx@aup1 "bash ~/aup_kit_v8_duplex/install_fsw_v8_aup1.sh"
Expect: `binary contains the seal_v8 HwAccelMgr` and `INSTALLED seal_v8 F' on aup1`. It aborts (nothing changed) if the
queue fix is missing (run mission_kit/harness/fix_fsw_queue.sh first) or if the PqcTransport patch does not apply.

## 3. Copy the binary to AUP2 (no build tree there) and install it
    scp "xilinx@aup1:/tmp/WepwawetDeployment.v8sealed" "$R\WepwawetDeployment.v8sealed"
    scp "$R\WepwawetDeployment.v8sealed" "xilinx@aup2:/tmp/WepwawetDeployment.v8sealed"
    ssh xilinx@aup2 "bash ~/aup_kit_v8_duplex/install_fsw_v8_bin.sh"
(The same binary still works on a v7 image: HwAccelMgr selects the v7 path by VERSION.)

## 4. Per board: load the phase-3 image (if needed) + KEYGEN in the PL (backs up identity/, MOVES node_sk.bin away)
    ssh -t xilinx@aup1 "sudo bash ~/aup_kit_v8_duplex/node_prep_v8.sh I-UNDERSTAND-LEVEL2"
    ssh -t xilinx@aup2 "sudo bash ~/aup_kit_v8_duplex/node_prep_v8.sh I-UNDERSTAND-LEVEL2"
Expect per board: `WCORE_KEYGEN rc=0 ... status=0x0000840e`, the pk fingerprint, and
`WCORE_CHECK ... locked=1 ... -> v8 ALIVE, key SEALED`. Backups: ~/wepwawet-core/firmware/identity/backup_<ts>/.
Record both fingerprints.

## 5. Exchange public keys (PC): each board's node_pk.bin becomes the other's trusted_peer_pk.bin
    scp "xilinx@aup1:/home/xilinx/wepwawet-core/firmware/identity/node_pk.bin" "$R\aup1_node_pk_v8.bin"
    scp "xilinx@aup2:/home/xilinx/wepwawet-core/firmware/identity/node_pk.bin" "$R\aup2_node_pk_v8.bin"
    scp "$R\aup1_node_pk_v8.bin" "xilinx@aup2:/home/xilinx/wepwawet-core/firmware/identity/trusted_peer_pk.bin"
    scp "$R\aup2_node_pk_v8.bin" "xilinx@aup1:/home/xilinx/wepwawet-core/firmware/identity/trusted_peer_pk.bin"
    ssh xilinx@aup1 "sha256sum ~/wepwawet-core/firmware/identity/{node_pk,trusted_peer_pk}.bin"
    ssh xilinx@aup2 "sha256sum ~/wepwawet-core/firmware/identity/{node_pk,trusted_peer_pk}.bin"
Check crosswise: aup1 node_pk == aup2 trusted_peer_pk and vice versa. (The previous trusted_peer_pk.bin of each board is in
its backup_<ts>/ from step 4.) The pk files are PUBLIC; nothing secret crosses the network.

## 6. Smoke test, then the duplex mission run (mission_run.sh unchanged; KIT points to this kit)
    ssh xilinx@aup2 "sudo KIT=/home/xilinx/aup_kit_v8_duplex bash ~/mission_kit/harness/mission_run.sh receiver"
    ssh xilinx@aup1 "sudo KIT=/home/xilinx/aup_kit_v8_duplex bash ~/mission_kit/harness/mission_run.sh fpga 2 0 20 smokev8"
    ssh xilinx@aup2 "sudo bash ~/mission_kit/harness/mission_run.sh stop"
Smoke expectation: run_summary sign.ok == done, peer_accepted > 0, hw_errors 0; AUP1 fsw.log contains
`WCORE: seal_v8 image: signing key SEALED in the PL; sk is never passed to the driver`. Then the duplex (both senders,
each verifies the other), exactly like `wcore.ps1 duplex` with KIT set:
    foreach ($h in "aup1","aup2") { ssh "xilinx@$h" "sudo bash ~/mission_kit/harness/mission_run.sh stop" | Out-Null }
    $jobs = foreach ($h in "aup1","aup2") { Start-Job -ScriptBlock { param($h) ssh "xilinx@$h" "sudo KIT=/home/xilinx/aup_kit_v8_duplex PAYLOAD_RATE=13.5 bash ~/mission_kit/harness/mission_run.sh fpga 10 4 60 duplexv8 | tail -30" } -ArgumentList $h }
    $jobs | Wait-Job | Receive-Job; $jobs | Remove-Job
    scp -r "xilinx@aup1:/home/xilinx/wepwawet-core/logs/mission_runs/*duplexv8*" "$R\mission_runs\"
    scp -r "xilinx@aup2:/home/xilinx/wepwawet-core/logs/mission_runs/*duplexv8*" "$R\mission_runs\"
hw_stats CSV format is unchanged (backend label `fpga`, same 12 fields), so tools/final_analysis.py works as before.

## 7. Evidence that no secret key file is used (per board)
    ssh xilinx@aup1 "ls -la ~/wepwawet-core/firmware/identity/ ; grep -a 'seal_v8\|HwAccelMgr backend' ~/wepwawet-core/logs/mission_runs/*duplexv8*/fsw.log | head -3"
node_sk.bin must be absent from identity/ (it sits in backup_<ts>/, untouched by F′; for a pure-KeyGen identity it is
not needed at all). Optional: `sudo strace -f -e trace=openat -p <F' pid> 2>&1 | grep node_sk` during a run shows nothing.

## 8. Back to v7 afterwards
Power-cycle the board (Level2), restore identity files from backup_<ts>/ (node_sk.bin, node_pk.bin, trusted_peer_pk.bin),
load the v7 image as before. The seal_v8 F′ binary keeps working on v7 (v7 path by VERSION; it then needs node_sk.bin).

## Lines for wcore.ps1
    "v8duplexprep" {
      foreach ($h in "aup1","aup2") { On $h "sudo bash ~/aup_kit_v8_duplex/node_prep_v8.sh I-UNDERSTAND-LEVEL2" }
      foreach ($h in "aup1","aup2") { scp "xilinx@${h}:/home/xilinx/wepwawet-core/firmware/identity/node_pk.bin" "$R\${h}_node_pk_v8.bin" }
      scp "$R\aup1_node_pk_v8.bin" "xilinx@aup2:/home/xilinx/wepwawet-core/firmware/identity/trusted_peer_pk.bin"
      scp "$R\aup2_node_pk_v8.bin" "xilinx@aup1:/home/xilinx/wepwawet-core/firmware/identity/trusted_peer_pk.bin"
    }
    "v8duplex" {
      $secs = if ($A1) { $A1 } else { 60 }; $rate = if ($A2) { $A2 } else { 10 }
      foreach ($h in "aup1","aup2") { ssh "xilinx@$h" "sudo bash ~/mission_kit/harness/mission_run.sh stop" | Out-Null }
      $jobs = foreach ($h in "aup1","aup2") { Start-Job -ScriptBlock { param($h,$rate,$secs) ssh "xilinx@$h" "sudo KIT=/home/xilinx/aup_kit_v8_duplex PAYLOAD_RATE=13.5 bash ~/mission_kit/harness/mission_run.sh fpga $rate 4 $secs duplexv8 | tail -30" } -ArgumentList $h,$rate,$secs }
      $jobs | Wait-Job | Out-Null; $i = 0; foreach ($h in "aup1","aup2") { Write-Host "===== $h" -ForegroundColor Green; Receive-Job $jobs[$i]; $i++ }; $jobs | Remove-Job
    }

## What this run demonstrates / does not
Demonstrates: F′ on both nodes signs every crosslink frame with an ML-DSA-44 key that was generated inside the PL and is
never present in PS memory, files or the F′ process; frames are verified by the peer (FPGA verify) under a public key
exported by the PL. Does not: protect against root using the signing service (oracle), replacing trusted_peer_pk.bin
(host file; the root-resistant anchor is the bitstream-constant pin, simulation only), PL reload/DoS, side channels.
