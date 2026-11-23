#!/bin/bash
# On AUP1: needs ~/pqbench (PQClean, already built once). Produces ./wcore_selftest
set -e; cd "$(dirname "$0")"; P=$HOME/pqbench
gcc -O2 -std=c99 -I. -I$P/aarch64 -I$P/common -I$P/common/keccak2x wcore_selftest.c wcore_fpga.c \
    $P/aarch64/*.c $P/aarch64/*.S $P/common/keccak2x/fips202x2.c $P/common/keccak2x/feat.S $P/common/fips202.c $P/common/randombytes.c \
    -o wcore_selftest
echo built ./wcore_selftest
