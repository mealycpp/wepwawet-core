#!/bin/bash
# Build on the AUP board (aarch64, gcc) or any Linux box. No internet, no CMake needed.
set -e; cd "$(dirname "$0")"
make -s -C libaec clean >/dev/null 2>&1 || true
make -s -C libaec CFLAGS="-O3 -std=c99 -Wall"
gcc -O2 -std=c99 -Wall -Ilibaec/include -o payload_load payload_load.c libaec/libaec.a -lpthread
gcc -O2 -std=c99 -Wall -Ilibaec/include -o ccsds_conformance ccsds_conformance.c libaec/libaec.a
./ccsds_conformance ccsds_testdata | tail -1
echo "built ./payload_load ./ccsds_conformance ($(uname -m))"
