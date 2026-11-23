#!/bin/bash
# On the board: fabric verifier + PQClean cross-check. Produces ./wcore_cert_check
set -e; cd "$(dirname "$0")"; P=${PQBENCH:-/home/xilinx/pqbench}
gcc -O2 -std=c99 -DWITH_PQCLEAN -I. -I$P/aarch64 -I$P/common -I$P/common/keccak2x wcore_cert_check.c wcore_fpga.c \
    $P/aarch64/*.c $P/aarch64/*.S $P/common/keccak2x/fips202x2.c $P/common/keccak2x/feat.S $P/common/fips202.c $P/common/randombytes.c \
    -o wcore_cert_check
echo built ./wcore_cert_check
