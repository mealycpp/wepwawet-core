#!/bin/bash
# On the AUP board: needs ~/pqbench (PQClean, built once, same as v7 kit). Produces ./wcore_selftest_v8
set -e; cd "$(dirname "$0")"; P=${PQBENCH:-/home/xilinx/pqbench}
gcc -O2 -std=c99 -I. -I$P/aarch64 -I$P/common -I$P/common/keccak2x wcore_selftest_v8.c wcore_fpga.c \
    $P/aarch64/*.c $P/aarch64/*.S $P/common/keccak2x/fips202x2.c $P/common/keccak2x/feat.S $P/common/fips202.c $P/common/randombytes.c \
    -o wcore_selftest_v8
echo built ./wcore_selftest_v8
