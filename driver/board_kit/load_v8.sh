#!/bin/bash
# Boot-time loader only (not in the signing/verify runtime path). Loads wepwawet_sign_v8.bit.
# Prefers the C fpgautil (Xilinx/PYNQ images); otherwise falls back to the PYNQ Overlay loader exactly like aup_kit_v7.
# NOTE: this image is built with BITSTREAM.READBACK.SECURITY=Level2 (see READBACK_SECURITY.txt). Level2 also restricts
# later PL reconfiguration: if loading a DIFFERENT image (e.g. back to v7) fails afterwards, power-cycle the board.
set -e; K="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
# build the checker first (independent of the load)
gcc -O2 -o "$K/wcore_check_v8" "$K/wcore_check_v8.c"
# PYNQ needs the XRT/PYNQ environment that sudo strips (same as mission_run.sh / aup_kit_v7)
set +e; for f in /etc/profile.d/xrt_setup.sh /etc/profile.d/pynq_venv.sh; do [ -f $f ] && . $f; done; set -e
if command -v fpgautil >/dev/null 2>&1; then fpgautil -b "$K/wepwawet_sign_v8.bit"
else /usr/local/share/pynq-venv/bin/python - <<PY
from pynq import Overlay; Overlay("$K/wepwawet_sign_v8.bit")
PY
fi
"$K/wcore_check_v8"
