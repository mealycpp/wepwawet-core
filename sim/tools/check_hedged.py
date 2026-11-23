#!/usr/bin/env python3
"""Dev-time checker (not in the board runtime path): assemble hedged signatures A/B from the PS-window
captures and verify them independently under pk with dilithium-py; they must differ from each other and
from the deterministic reference."""
import sys, hashlib
from pathlib import Path
W = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(W / 'sign_v1'))
from check_retry_capture import read_words, words_bytes, coeffs, canonical_hw_zy, pack_z, pack_hints
from dilithium_py.ml_dsa import ML_DSA_44
cap, ref = Path(sys.argv[1]), Path(sys.argv[2])
def verify_mu(pk, mu, sig, M=ML_DSA_44):
    rho, t1 = M._unpack_pk(pk)
    c_tilde, z, h = M._unpack_sig(sig)
    if h.sum_hint() > M.omega or z.check_norm_bound(M.gamma_1 - M.beta): return False
    A_hat = M._expand_matrix_from_seed(rho)
    c = M.R.sample_in_ball(c_tilde, M.tau).to_ntt()
    w = ((A_hat @ z.to_ntt()) - t1.scale(1 << M.d).to_ntt().scale(c)).from_ntt()
    return c_tilde == M._h(mu + h.use_hint(w, 2 * M.gamma_2).bit_pack_w(M.gamma_2), M.c_tilde_bytes)
pk = (ref / 'pk.bin').read_bytes(); msg = (ref / 'msg.bin').read_bytes()
detref = (ref / 'signature_REFERENCE_ONLY.bin').read_bytes()
sigs = {}
for t in 'AB':
    c = words_bytes(read_words(cap / f'{t}_ctilde_4x64.hex', 4))
    z = [canonical_hw_zy(x, 'Z', i) for i, x in enumerate(coeffs(read_words(cap / f'{t}_z_512x64.hex', 512)))]
    hp, w = pack_hints(coeffs(read_words(cap / f'{t}_hint_512x64.hex', 512)))
    s = c + pack_z(z) + hp; sigs[t] = s
    ok = ML_DSA_44.verify(pk, msg, s, ctx=b''); bad = ML_DSA_44.verify(pk, msg + b'!', s, ctx=b'')
    print(f'HEDGED_{t} sha256={hashlib.sha256(s).hexdigest()} hint_weight={w} verify={ok} mutated_msg_rejected={not bad} equals_deterministic={s == detref}')
    if not ok or bad: sys.exit('HEDGED_VERIFY_FAILED')
if sigs['A'] == sigs['B']: sys.exit('HEDGED_SIGNATURES_IDENTICAL')
kg = cap / 'KG_t1_512x64.hex'
if kg.exists():                                  # phase 3: hedged PL KeyGen -> pk from the PS window
    rho = words_bytes(read_words(cap / 'KG_rho_4x64.hex', 4)); v = 0
    for i, c in enumerate(coeffs(read_words(kg, 512))): v |= (c & 1023) << (10 * i)
    pk2 = rho + v.to_bytes(1280, 'little')
    c = words_bytes(read_words(cap / 'C_ctilde_4x64.hex', 4))
    z = [canonical_hw_zy(x, 'Z', i) for i, x in enumerate(coeffs(read_words(cap / 'C_z_512x64.hex', 512)))]
    hp, w = pack_hints(coeffs(read_words(cap / 'C_hint_512x64.hex', 512)))
    s = c + pack_z(z) + hp
    # the tb signs the fixed test mu (vectors/mu.bin) with the new key: verify FIPS 204 Alg. 8 with that external mu
    mu = (ref / 'mu.bin').read_bytes()
    ok = verify_mu(pk2, mu, s); bad = verify_mu(pk2, bytes([mu[0] ^ 1]) + mu[1:], s)
    print(f'HEDGED_KEYGEN pk_sha256={hashlib.sha256(pk2).hexdigest()} differs_from_test_pk={pk2 != pk} sign_verify_under_PL_pk={ok} mutated_rejected={not bad}')
    if not ok or bad or pk2 == pk: sys.exit('HEDGED_KEYGEN_CHECK_FAILED')
print('HEDGED_CHECK_PASS')
