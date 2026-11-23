#!/bin/bash
# build.sh <pqclean_root>  -> ./pqc_oracle (in $HOME/rv)
P=$1; D=$(cd "$(dirname "$0")" && pwd)
gcc -O2 -I$D -I$P/crypto_sign/ml-dsa-44/clean -I$P/common -o $HOME/rv/pqc_oracle $D/pqc_oracle.c $P/crypto_sign/ml-dsa-44/clean/*.c $P/common/fips202.c && echo BUILT_ORACLE
