#!/usr/bin/env python3
"""REVIEWER: KeyGen KAT inputs from PQClean. usage: kg_prep.py <vecdir_with_msg.bin> <outdir> <xi_hex64>
Writes outdir/{pk.bin, sk_TEST_ONLY.bin, msg.bin, signature_REFERENCE_ONLY.bin (deterministic, rnd=0),
xi_4x64.mem, mu_8x64.mem (mu for the PL-generated key), K_4x64.mem, t1_coeffs.txt, rho_4x64.mem} using
~/rv/pqc_oracle (PQClean ML-DSA-44 clean, randombytes = xi)."""
import sys, os, subprocess, hashlib, shutil
vd, od, xi = sys.argv[1], sys.argv[2], sys.argv[3]
O = os.path.expanduser('~/rv/pqc_oracle'); os.makedirs(od, exist_ok=True)
pk, sk = os.path.join(od, 'pk.bin'), os.path.join(od, 'sk_TEST_ONLY.bin')
subprocess.run([O, 'keygen', xi, pk, sk], check=True, capture_output=True)
shutil.copy(os.path.join(vd, 'msg.bin'), os.path.join(od, 'msg.bin'))
subprocess.run([O, 'sign', sk, os.path.join(od, 'msg.bin'), 'zero', os.path.join(od, 'signature_REFERENCE_ONLY.bin')], check=True, capture_output=True)
P, S, M = open(pk, 'rb').read(), open(sk, 'rb').read(), open(os.path.join(od, 'msg.bin'), 'rb').read()
w = lambda b: ''.join('%016x\n' % int.from_bytes(b[8*i:8*i+8], 'little') for i in range(len(b) // 8))
tr = hashlib.shake_256(P).digest(64); assert tr == S[64:128], 'tr mismatch'
mu = hashlib.shake_256(tr + b'\x00\x00' + M).digest(64)
open(os.path.join(od, 'xi_4x64.mem'), 'w').write(w(bytes.fromhex(xi)))
open(os.path.join(od, 'mu_8x64.mem'), 'w').write(w(mu))
open(os.path.join(od, 'K_4x64.mem'), 'w').write(w(S[32:64]))
open(os.path.join(od, 'rho_4x64.mem'), 'w').write(w(P[:32]))
t1 = []; bits = int.from_bytes(P[32:], 'little')
for i in range(1024): t1.append((bits >> (10 * i)) & 0x3ff)
open(os.path.join(od, 't1_coeffs.txt'), 'w').write(' '.join(map(str, t1)) + '\n')
for fn, n in (('s1_hat_512x64.mem', 512), ('s2_hat_512x64.mem', 512), ('t0_hat_512x64.mem', 512), ('candidate_mask_seed_nonce_36x64.mem', 36)):
    open(os.path.join(od, fn), 'w').write('0000000000000000\n' * n)     # unused placeholders (key comes from the PL KeyGen)
print('KG_PREP_OK', od, 'pk_sha256', hashlib.sha256(P).hexdigest()[:16], 'rho', P[:8].hex())
