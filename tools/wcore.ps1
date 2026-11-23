# WEPWAWET-CORE control from ONE PowerShell window (drives AUP1 + AUP2 over ssh; keeps them in sync).
# Usage (from <WORKDIR>):
#   .\wcore.ps1 sync                         # copy mission_kit + aup_kit_v7 updates to both boards
#   .\wcore.ps1 status                       # FPGA image + running F' on both boards
#   .\wcore.ps1 run <cpu|fpga> <rate> <load> <seconds> [tag]   # AUP2 receiver, then one loaded run on AUP1
#   .\wcore.ps1 sweep [seconds] [repeats]    # baseline + fabric/CPU at 5 and 10 frames/s, load 4, alternating
#   .\wcore.ps1 final [seconds] [repeats] # FINAL: imager-derived load; base, fabric, CPU, CPU-RT70, unpinned fabric/CPU
#   .\wcore.ps1 duplex [fpga|cpu] [s] [rate]  # both boards loaded AND signing to each other at once
#   .\wcore.ps1 selftest [N]                 # clean standalone v7 self-test on both boards, output saved to logs
#   .\wcore.ps1 idletest                     # stall hypothesis: deep CPU idle off on AUP1, 3 no-crypto + 1 CPU run, then restore
#   .\wcore.ps1 v8test [aup1|aup2] [N]       # v8 seal board test (Level2: power-cycle needed to go back to v7)
#   .\wcore.ps1 analyze                      # build the comparison table on AUP1 and copy all runs here
#   .\wcore.ps1 fixfsw                       # rebuild F' with the PqcTransport queue fix (AUP1 build, same binary to AUP2)
#   .\wcore.ps1 collect                      # pull every experiment log from both boards into 05_RESULTS\board_logs
#   .\wcore.ps1 stop                         # stop everything on both boards
param([string]$Action = "status", [string]$A1 = "", [string]$A2 = "", [string]$A3 = "", [string]$A4 = "", [string]$A5 = "")
$ErrorActionPreference = "Continue"
$OtherPlServices = @()   # services that own the PL and must be stopped first
$R = "<WORKDIR>\05_RESULTS"
$PAYLOAD_RATE = 8
function On($h, $cmd) { Write-Host "[$h] $cmd" -ForegroundColor Cyan; ssh -t "xilinx@$h" $cmd }
function Receiver { On aup2 "sudo bash ~/mission_kit/harness/mission_run.sh stop; sudo bash ~/mission_kit/harness/mission_run.sh receiver" }
function OneRun($b, $rate, $load, $secs, $tag, $envs = "") {
  On aup1 "sudo bash ~/mission_kit/harness/mission_run.sh stop >/dev/null; sudo PAYLOAD_RATE=$PAYLOAD_RATE $envs bash ~/mission_kit/harness/mission_run.sh $b $rate $load $secs $tag | tail -40; R=`$(ls -td /home/xilinx/wepwawet-core/logs/mission_runs/*_${b}_r${rate}_L${load}*_${tag} | head -1); echo ADCS: `$(cat `$R/adcs.json); echo PAYLOAD: `$(cat `$R/payload.json)"
}
switch ($Action) {
  "sync" {
    foreach ($h in "aup1","aup2") {
      scp -r "$R\mission_kit\harness" "$R\mission_kit\adcs" "xilinx@${h}:~/mission_kit/"
      scp "$R\mission_kit\payload\payload_load.c" "xilinx@${h}:~/mission_kit/payload/"
      scp "$R\aup_kit_v7\wcore_node.sh" "xilinx@${h}:~/aup_kit_v7/"
      On $h "cd ~/mission_kit/adcs && bash build_adcs.sh >/dev/null && cd ../payload && bash build_payload.sh | tail -1 && grep -c setvbuf ../adcs/adcs_load.c payload_load.c"
    }
  }
  "status" { foreach ($h in "aup1","aup2") { On $h "cd ~/aup_kit_v7 && ([ -x wcore_check ] || gcc -O2 -o wcore_check wcore_check.c) && sudo ./wcore_check; pgrep -fa WepwawetDeployment | head -2; systemctl is-active $($OtherPlServices -join ' ') 2>/dev/null | tr '\n' ' '; echo" } }
  "stop"   { foreach ($h in "aup1","aup2") { On $h "sudo bash ~/mission_kit/harness/mission_run.sh stop; sudo bash ~/aup_kit_v7/wcore_node.sh stop" } }
  "run"    { Receiver; OneRun $A1 $A2 $A3 $A4 $A5 }
  "sweep"  {
    $secs = if ($A1) { $A1 } else { 60 }; $reps = if ($A2) { [int]$A2 } else { 3 }
    Receiver
    for ($k = 1; $k -le $reps; $k++) {
      OneRun fpga 0 4 $secs "base$k"
      foreach ($rate in 5, 10) {
        if ($k % 2) { OneRun fpga $rate 4 $secs "rep$k"; OneRun cpu $rate 4 $secs "rep$k" }
        else        { OneRun cpu  $rate 4 $secs "rep$k"; OneRun fpga $rate 4 $secs "rep$k" }
      }
    }
    & $PSCommandPath analyze
  }
  "final" {
    # FINAL sweep. Payload = imaging pass of a MultiScape100-class push-broom imager at 500 km
    # (4084 px x 7 bands, GSD 4.75 m, 16-bit words): 7.06 km/s / 4.75 m = 1487 lines/s -> 85.0 MB/s raw
    # -> 40.5 tiles/s of 2 MiB -> 13.5 tiles/s per payload thread (3 threads). Crosslink: 10 signed frames/s.
    $script:PAYLOAD_RATE = 13.5
    $secs = if ($A1) { $A1 } else { 60 }; $reps = if ($A2) { [int]$A2 } else { 3 }
    Receiver
    for ($k = 1; $k -le $reps; $k++) {
      OneRun fpga 0 4 $secs "fbase$k"
      $cfgs = @(@("fpga",""), @("cpu",""), @("cpu","SIGNER_PRIO=70"), @("fpga","PINNING=none"), @("cpu","PINNING=none"))
      if ($k % 2 -eq 0) { [array]::Reverse($cfgs) }
      foreach ($c in $cfgs) { OneRun $c[0] 10 4 $secs "f$k" $c[1] }
    }
    & $PSCommandPath analyze
  }
  "duplex" {
    # BOTH spacecraft loaded and signing to each other at the same time (each also verifies the other's frames).
    # Usage: .\wcore.ps1 duplex [backend fpga|cpu] [seconds] [rate]
    $b = if ($A1) { $A1 } else { "fpga" }; $secs = if ($A2) { $A2 } else { 60 }; $rate = if ($A3) { $A3 } else { 10 }
    $tag = "duplex"
    foreach ($h in "aup1","aup2") { ssh "xilinx@$h" "sudo bash ~/mission_kit/harness/mission_run.sh stop" | Out-Null }
    Write-Host "starting $b duplex on both boards ($rate frames/s each way, $secs s, imager load)" -ForegroundColor Cyan
    $jobs = foreach ($h in "aup1","aup2") {
      Start-Job -ScriptBlock { param($h,$b,$rate,$secs,$tag)
        ssh "xilinx@$h" "sudo PAYLOAD_RATE=13.5 bash ~/mission_kit/harness/mission_run.sh $b $rate 4 $secs $tag | tail -30"
      } -ArgumentList $h,$b,$rate,$secs,$tag
    }
    $jobs | Wait-Job | Out-Null
    $i = 0; foreach ($h in "aup1","aup2") { Write-Host "===== $h" -ForegroundColor Green; Receive-Job $jobs[$i]; $i++ }
    $jobs | Remove-Job
  }
  "selftest" {
    # clean standalone v7 run, output SAVED to the board log folder (evidence for the paper)
    $n = if ($A1) { $A1 } else { 2000 }
    foreach ($h in "aup1","aup2") {
      On $h "sudo bash ~/mission_kit/harness/mission_run.sh stop"
      On $h "cd ~/aup_kit_v7/wcore_drv && ([ -x wcore_selftest ] || bash build_selftest.sh >/dev/null) && sudo ~/aup_kit_v7/wcore_check && L=~/wepwawet-core/logs/selftest_v7_`$(hostname)_`$(date +%Y%m%d_%H%M%S).log && { echo IMAGE: `$(sudo ~/aup_kit_v7/wcore_check); sha256sum ~/aup_kit_v7/wepwawet_sign_v7.bit; sudo ./wcore_selftest $n 100; } 2>&1 | tee `$L | tail -12; echo SAVED `$L"
    }
  }
  "idletest" {
    # Hypothesis test for the multi-second RT stalls: disable deep CPU idle states on AUP1 (reverted at the end;
    # a reboot also reverts), then run no-crypto baselines + one CPU run. Prior: 2 of 3 no-crypto runs stalled >= 4 s.
    $script:PAYLOAD_RATE = 13.5
    Receiver
    On aup1 "echo BEFORE; for c in /sys/devices/system/cpu/cpu[0-3]/cpuidle/state*; do echo `$c `$(cat `$c/name 2>/dev/null) disable=`$(cat `$c/disable 2>/dev/null) usage=`$(cat `$c/usage 2>/dev/null); done; cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null; for f in /sys/devices/system/cpu/cpu[0-3]/cpuidle/state[1-9]/disable; do [ -f `$f ] && echo 1 | sudo tee `$f >/dev/null; done; echo AFTER; grep -H . /sys/devices/system/cpu/cpu[0-3]/cpuidle/state*/disable 2>/dev/null"
    for ($k = 1; $k -le 3; $k++) { OneRun fpga 0 4 60 "idleoff_base$k" }
    OneRun cpu 10 4 60 "idleoff_cpu1"
    On aup1 "for f in /sys/devices/system/cpu/cpu[0-3]/cpuidle/state[1-9]/disable; do [ -f `$f ] && echo 0 | sudo tee `$f >/dev/null; done; echo RESTORED; grep -H . /sys/devices/system/cpu/cpu[0-3]/cpuidle/state*/disable 2>/dev/null"
  }
  "v8test" {
    # v8 phase-2r board test on ONE board (default aup2). Level2 readback security: after this, loading another PL
    # image on that board may need a power cycle.
    $h = if ($A1) { $A1 } else { "aup2" }; $n = if ($A2) { $A2 } else { 50 }
    On $h "sudo bash ~/mission_kit/harness/mission_run.sh stop >/dev/null 2>&1; sudo rm -rf ~/aup_kit_v8; echo stopped"
    scp -r -q "$R\aup_kit_v8" "xilinx@${h}:~/aup_kit_v8"
    On $h "cd ~/aup_kit_v8 && sudo bash run_board_test_v8.sh $n I-UNDERSTAND-LEVEL2"
  }
  "v8install" {
    # steps 1-3: copy the duplex kit to both boards, build the sealed F' on AUP1, install the same binary on AUP2
    foreach ($h in "aup1","aup2") {
      On $h "sudo bash ~/mission_kit/harness/mission_run.sh stop >/dev/null 2>&1; sudo rm -rf ~/aup_kit_v8_duplex; echo cleared"
      scp -r -q "$R\aup_kit_v8_duplex" "xilinx@${h}:~/aup_kit_v8_duplex"
      On $h "cd ~/aup_kit_v8_duplex && sha256sum -c SHA256SUMS.txt | grep -v ': OK' ; echo SHA_DONE"
    }
    On aup1 "bash ~/aup_kit_v8_duplex/install_fsw_v8_aup1.sh"
    scp "xilinx@aup1:/tmp/WepwawetDeployment.v8sealed" "$R\WepwawetDeployment.v8sealed"
    scp "$R\WepwawetDeployment.v8sealed" "xilinx@aup2:/tmp/WepwawetDeployment.v8sealed"
    On aup2 "bash ~/aup_kit_v8_duplex/install_fsw_v8_bin.sh"
  }
  "v8prep" {
    # steps 4-5: load the KeyGen image if needed, generate the key IN THE FABRIC on each board, exchange PUBLIC keys
    foreach ($h in "aup1","aup2") { On $h "sudo bash ~/aup_kit_v8_duplex/node_prep_v8.sh I-UNDERSTAND-LEVEL2" }
    foreach ($h in "aup1","aup2") { scp "xilinx@${h}:/home/xilinx/wepwawet-core/firmware/identity/node_pk.bin" "$R\${h}_node_pk_v8.bin" }
    # install via /tmp + sudo: the certificate step leaves trusted_peer_pk.bin owned by root, so a plain scp cannot overwrite it
    scp "$R\aup1_node_pk_v8.bin" "xilinx@aup2:/tmp/peer_pk_new.bin"
    scp "$R\aup2_node_pk_v8.bin" "xilinx@aup1:/tmp/peer_pk_new.bin"
    foreach ($h in "aup1","aup2") { On $h "sudo install -m 644 -o xilinx -g xilinx /tmp/peer_pk_new.bin /home/xilinx/wepwawet-core/firmware/identity/trusted_peer_pk.bin && echo PEER_KEY_INSTALLED" }
    foreach ($h in "aup1","aup2") { On $h "sha256sum ~/wepwawet-core/firmware/identity/node_pk.bin ~/wepwawet-core/firmware/identity/trusted_peer_pk.bin; ls ~/wepwawet-core/firmware/identity/" }
  }
  "v8smoke" {
    On aup2 "sudo KIT=/home/xilinx/aup_kit_v8_duplex bash ~/mission_kit/harness/mission_run.sh receiver"
    On aup1 "sudo KIT=/home/xilinx/aup_kit_v8_duplex bash ~/mission_kit/harness/mission_run.sh fpga 2 0 20 smokev8 | tail -32; grep -a -m2 'seal_v8' `$(ls -td /home/xilinx/wepwawet-core/logs/mission_runs/*smokev8 | head -1)/fsw.log"
    On aup2 "grep -a -c 'verdict=ACCEPT' `$(ls -td /home/xilinx/wepwawet-core/logs/mission_receiver_* | head -1)/fsw.log; grep -a -c 'verdict=REJECT' `$(ls -td /home/xilinx/wepwawet-core/logs/mission_receiver_* | head -1)/fsw.log; sudo bash ~/mission_kit/harness/mission_run.sh stop"
  }
  "v8duplex" {
    $secs = if ($A1) { $A1 } else { 60 }; $rate = if ($A2) { $A2 } else { 10 }; $tag = if ($A3) { $A3 } else { "duplexv8" }
    foreach ($h in "aup1","aup2") { ssh "xilinx@$h" "sudo bash ~/mission_kit/harness/mission_run.sh stop" | Out-Null }
    Write-Host "v8 duplex: both boards loaded, $rate frames/s each way, $secs s, keys sealed in the fabric" -ForegroundColor Cyan
    $jobs = foreach ($h in "aup1","aup2") { Start-Job -ScriptBlock { param($h,$rate,$secs,$tag) ssh "xilinx@$h" "sudo KIT=/home/xilinx/aup_kit_v8_duplex PAYLOAD_RATE=13.5 bash ~/mission_kit/harness/mission_run.sh fpga $rate 4 $secs $tag | tail -30" } -ArgumentList $h,$rate,$secs,$tag }
    $jobs | Wait-Job | Out-Null; $i = 0; foreach ($h in "aup1","aup2") { Write-Host "===== $h" -ForegroundColor Green; Receive-Job $jobs[$i]; $i++ }; $jobs | Remove-Job
    foreach ($h in "aup1","aup2") { On $h "D=`$(ls -td /home/xilinx/wepwawet-core/logs/mission_runs/*_$tag | head -1); echo `$D; grep -a -c 'verdict=ACCEPT' `$D/fsw.log; grep -a -c 'verdict=REJECT' `$D/fsw.log; grep -a -c 'Assert' `$D/fsw.log; ls ~/wepwawet-core/firmware/identity/ | tr '\n' ' '" }
  }
  "v8cert" {
    # ground-issued certificates: each board checks the PEER's pk + certificate (fabric verifier and CPU) and installs it; output saved as evidence
    scp "$R\aup2_node_pk_v8.bin" "$R\ground_ca\AUP2.cert" "xilinx@aup1:~/aup_kit_v8_duplex/"
    scp "$R\aup1_node_pk_v8.bin" "$R\ground_ca\AUP1.cert" "xilinx@aup2:~/aup_kit_v8_duplex/"
    $pairs = @(@("aup1","AUP2","aup2"), @("aup2","AUP1","aup1"))
    foreach ($x in $pairs) { $h=$x[0]; $peer=$x[1]; $pf=$x[2]
      On $h "sudo bash ~/mission_kit/harness/mission_run.sh stop >/dev/null 2>&1; cd ~/aup_kit_v8_duplex && bash wcore_drv/build_cert_check.sh >/dev/null && { date -u +'DATE_EPOCH %s'; sudo ./wcore_drv/wcore_cert_check ground_pk.bin $peer ${pf}_node_pk_v8.bin ${peer}.cert --install; } 2>&1 | tee ~/wepwawet-core/logs/cert_check_`$(hostname).log; sudo ~/aup_kit_v8_duplex/wcore_check"
    }
  }
  "v8fab" {
    # fabric rows of the comparison table on the SEALED image: AUP2 receives, AUP1 sends under full load (same as "final" fabric runs)
    $script:PAYLOAD_RATE = 13.5; $kitenv = "KIT=/home/xilinx/aup_kit_v8_duplex"
    $reps = if ($A1) { [int]$A1 } else { 3 }
    On aup2 "sudo bash ~/mission_kit/harness/mission_run.sh stop; sudo $kitenv bash ~/mission_kit/harness/mission_run.sh receiver"
    for ($k = 1; $k -le $reps; $k++) { OneRun fpga 10 4 60 "v8f$k" $kitenv }
    On aup2 "D=`$(ls -td /home/xilinx/wepwawet-core/logs/mission_receiver_* | head -1); grep -a -c 'verdict=ACCEPT' `$D/fsw.log; grep -a -c 'verdict=REJECT' `$D/fsw.log; sudo bash ~/mission_kit/harness/mission_run.sh stop"
  }
  "v8base" {
    # no-crypto baseline in the same session as the sealed-image fabric rows (image stays loaded and sealed)
    $script:PAYLOAD_RATE = 13.5; $kitenv = "KIT=/home/xilinx/aup_kit_v8_duplex"
    $reps = if ($A1) { [int]$A1 } else { 3 }
    for ($k = 1; $k -le $reps; $k++) { OneRun fpga 0 4 60 "v8base$k" $kitenv }
  }
  "v8selftest" {
    # N hedged signatures on the sealed KeyGen image, each verified with PQClean, on both boards; output saved. REGENERATES the keys.
    $n = if ($A1) { $A1 } else { 2000 }
    foreach ($h in "aup1","aup2") {
      On $h "sudo bash ~/mission_kit/harness/mission_run.sh stop >/dev/null 2>&1; sudo rm -rf ~/aup_kit_v8_kg; echo cleared"
      scp -r -q "$R\aup_kit_v8_kg" "xilinx@${h}:~/aup_kit_v8_kg"
      On $h "cd ~/aup_kit_v8_kg && sudo bash run_board_test_v8kg.sh $n I-UNDERSTAND-LEVEL2 2>&1 | tee ~/wepwawet-core/logs/selftest_v8kg_`$(hostname)_`$(date +%Y%m%d_%H%M%S).log | grep -v '  pk[12] sig' | tail -25"
    }
  }
  "analyze" {
    On aup1 "sudo python3 ~/mission_kit/harness/analyze.py /home/xilinx/wepwawet-core/logs/mission_runs"
    New-Item -ItemType Directory -Force -Path "$R\mission_runs" | Out-Null
    scp -r "xilinx@aup1:/home/xilinx/wepwawet-core/logs/mission_runs/*" "$R\mission_runs\"
    Write-Host "runs copied to $R\mission_runs" -ForegroundColor Green
  }
  "fixfsw" {
    # rebuild F' on AUP1 with the PqcTransport queue fix, then copy the same binary to AUP2
    scp "$R\mission_kit\harness\fix_fsw_queue.sh" "$R\mission_kit\harness\mission_run.sh" "xilinx@aup1:~/mission_kit/harness/"
    scp "$R\mission_kit\harness\mission_run.sh" "xilinx@aup2:~/mission_kit/harness/"
    On aup1 "sudo bash ~/mission_kit/harness/mission_run.sh stop >/dev/null 2>&1; bash ~/mission_kit/harness/fix_fsw_queue.sh"
    scp "xilinx@aup1:/tmp/WepwawetDeployment.queuefix" "$R\WepwawetDeployment.queuefix"
    scp "$R\WepwawetDeployment.queuefix" "xilinx@aup2:/tmp/WepwawetDeployment.queuefix"
    scp "$R\mission_kit\harness\install_queuefix_bin.sh" "xilinx@aup2:~/mission_kit/harness/"
    On aup2 "sudo bash ~/mission_kit/harness/mission_run.sh stop"
    On aup2 "bash ~/mission_kit/harness/install_queuefix_bin.sh"
  }
  "fixaup2" {
    # AUP2 half of fixfsw only (stop is a separate ssh call: its pkill -f would match a combined command line)
    scp "$R\WepwawetDeployment.queuefix" "xilinx@aup2:/tmp/WepwawetDeployment.queuefix"
    scp "$R\mission_kit\harness\install_queuefix_bin.sh" "xilinx@aup2:~/mission_kit/harness/"
    On aup2 "sudo bash ~/mission_kit/harness/mission_run.sh stop"
    On aup2 "bash ~/mission_kit/harness/install_queuefix_bin.sh"
  }
  "collect" {
    # pull ALL experiment logs from both boards into 05_RESULTS\board_logs\<board>\ (no keys, no core dumps)
    $stamp = Get-Date -Format "yyyyMMdd_HHmm"
    foreach ($h in "aup1","aup2") {
      $d = "$R\board_logs\$h"; New-Item -ItemType Directory -Force -Path $d | Out-Null
      On $h "sudo dmesg -T > ~/wepwawet-core/logs/dmesg_`$(date +%Y%m%d_%H%M%S).txt 2>&1; cat /proc/sys/kernel/sched_rt_runtime_us /proc/sys/kernel/sched_rt_period_us > ~/wepwawet-core/logs/rt_sched_params.txt; uname -a >> ~/wepwawet-core/logs/rt_sched_params.txt"
      On $h "cd ~ && tar czf /tmp/wcore_logs_$h.tgz --exclude='core*' --exclude='*.bin' --exclude='identity' wepwawet-core/logs `$(ls -d aup_kit_v*/*.log mission_kit/*/*.log 2>/dev/null) 2>/dev/null; ls -la /tmp/wcore_logs_$h.tgz"
      scp "xilinx@${h}:/tmp/wcore_logs_$h.tgz" "$d\logs_$stamp.tgz"
      tar -xzf "$d\logs_$stamp.tgz" -C $d
    }
    Write-Host "logs in $R\board_logs\aup1 and aup2 (snapshot $stamp)" -ForegroundColor Green
  }
  default { Get-Content $PSCommandPath | Select-Object -First 16 }
}
