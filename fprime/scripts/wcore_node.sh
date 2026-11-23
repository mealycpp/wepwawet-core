#!/bin/bash
# WEPWAWET-CORE autonomous node launcher (run the same command on AUP1 and AUP2, as root):
#   sudo bash wcore_node.sh [PING_EVERY_SEC=5] [PINGS=20]
# 1) load the v6 SIGN+VERIFY+TRNG image and prove it is alive  2) start F' GDS + flight software (logs)
# 3) PeerPing the other node every PING_EVERY_SEC (FPGA sign here -> FPGA verify there), re-checking the
#    image before every ping  4) print a summary from the F' log. F' keeps running afterwards (stop: wcore_node.sh stop)
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"; HOST=$(hostname); TS=$(date +%Y%m%d_%H%M%S)
LOGD=/home/xilinx/wepwawet-core/logs/node_$TS; mkdir -p $LOGD
DEP=/home/xilinx/wepwawet-core/fprime/deployment; PRJ=/home/xilinx/wepwawet-core/fprime/core-source/WepwawetDeployment
VENV=/home/xilinx/Wepwawet/fprime-venv
EVERY=${1:-5}; N=${2:-20}
if [ "${1:-}" = "stop" ]; then pkill -f WepwawetDeployment; pkill -f fprime-gds; echo stopped; exit 0; fi
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
for f in /etc/profile.d/xrt_setup.sh /etc/profile.d/pynq_venv.sh; do [ -f $f ] && . $f; done
cd $KIT; [ -x ./wcore_check ] || gcc -O2 -o wcore_check wcore_check.c
pkill -f "$DEP/WepwawetDeployment" 2>/dev/null; pkill -f fprime-gds 2>/dev/null; sleep 1
echo "[$HOST] 1/4 loading v6 image"; /usr/local/share/pynq-venv/bin/python $KIT/load_v6.py > $LOGD/load.log 2>&1
./wcore_check | tee $LOGD/check.log || { echo "[$HOST] ABORT: v6 image not alive after load"; exit 1; }
echo "[$HOST] 2/4 starting GDS + F' (logs in $LOGD)"
( . $VENV/bin/activate; cd $PRJ; exec fprime-gds --no-app ) > $LOGD/gds.log 2>&1 &
sleep 6
( cd $DEP; exec ./WepwawetDeployment -a 127.0.0.1 -p 50000 ) > $LOGD/fsw.log 2>&1 &
for i in $(seq 1 20); do grep -aq "listening on" $LOGD/fsw.log && break; sleep 0.5; done
grep -a "WCORE" $LOGD/fsw.log | head -3
echo "[$HOST] 3/4 waiting 10 s for the peer node, then $N PeerPings every $EVERY s"; sleep 10
for k in $(seq 1 $N); do
  ./wcore_check > /dev/null || { echo "[$HOST] ping $k: FPGA IMAGE LOST -> reloading"; /usr/local/share/pynq-venv/bin/python $KIT/load_v6.py >> $LOGD/load.log 2>&1; }
  ( . $VENV/bin/activate; cd $PRJ; fprime-cli command-send WepwawetDeployment.pqcTransport.PeerPing ) >> $LOGD/cli.log 2>&1
  sleep $EVERY
done
sleep 2
S() { grep -ac "$1" $LOGD/fsw.log; }
echo "================ [$HOST] SUMMARY ($LOGD) ================"
echo "image:                      $(./wcore_check)"
echo "PeerPings sent:             $N"
echo "signed on FPGA (rc=0):      $(S 'WCORE: sign backend=fpga rc=0')"
echo "sign failures:              $(grep -a 'WCORE: sign' $LOGD/fsw.log | grep -avc 'rc=0')"
echo "peer frames verified FPGA:  $(S 'WCORE: verify backend=fpga rc=0')"
echo "  accepted (verdict=1):     $(grep -a 'WCORE: verify backend=fpga' $LOGD/fsw.log | grep -ac 'verdict=1')"
echo "verify on CPU (must be 0):  $(S 'WCORE: verify backend=cpu')"
echo "verify FPGA unavailable:    $(S 'fpga-unavailable')"
echo "receive ACCEPT / REJECT:    $(S 'verdict=ACCEPT') / $(S 'verdict=REJECT')"
echo "F' keeps running. Stop with: sudo bash $KIT/wcore_node.sh stop"
