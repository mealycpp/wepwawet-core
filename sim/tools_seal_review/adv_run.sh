#!/bin/bash
# REVIEWER: adv_run.sh <binary> <srcdir> <sign_vecdir> <verify_vecdir> <rundir> [+STOP=N] [+SWEEPS=hexmask]
B=$1; S=$2; V=$3; VV=$4; RD=$5; shift 5
mkdir -p $RD/vectors $RD/vvectors $RD/capture; cp $V/*.mem $RD/vectors/; cp $VV/*.mem $RD/vvectors/; cp $S/hls_*/*.dat $RD/ 2>/dev/null
# phase-2 ABI needs K = sk[32..63] as 4 little-endian 64-bit words
[ -f $V/sk_TEST_ONLY.bin ] && python3 -c "import sys;b=open(sys.argv[1],'rb').read()[32:64];open(sys.argv[2],'w').write(''.join('%016x\n'%int.from_bytes(b[8*i:8*i+8],'little') for i in range(4)))" $V/sk_TEST_ONLY.bin $RD/vectors/K_4x64.mem
cd $RD && timeout 600 $B "$@" > sim.log 2>&1; echo "EXIT=$?" >> sim.log; tail -3 sim.log
