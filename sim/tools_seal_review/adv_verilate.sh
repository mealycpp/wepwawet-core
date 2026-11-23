#!/bin/bash
# REVIEWER: adv_verilate.sh <srcdir> <objdir> [+define+ADV_V8 ...]   then run adv_make.sh <objdir> until it prints BUILT
S=$1; OBJ=$2; shift 2
R=$(cd "$(dirname "$0")/.." && pwd)
F="$(ls $S/rtl/*.v $S/rtl/*.sv) $S/reference/wcore_scratchpad.v $(ls $S/hls_*/*.v) $(ls $S/*.sv $S/*.v) $(ls $S/trng/*.v 2>/dev/null)"
~/.local/bin/verilator-cli --cc --exe --main --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
   --top-module tb_adv_seal -Mdir $OBJ "$@" $F $R/tb/tb_adv_seal.sv > $OBJ.vl.log 2>&1; rc=$?
grep -E "%Error" $OBJ.vl.log | head; rm -f $OBJ/*.gch; echo VERILATE_RC=$rc
