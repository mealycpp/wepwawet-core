#!/bin/bash
# vl_regress.sh <tag> : build seal_v8 src with Verilator and run the v7 regression set.
W=$HOME/mnt/HLS/WEPWAWET_CORE_WORK/04_WORK; S=$W/seal_v8/src; T=$W/seal_v8/tb; SIM=$W/seal_v8/sim
TAG=$1; B=~/vb/$TAG; mkdir -p $B; OUT=$W/seal_v8/sim/runs/$TAG; mkdir -p $OUT
echo "BUILD_START $(date -Is)" > $OUT/SUMMARY.txt
$SIM/vl_build.sh $S $T/tb_sign_multi.sv tb_sign_multi $B/obj_sign >> $OUT/SUMMARY.txt 2>&1 || { echo BUILD_FAIL_SIGN >> $OUT/SUMMARY.txt; exit 1; }
$SIM/vl_build.sh $S $T/tb_verify_axil.sv tb_verify_axil $B/obj_verify >> $OUT/SUMMARY.txt 2>&1 || { echo BUILD_FAIL_VERIFY >> $OUT/SUMMARY.txt; exit 1; }
for c in vec_7 vec_6 vec_b80 vec_3 vec_hint vec_23; do
  vd=$W/vectors/$c; [ -d $W/omega_v1/vectors/$c ] && vd=$W/omega_v1/vectors/$c
  $SIM/vl_run.sh $B/obj_sign/Vtb_sign_multi $S $vd $B/sign_$c > /dev/null
  cp $B/sign_$c/sim.log $OUT/sign_$c.sim.log; mkdir -p $OUT/sign_$c; cp $B/sign_$c/capture/* $OUT/sign_$c/
  python3 $W/sign_v3/check_sign_v3.py --capture $B/sign_$c/capture --oracle $vd > $OUT/sign_$c.check.log 2>&1
  echo "sign_$c $(grep -o 'cycles=[0-9]*' $B/sign_$c/capture/status.txt) $(tail -1 $OUT/sign_$c.check.log)" >> $OUT/SUMMARY.txt
done
for c in valid valid_vec3 bad_msg bad_ctilde bad_znorm; do
  $SIM/vl_run.sh $B/obj_verify/Vtb_verify_axil $S $W/verify_v1/vectors/$c $B/verify_$c > /dev/null
  cp $B/verify_$c/sim.log $OUT/verify_$c.sim.log
  echo "verify_$c $(grep -h 'VERIFYV1_RESULT\|fatal\|INTERMEDIATES' $B/verify_$c/sim.log | tr '\n' ' ')" >> $OUT/SUMMARY.txt
done
echo "ALL_DONE $(date -Is)" >> $OUT/SUMMARY.txt
