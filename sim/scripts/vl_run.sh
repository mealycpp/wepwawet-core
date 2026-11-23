#!/bin/bash
# vl_run.sh <binary> <srcdir> <vecdir> <rundir> [+plusargs]
B=$1; S=$2; V=$3; R=$4; shift 4
mkdir -p $R/vectors $R/capture; cp $V/*.mem $R/vectors/; cp $S/hls_*/*.dat $R/ 2>/dev/null
cd $R && timeout 600 $B "$@" > sim.log 2>&1; echo "EXIT=$?" >> sim.log; grep -E "DONE|PASS|FAIL|fatal|Error|EXIT" sim.log | tail -6
