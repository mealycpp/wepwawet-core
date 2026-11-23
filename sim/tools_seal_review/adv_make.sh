#!/bin/bash
OBJ=$1
timeout ${2:-60} make -j2 -C $OBJ -f Vtb_adv_seal.mk VK_PCH_I_FAST= VK_PCH_I_SLOW= CXXFLAGS="-fcoroutines -std=gnu++20" OPT_FAST="-O1" OPT_SLOW="-O0" >> $OBJ.make.log 2>&1
rc=$?; [ $rc -eq 0 ] && echo BUILT || echo "MAKE_RC=$rc (rerun)"; grep -m3 " error" $OBJ.make.log
exit $rc
