#!/usr/bin/env python3
"""REVIEWER: hedged-KeyGen stage 2 inputs. Rebuild pk = rho || SimpleBitPack(t1,10) from the host-readable KEYGEN
outputs of a stage-1 run, then mu = H(H(pk)||0||0||msg). usage: kg_from_sweep.py <stage1_rundir> <msg_vecdir> <outdir>"""
import sys, os, hashlib
rd, vd, od = sys.argv[1:4]; os.makedirs(od, exist_ok=True)
h = {}
for l in open(os.path.join(rd, 'capture', 'sweep_p8_after_keygen.txt')):
    p = l.split(); h[int(p[1], 16)] = int(p[2], 16)
w64 = lambda bk, wd: (h[(bk << 14) | (wd << 3) | 4] << 32) | h[(bk << 14) | (wd << 3)]
rho = b''.join(w64(2, 1028 + i).to_bytes(8, 'little') for i in range(4))
t1 = []
for i in range(512): x = w64(3, 1536 + i); t1 += [x & 0xffffffff, x >> 32]
assert all(0 <= c < 1024 for c in t1), 't1 out of range'
acc = 0
for i, c in enumerate(t1): acc |= c << (10 * i)
pk = rho + acc.to_bytes(1280, 'little')
msg = open(os.path.join(vd, 'msg.bin'), 'rb').read()
mu = hashlib.shake_256(hashlib.shake_256(pk).digest(64) + b'\x00\x00' + msg).digest(64)
open(os.path.join(od, 'pk.bin'), 'wb').write(pk); open(os.path.join(od, 'msg.bin'), 'wb').write(msg)
w = lambda b: ''.join('%016x\n' % int.from_bytes(b[8*i:8*i+8], 'little') for i in range(len(b) // 8))
open(os.path.join(od, 'mu_8x64.mem'), 'w').write(w(mu)); open(os.path.join(od, 'rho_4x64.mem'), 'w').write(w(rho))
open(os.path.join(od, 't1_coeffs.txt'), 'w').write(' '.join(map(str, t1)) + '\n')
for fn, n in (('s1_hat_512x64.mem', 512), ('s2_hat_512x64.mem', 512), ('t0_hat_512x64.mem', 512), ('candidate_mask_seed_nonce_36x64.mem', 36), ('xi_4x64.mem', 4)):
    open(os.path.join(od, fn), 'w').write('0000000000000000\n' * n)
open(os.path.join(od, 'signature_REFERENCE_ONLY.bin'), 'wb').write(b'')   # hedged: no KAT; verify under pk only
print('KG_STAGE2_OK pk_sha256', hashlib.sha256(pk).hexdigest()[:16])
