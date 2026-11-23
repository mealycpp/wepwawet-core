#!/usr/bin/env python3
"""Dev-time checker: signature produced with the PL-generated sealed key (from captures) must equal the oracle
deterministic signature of the oracle sk and verify under the oracle pk; t1 capture must re-encode to pk."""
import sys, hashlib
from pathlib import Path
W = Path(__file__).resolve().parents[2]; sys.path.insert(0, str(W / 'sign_v1'))
from check_retry_capture import read_words, words_bytes, coeffs, canonical_hw_zy, pack_z, pack_hints
from dilithium_py.ml_dsa import ML_DSA_44
cap, ref = Path(sys.argv[1]), Path(sys.argv[2])
pk = (ref / 'pk.bin').read_bytes(); msg = (ref / 'msg.bin').read_bytes()
t1 = coeffs(read_words(cap / 't1_512x64.hex', 512)); rho = pk[:32]
v = 0
for i, c in enumerate(t1): v |= (c & 1023) << (10 * i)
pk_pl = rho + v.to_bytes(1280, 'little')
c = words_bytes(read_words(cap / 'ctilde_4x64.hex', 4))
z = [canonical_hw_zy(x, 'Z', i) for i, x in enumerate(coeffs(read_words(cap / 'z_512x64.hex', 512)))]
hp, w = pack_hints(coeffs(read_words(cap / 'hint_512x64.hex', 512)))
sig = c + pack_z(z) + hp
ok = ML_DSA_44.verify(pk_pl, msg, sig, ctx=b''); same = sig == (ref / 'signature_REFERENCE_ONLY.bin').read_bytes()
print(f'KG_PK_FROM_PL_EQUALS_ORACLE={pk_pl == pk} pk_sha256={hashlib.sha256(pk_pl).hexdigest()}')
print(f'KG_SIGN_AFTER_KEYGEN verify_under_PL_pk={ok} equals_oracle_signature={same} hint_weight={w}')
if not (pk_pl == pk and ok and same): sys.exit('KG_CHECK_FAILED')
print('KG_CHECK_PASS')
