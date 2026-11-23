#!/bin/bash
# Fix the F' crash seen in the 2026-11-22 sweep: PqcTransport's async queue (depth 10) filled while
# the PeerPing handler was blocked in sign + TCP round trip -> FW_ASSERT (status 8 = queue full) -> abort.
# Change: PqcTransport queue depth 10 -> 100, and PeerPing commands DROP on overflow instead of asserting.
# Run on AUP1 only (it has the build tree). Backs up every file it touches.
set -e
CORE=$HOME/wepwawet-core/fprime/core-source
TS=$(date +%Y%m%d_%H%M%S)
FPP=$CORE/PqcTransport/PqcTransport.fpp
INST=$CORE/WepwawetDeployment/Top/instances.fpp
cp $FPP $FPP.bak_queuefix_$TS; cp $INST $INST.bak_queuefix_$TS
grep -q "async command PeerPing opcode 0 drop" $FPP || sed -i 's/async command PeerPing opcode 0$/async command PeerPing opcode 0 drop/' $FPP
grep -q "TRANSPORT_QUEUE_SIZE" $INST || sed -i 's/^\(\s*\)constant QUEUE_SIZE = 10$/\1constant QUEUE_SIZE = 10\n\1constant TRANSPORT_QUEUE_SIZE = 100/' $INST
awk '/instance pqcTransport:/{f=1} f && /queue size Default.QUEUE_SIZE/{sub(/Default.QUEUE_SIZE/,"Default.TRANSPORT_QUEUE_SIZE"); f=0} {print}' $INST > $INST.tmp && mv $INST.tmp $INST
echo "--- changes:"; grep -n "PeerPing" $FPP; grep -n "TRANSPORT_QUEUE_SIZE" $INST
source $HOME/Wepwawet/fprime-venv/bin/activate
cd $CORE/build-core && (make -j4 && make install) 2>&1 | tee $HOME/wepwawet-core/logs/queuefix_build_$TS.log | tail -4
BIN=$CORE/build-artifacts/Linux/WepwawetDeployment/bin/WepwawetDeployment
DEP=$HOME/wepwawet-core/fprime/deployment
[ $BIN -nt $INST.bak_queuefix_$TS ] || { echo "BUILD FAILED: binary not rebuilt, see queuefix_build_$TS.log"; exit 1; }
cp $DEP/WepwawetDeployment $DEP/WepwawetDeployment.before_queuefix_$TS
cp $BIN $DEP/WepwawetDeployment
cp $BIN /tmp/WepwawetDeployment.queuefix
sha256sum $DEP/WepwawetDeployment
echo "QUEUEFIX INSTALLED $TS"
