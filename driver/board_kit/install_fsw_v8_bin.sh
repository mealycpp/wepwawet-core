#!/bin/bash
# AUP2 (no build tree): install the seal_v8 F' binary copied from AUP1 to /tmp/WepwawetDeployment.v8sealed. Backs up.
set -e
D=/home/xilinx/wepwawet-core/fprime/deployment; N=$D/WepwawetDeployment
[ -f /tmp/WepwawetDeployment.v8sealed ] || { echo "MISSING /tmp/WepwawetDeployment.v8sealed (copy it from AUP1)"; exit 1; }
strings /tmp/WepwawetDeployment.v8sealed | grep -q "seal_v8 image: signing key SEALED" || { echo "not the seal_v8 binary"; exit 1; }
cp $N $N.before_seal_v8_$(date +%Y%m%d_%H%M%S); cp /tmp/WepwawetDeployment.v8sealed $N; chmod +x $N
sha256sum $N; echo "seal_v8 F' BINARY INSTALLED on $(hostname)"
