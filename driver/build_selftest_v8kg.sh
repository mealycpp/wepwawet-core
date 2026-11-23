#!/bin/bash
# On the AUP board: needs PQClean (~xilinx/pqbench, built once, as the v7/v8 kits). Produces ./wcore_selftest_v8kg
set -e; cd "$(dirname "$0")"; P=${PQBENCH:-/home/xilinx/pqbench}
gcc -O2 -std=c99 -I. -I$P/aarch64 -I$P/common -I$P/common/keccak2x wcore_selftest_v8kg.c wcore_fpga.c \
    $P/aarch64/*.c $P/aarch64/*.S $P/common/keccak2x/fips202x2.c $P/common/keccak2x/feat.S $P/common/fips202.c $P/common/randombytes.c \
    -o wcore_selftest_v8kg
gcc -O2 -std=c99 -I. -o wcore_provision wcore_provision.c wcore_fpga.c
echo built ./wcore_selftest_v8kg
