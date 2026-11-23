#!/bin/bash
# Per boot / per image load, on EACH board, as root:   sudo bash node_prep_v8.sh [I-UNDERSTAND-LEVEL2]
# 1 stops F'/GDS  2 loads the phase-3 image if it is not already loaded (Level2: needs the explicit argument)
# 3 builds the C tools  4 wcore_keygen_tool: PL KEYGEN, backs up identity files (node_sk.bin MOVED to backup), writes
#   node_pk.bin + node_tr.bin  5 wcore_check (must say "key SEALED").
set -u; K="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
for f in /etc/profile.d/xrt_setup.sh /etc/profile.d/pynq_venv.sh; do [ -f $f ] && . $f; done
pkill -f WepwawetDeployment 2>/dev/null; pkill -f fprime-gds 2>/dev/null; pkill -f fprime_gds 2>/dev/null; sleep 1   # F' must not hold the PL while the key is generated
gcc -O2 -o $K/wcore_check $K/wcore_check.c || exit 1
gcc -O2 -std=c99 -I$K/wcore_drv -o $K/wcore_keygen_tool $K/wcore_drv/wcore_keygen_tool.c $K/wcore_drv/wcore_fpga.c || exit 1
if ! WCORE_CHECK_ALLOW_UNLOCKED=1 $K/wcore_check > /dev/null; then
  [ "${1:-}" = "I-UNDERSTAND-LEVEL2" ] || { echo "phase-3 image not loaded. Loading it (Level2 readback security: other images may need a power cycle afterwards). Re-run with I-UNDERSTAND-LEVEL2"; exit 3; }
  bash $K/load_v8.sh || exit 1
fi
$K/wcore_keygen_tool || exit 1
$K/wcore_check
