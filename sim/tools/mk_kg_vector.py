#!/usr/bin/env python3
"""Dev-time oracle (dilithium-py 1.5.1, FIPS 204 final): KeyGen_internal(xi) -> expected PL KeyGen outputs + a sign vector."""
import sys, os, subprocess, hashlib
from pathlib import Path
from dilithium_py.ml_dsa import ML_DSA_44 as M
out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
xi = bytes.fromhex(sys.argv[1])
pk, sk = M._keygen_internal(xi)
def w64(b): return ['%016x' % int.from_bytes(b[8*i:8*i+8], 'little') for i in range(len(b)//8)]
(out / 'pk.bin').write_bytes(pk); (out / 'sk_TEST_ONLY.bin').write_bytes(sk)
(out / 'xi_4x64.mem').write_text('\n'.join(w64(xi)) + '\n')
(out / 'rho_4x64.mem').write_text('\n'.join(w64(pk[:32])) + '\n')
(out / 'k_4x64.mem').write_text('\n'.join(w64(sk[32:64])) + '\n')
t1 = []
for q in range(4):
    blk = pk[32+320*q:32+320*(q+1)]; v = int.from_bytes(blk, 'little')
    t1 += [(v >> (10*i)) & 1023 for i in range(256)]
(out / 't1_512x64.mem').write_text(''.join('%016x\n' % (t1[2*i] | (t1[2*i+1] << 32)) for i in range(512)))
subprocess.check_call(['/tmp/mk_kg_vector', str(out / 'sk_TEST_ONLY.bin'), str(out)])
msg = b'WEPWAWET-CORE seal_v8 phase 3: sign after PL KeyGen'
(out / 'msg.bin').write_bytes(msg)
tr = sk[64:128]; mu = hashlib.shake_256(tr + b'\x00\x00' + msg).digest(64)
(out / 'mu_8x64.mem').write_text('\n'.join(w64(mu)) + '\n')
sig = M.sign(sk, msg, ctx=b'', deterministic=True)
(out / 'signature_REFERENCE_ONLY.bin').write_bytes(sig)
print('KG_VECTOR pk_sha256=%s xi=%s' % (hashlib.sha256(pk).hexdigest(), xi.hex()))
