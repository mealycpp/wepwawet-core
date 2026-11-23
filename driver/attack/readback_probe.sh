#!/bin/bash
# REVIEWER: CRITICAL-6 probe — can root read PL configuration data (incl. BRAM) back through PCAP?
# Run AFTER the v8 image is loaded and a TEST key is provisioned+LOCKed (e.g. right after wcore_attack_v8 step 1,
# before its final ZEROIZE, or after `wcore_provision` with the TEST key). Read-only; never writes the PL.
# PASS = readback interface absent or every attempt fails / returns no data. FAIL = configuration data came back.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
OUT=${1:-/tmp/readback_probe}; mkdir -p $OUT; res=PASS
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug 2>/dev/null
echo "kernel: $(uname -r)"; ls /sys/class/fpga_manager/ 2>/dev/null
P=/sys/module/zynqmp_fpga/parameters/readback_type; IMG=/sys/kernel/debug/fpga/fpga0/image
echo "readback_type param: $([ -e $P ] && cat $P || echo absent)   debugfs image: $([ -e $IMG ] && echo present || echo absent)"
if [ -e $IMG ]; then
  for t in 1 0; do                                   # 1 = configuration data (BRAM), 0 = configuration registers
    [ -e $P ] && echo $t > $P 2>/dev/null
    timeout 120 dd if=$IMG of=$OUT/readback_type$t.bin bs=1M 2>$OUT/dd_type$t.txt; rc=$?
    sz=$(stat -c %s $OUT/readback_type$t.bin 2>/dev/null || echo 0)
    nz=$(od -An -v -tx1 $OUT/readback_type$t.bin 2>/dev/null | tr -s ' ' '\n' | grep -vc '^00$\|^$')
    echo "type=$t rc=$rc bytes=$sz nonzero_bytes=$nz"
    if [ "$t" = 1 ] && [ "$sz" -gt 0 ] && [ "$nz" -gt 0 ]; then res=FAIL; fi
  done
else echo "no debugfs readback interface on this kernel (also try the vendor tool path if one exists)"; fi
echo "READBACK_PROBE $res  (FAIL = configuration data incl. BRAM readable by root -> the AXI seal can be bypassed)"
