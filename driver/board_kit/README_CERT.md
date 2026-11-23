# Optional: ground-issued certificates for the PL-generated node keys (after STEPS 4, replaces the trust part of STEP 5)
Ground CA: 05_RESULTS/ground_ca (ground_ca.c, ground_ca.x86_64, ground_pk.bin; ground_sk.bin stays there, NEVER on a board).
Certificate = ML-DSA-44 (PQClean clean, hedged/randomized signing, pure, empty ctx) over
  "WCORE-CERT-V1|<NODE>|" || SHAKE256(node_pk, 32 bytes).
Board check: `wcore_cert_check ground_pk.bin <PEER> peer_pk.bin <PEER>.cert --install` verifies with the FABRIC Verify
program AND PQClean (CPU) -- it prints both verifier names -- and first proves that a 1-bit tampered pk and a 1-bit
tampered cert are rejected; only then it installs peer_pk.bin as trusted_peer_pk.bin (old one backed up).

1. (PC) fetch node pks:   scp "xilinx@aup1:/home/xilinx/wepwawet-core/firmware/identity/node_pk.bin" "$R\aup1_node_pk_v8.bin"   (same for aup2)
2. (ground computer) issue:
     cd /path/to/05_RESULTS/ground_ca && ./ground_ca.x86_64 issue . AUP1 ../aup1_node_pk_v8.bin && ./ground_ca.x86_64 issue . AUP2 ../aup2_node_pk_v8.bin
     ./ground_ca.x86_64 check . AUP1 ../aup1_node_pk_v8.bin AUP1.cert ; ./ground_ca.x86_64 check . AUP2 ../aup2_node_pk_v8.bin AUP2.cert
3. (PC) give each board the PEER's pk + cert (into the kit dir; F' stopped):
     scp "$R\aup2_node_pk_v8.bin" "$R\ground_ca\AUP2.cert" "xilinx@aup1:~/aup_kit_v8_duplex/"
     scp "$R\aup1_node_pk_v8.bin" "$R\ground_ca\AUP1.cert" "xilinx@aup2:~/aup_kit_v8_duplex/"
4. (boards)
     ssh -t xilinx@aup1 "cd ~/aup_kit_v8_duplex && bash wcore_drv/build_cert_check.sh && sudo ./wcore_drv/wcore_cert_check ground_pk.bin AUP2 aup2_node_pk_v8.bin AUP2.cert --install"
     ssh -t xilinx@aup2 "cd ~/aup_kit_v8_duplex && bash wcore_drv/build_cert_check.sh && sudo ./wcore_drv/wcore_cert_check ground_pk.bin AUP1 aup1_node_pk_v8.bin AUP1.cert --install"
   Expect two CERT_CHECK lines (FABRIC, CPU) with valid=1 tampered_pk_rejected=1 tampered_cert_rejected=1 and RESULT: ACCEPT.
LIMIT (state it in the paper): ground_pk.bin is a host file on the board, so root can substitute it; this is a protocol
demonstration of ground-certified PL keys, not a root-resistant anchor. The root-resistant anchor is the
bitstream-constant pin (separate seal_v8/pin implementation, simulation only).
Off-board check done: ground_ca keygen/issue/check works (VALID for the right node+pk, INVALID for a wrong node name or a
different pk); PQClean SHAKE256 and the driver's SHAKE256 produce the same certificate digest. Not run on hardware.
