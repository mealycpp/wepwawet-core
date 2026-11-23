# ground_ca (BUILDER-owned)
- ground_sk.bin: SECRET ground signing key (generated 16:47 PT 2026-11-22 by ground_ca.x86_64 keygen). Never copy to a
  board or a repository. ground_pk.bin: public (also in aup_kit_v8_duplex/ground_pk.bin, same SHA256 2b655852...).
- Exact certificate format used by the kit (wcore_cert_check) and by ground_ca.x86_64 / ground_ca.c:
    body = ASCII "WCORE-CERT-V1|" || NODE || "|" || SHAKE256(node_pk.bin (1312 B), 32 bytes)
    cert = ML-DSA-44 signature (2420 B), PQClean "clean", hedged (randomized) signing, pure ML-DSA, empty context.
  (NOT "|| pk (1312 B)": the earlier quick binary with that body was renamed an unused full-pk-format build;
   certificates from it do not verify with wcore_cert_check.)
- usage: ./ground_ca.x86_64 issue . AUP1 ../aup1_node_pk_v8.bin ; ./ground_ca.x86_64 check . AUP1 ../aup1_node_pk_v8.bin AUP1.cert
