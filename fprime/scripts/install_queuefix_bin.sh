#!/bin/bash
# Install the queue-fixed F' binary (copied from AUP1 to /tmp) on this board. Backs up the old one.
set -e
D=$HOME/wepwawet-core/fprime/deployment
N=$D/WepwawetDeployment
[ -f /tmp/WepwawetDeployment.queuefix ] || { echo "MISSING /tmp/WepwawetDeployment.queuefix"; exit 1; }
cp $N $N.before_queuefix_$(date +%Y%m%d_%H%M%S)
cp /tmp/WepwawetDeployment.queuefix $N; chmod +x $N
sha256sum $N; echo "QUEUEFIX BINARY INSTALLED on $(hostname)"
