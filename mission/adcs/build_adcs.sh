#!/bin/bash
# Build adcs_load (aarch64 board or x86 VM). Usage: bash build_adcs.sh
set -e; cd "$(dirname "$0")"
gcc -O2 -std=c99 -Wall -Wextra -o adcs_load adcs_load.c -lm
echo "built $(pwd)/adcs_load"
