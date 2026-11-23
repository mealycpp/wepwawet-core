#!/bin/bash
# Sweep backend x rate x load on the SENDER board (as root). Peer must run `sudo bash mission_run.sh receiver`.
#   sudo bash sweep.sh [SECONDS=60] ["RATES"] ["LOADS"] [REPEATS=1]
# Backends are interleaved inside each (rate, load) cell so drift (thermal, network) hits both equally.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SECS=${1:-60}; RATES=${2:-"1 5 10 20"}; LOADS=${3:-"0 1 2 3 4"}; REP=${4:-1}
TAG=sweep_$(date +%Y%m%d_%H%M%S)
echo "sweep $TAG: seconds=$SECS rates=[$RATES] loads=[$LOADS] repeats=$REP"
for r in $(seq 1 $REP); do for rate in $RATES; do for load in $LOADS; do
  order="cpu fpga"; [ $(( (r + rate + load) % 2 )) = 1 ] && order="fpga cpu"
  for b in $order; do
    echo "=== rep $r rate $rate load $load backend $b"
    bash $HERE/mission_run.sh $b $rate $load $SECS ${TAG}_rep$r || echo "!!! run failed: $b r$rate L$load"
  done
done; done; done
python3 $HERE/analyze.py /home/xilinx/wepwawet-core/logs/mission_runs --tag $TAG
