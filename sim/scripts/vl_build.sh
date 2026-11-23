#!/bin/bash
# Verilator build: vl_build.sh <srcdir> <tb.sv> <top> <objdir> [extra verilator args...]
# Verilator 5.48 (pip wheel) in the Cowork Linux VM. XSim remains the reference simulator.
set -e
S=$1; TB=$2; TOP=$3; OBJ=$4; shift 4
F="$(ls $S/rtl/*.v $S/rtl/*.sv) $S/reference/wcore_scratchpad.v $(ls $S/hls_*/*.v) $(ls $S/*.sv $S/*.v)"
VL=~/.local/bin/verilator-cli
$VL --cc --exe --main --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
   --top-module $TOP -Mdir $OBJ "$@" $F $TB > $OBJ.vl.log 2>&1 || { tail -20 $OBJ.vl.log; exit 1; }
rm -f $OBJ/*.gch
make -j2 -C $OBJ -f V$TOP.mk VK_PCH_I_FAST= VK_PCH_I_SLOW= CXXFLAGS="-fcoroutines -std=gnu++20" OPT_FAST="-O1" OPT_SLOW="-O0" > $OBJ.make.log 2>&1 || { grep -m5 error $OBJ.make.log; exit 1; }
ls -la $OBJ/V$TOP
