#!/bin/bash
# REVIEWER: build the adversarial TB with Verilator 5 (--timing).  adv_build.sh <srcdir> <objdir> [defines...]
# e.g. adv_build.sh .../omega_v1/src ~/rv/obj_v7            (v7 positive control)
#      adv_build.sh .../review/snap/X/src ~/rv/obj_v8 +define+ADV_V8
set -e
S=$1; OBJ=$2; shift 2
R=$(cd "$(dirname "$0")/.." && pwd)
F="$(ls $S/rtl/*.v $S/rtl/*.sv) $S/reference/wcore_scratchpad.v $(ls $S/hls_*/*.v) $(ls $S/*.sv $S/*.v)"
VL=~/.local/bin/verilator-cli
mkdir -p $OBJ
nice $VL --cc --exe --main --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
   --top-module tb_adv_seal -Mdir $OBJ "$@" $F $R/tb/tb_adv_seal.sv > $OBJ.vl.log 2>&1 || { tail -20 $OBJ.vl.log; exit 1; }
rm -f $OBJ/*.gch
nice make -j2 -C $OBJ -f Vtb_adv_seal.mk VK_PCH_I_FAST= VK_PCH_I_SLOW= CXXFLAGS="-fcoroutines -std=gnu++20" OPT_FAST="-O1" OPT_SLOW="-O0" > $OBJ.make.log 2>&1 || { grep -m5 error $OBJ.make.log; exit 1; }
ls -la $OBJ/Vtb_adv_seal
