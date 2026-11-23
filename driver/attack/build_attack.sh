#!/bin/bash
# Build on the AUP board (aarch64, gcc). Uses the kit's driver only for the pure helpers
# (wcore_prepare_key/msg, wcore_pack_sig); all attack accesses are raw /dev/mem in wcore_attack_v8.c.
set -e; cd "$(dirname "$0")"
D=../wcore_drv; [ -f $D/wcore_fpga.c ] || D=../../../04_WORK/seal_v8/wcore_drv; [ -f $D/wcore_fpga.c ] || D=../../aup_kit_v7/wcore_drv
gcc -O2 -std=gnu99 -I$D -o wcore_attack_v8 wcore_attack_v8.c $D/wcore_fpga.c
echo "built ./wcore_attack_v8 (driver helpers from $D)"
