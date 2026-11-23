#!/bin/bash
# AUP1 ONLY (has the F' build tree). Run as user xilinx (NOT sudo: the venv and build tree live in /home/xilinx).
#   bash install_fsw_v8_aup1.sh
# Installs the seal_v8 HwAccelMgr (VERSION >= 0x0003_0002 -> sign with the PL-sealed key via node_tr.bin, never opens
# node_sk.bin; v7 image -> unchanged v7 path) and the PqcTransport sealed-key patch (no secret read if node_sk.bin is
# absent). Keeps the queue fix (queue 100 + PeerPing drop) -- aborts if it is not in the tree. Backs up everything.
# Result: deployment binary installed here + /tmp/WepwawetDeployment.v8sealed for AUP2.
set -e
[ "$(id -u)" != 0 ] || { echo "run as xilinx, not root (sudo sets HOME=/root)"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"; CORE=/home/xilinx/wepwawet-core/fprime/core-source; TS=$(date +%Y%m%d_%H%M%S)
DEP=/home/xilinx/wepwawet-core/fprime/deployment; LOGS=/home/xilinx/wepwawet-core/logs; mkdir -p $LOGS
PQT=$CORE/PqcTransport/PqcTransport.cpp; FPP=$CORE/PqcTransport/PqcTransport.fpp; INST=$CORE/WepwawetDeployment/Top/instances.fpp
for f in $PQT $FPP $INST $CORE/HwAccelMgr/HwAccelMgr.cpp; do [ -f $f ] || { echo "MISSING $f"; exit 1; }; done
grep -q "async command PeerPing opcode 0 drop" $FPP && grep -q "TRANSPORT_QUEUE_SIZE" $INST || {
  echo "ABORT: the PqcTransport queue fix is not in the tree. Run mission_kit/harness/fix_fsw_queue.sh first."; exit 1; }
# PqcTransport: apply the 22-line sealed-key patch (fuzzy), or accept an already patched file
if grep -q "haveSecret" $PQT; then echo "PqcTransport.cpp already patched"
else patch --dry-run -p0 $PQT < $HERE/fprime_src/PqcTransport_seal_v8.diff > /dev/null \
     || { echo "ABORT: PqcTransport_seal_v8.diff does not apply to $PQT (tree differs). Nothing changed."; exit 1; }
     cp $PQT $PQT.before_seal_v8_$TS; patch -p0 $PQT < $HERE/fprime_src/PqcTransport_seal_v8.diff; fi
cp -r $CORE/HwAccelMgr $CORE/../HwAccelMgr.backup_seal_v8_$TS
cp $HERE/fprime_src/HwAccelMgr/HwAccelMgr.cpp $HERE/fprime_src/HwAccelMgr/HwAccelMgr.hpp $HERE/fprime_src/HwAccelMgr/CMakeLists.txt $CORE/HwAccelMgr/
cp -r $HERE/fprime_src/HwAccelMgr/pqclean_neon $CORE/HwAccelMgr/
cp $HERE/wcore_drv/wcore_fpga.c $HERE/wcore_drv/wcore_fpga.h $CORE/HwAccelMgr/
source /home/xilinx/Wepwawet/fprime-venv/bin/activate
cd $CORE/build-core && (make -j4 && make install) 2>&1 | tee $LOGS/fsw_v8sealed_build_$TS.log | tail -4
BIN=$CORE/build-artifacts/Linux/WepwawetDeployment/bin/WepwawetDeployment
[ $BIN -nt $CORE/../HwAccelMgr.backup_seal_v8_$TS ] || { echo "BUILD FAILED: binary not rebuilt, see $LOGS/fsw_v8sealed_build_$TS.log"; exit 1; }
cp $DEP/WepwawetDeployment $DEP/WepwawetDeployment.before_seal_v8_$TS
cp $BIN $DEP/WepwawetDeployment; cp $BIN /tmp/WepwawetDeployment.v8sealed
sha256sum $DEP/WepwawetDeployment /tmp/WepwawetDeployment.v8sealed
strings $DEP/WepwawetDeployment | grep -q "seal_v8 image: signing key SEALED" && echo "binary contains the seal_v8 HwAccelMgr" || { echo "WARNING: seal_v8 string not found in binary"; exit 1; }
echo "INSTALLED seal_v8 F' on $(hostname) ($TS). Backups: HwAccelMgr.backup_seal_v8_$TS, PqcTransport.cpp.before_seal_v8_$TS, WepwawetDeployment.before_seal_v8_$TS"
