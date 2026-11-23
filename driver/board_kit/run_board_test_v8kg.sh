#!/bin/bash
# ONE-COMMAND seal_v8 PHASE-3 (KEYGEN IN THE PL) board test. Human-run.   sudo bash run_board_test_v8kg.sh 20 I-UNDERSTAND-LEVEL2
# !!! wepwawet_sign_v8.bit (phase 3) is built with BITSTREAM.READBACK.SECURITY=Level2: loading ANY other PL image afterwards
# !!! may fail until the board is POWER-CYCLED. No key file of any kind is used: the key is generated inside the PL.
set -u; K="$(cd "$(dirname "$0")" && pwd)"; N=${1:-20}; TS=$(date +%Y%m%d_%H%M%S)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
if [ "${2:-}" != "I-UNDERSTAND-LEVEL2" ]; then
  echo "REFUSING: Level2 readback security; loading another PL image may need a power cycle afterwards."
  echo "Re-run as: sudo bash $0 ${N} I-UNDERSTAND-LEVEL2"; exit 3; fi
L=$K/logs_$TS; mkdir -p $L; cd $K
echo "== 0 sha256" | tee $L/summary.txt
sha256sum -c SHA256SUMS.txt > $L/sha256.txt 2>&1 && echo "SHA256 OK" | tee -a $L/summary.txt || { echo "SHA256 FAIL" | tee -a $L/summary.txt; exit 1; }
cat KAT_XI_PROOF.txt >> $L/summary.txt
echo "== 1 load" | tee -a $L/summary.txt; bash $K/load_v8.sh > $L/load.txt 2>&1; tail -1 $L/load.txt | tee -a $L/summary.txt
$K/wcore_check_v8 | grep -q "VERSION=0x00030003" || { echo "ABORT: phase-3 image (VERSION 0x00030003) not alive" | tee -a $L/summary.txt; exit 1; }
echo "== 2 build" | tee -a $L/summary.txt
bash $K/wcore_drv/build_selftest_v8kg.sh > $L/build.txt 2>&1 && echo "build OK" | tee -a $L/summary.txt || { echo "build FAIL (see $L/build.txt)" | tee -a $L/summary.txt; exit 1; }
echo "== 3 selftest (PL KeyGen)" | tee -a $L/summary.txt
( cd $L && $K/wcore_drv/wcore_selftest_v8kg $N 100 ) > $L/selftest.txt 2>&1; R3=$?
grep -E "^K[0-9]|^sweep|RESULT|  pk. sig" $L/selftest.txt | tee -a $L/summary.txt
$K/wcore_drv/wcore_provision --zeroize >> $L/summary.txt 2>&1
echo "== RESULT selftest_rc=$R3 -> $([ $R3 = 0 ] && echo PASS || echo FAIL)" | tee -a $L/summary.txt
echo "logs: $L"
