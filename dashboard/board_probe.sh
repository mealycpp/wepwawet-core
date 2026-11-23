#!/bin/bash
# WEPWAWET-CORE dashboard probe. READ-ONLY: reads /proc, the F' hw-stats CSV, process list,
# newest mission-run folder name, and (every 10 s, only if sudo needs no password) the FPGA
# MAGIC/VERSION registers via the existing wcore_check. Starts, stops and writes nothing.
# Prints one JSON line per second on stdout.
H=/home/xilinx/wepwawet-core/logs/fprime_hw_stats.csv
R=/home/xilinx/wepwawet-core/logs/mission_runs
CHK=/home/xilinx/aup_kit_v7/wcore_check
# sealed design (VERSION 0x0003000x): its own checker also reports the lock bit; reads registers only
[ -x /home/xilinx/aup_kit_v8_duplex/wcore_check ] && CHK=/home/xilinx/aup_kit_v8_duplex/wcore_check
n=$(wc -l < "$H" 2>/dev/null || echo 0)
prev=$(grep -E '^cpu[0-9]+ ' /proc/stat)
seq=0; img="not checked"
while :; do
  sleep 1; seq=$((seq+1))
  cur=$(grep -E '^cpu[0-9]+ ' /proc/stat)
  util=$(paste <(echo "$prev") <(echo "$cur") | awk '{n=NF/2; b0=0;b1=0; for(k=2;k<=n;k++){b0+=$k; b1+=$(k+n)}; i0=$5+$6; i1=$(5+n)+$(6+n); db=b1-b0; di=i1-i0; printf "%s%.1f", (NR>1?",":""), (db>0)?100*(db-di)/db:0}')
  prev="$cur"
  m=$(wc -l < "$H" 2>/dev/null || echo 0); ev=""
  if [ "$m" -gt "$n" ]; then ev=$(sed -n "$((n+1)),${m}p" "$H" | tail -n 60 | awk '{gsub(/["\\]/,""); printf "%s\"%s\"", (NR>1?",":""), $0}'); fi
  n=$m
  f=0; pgrep WepwawetDeploy >/dev/null && f=1
  a=0; pgrep -x adcs_load >/dev/null && a=1
  p=0; pgrep -x payload_load >/dev/null && p=1
  run=$(ls -td "$R"/*/ 2>/dev/null | head -1); run=$(basename "$run" 2>/dev/null)
  if [ $((seq % 10)) -eq 1 ]; then
    if [ -x "$CHK" ] && sudo -n true 2>/dev/null; then img=$(sudo -n env WCORE_CHECK_ALLOW_UNLOCKED=1 "$CHK" 2>/dev/null | head -1 | tr -d '"\\'); else img="not checked"; fi
  fi
  up=$(cut -d' ' -f1 /proc/uptime)
  printf '{"host":"%s","seq":%d,"epoch":%s,"uptime":%s,"cpu":[%s],"hw":[%s],"fsw":%d,"adcs":%d,"payload":%d,"run":"%s","img":"%s"}\n' \
    "$(hostname)" "$seq" "$(date +%s.%N)" "$up" "$util" "$ev" "$f" "$a" "$p" "$run" "$img"
done
