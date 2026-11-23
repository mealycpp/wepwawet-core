#!/usr/bin/env python3
"""REVIEWER: hedged KeyGen chain from the internal trace: raw (b2[1100..1115]) == last 32 TRNG words of phase 8,
xi (b2[1160..1163]) == SHAKE256(raw, 32), PQClean KeyGen(xi).pk == pk exported through the window.
usage: p3_derivation_check.py <rundir> <pk.bin>"""
import hashlib, subprocess, os, sys
rd, pkf = sys.argv[1], sys.argv[2]
j = {}; T = []
for l in open(os.path.join(rd, 'capture', 'trace_sp_writes.txt')):
    p = l.split()
    if p[0] == 'T':
        if p[1] == '8': T.append(int(p[3], 16))
        continue
    if p[1] != '8' or p[5] != '2': continue
    wd = int(p[6]); v = int(p[7], 16)
    if 1100 <= wd <= 1115 or 1160 <= wd <= 1163: j[wd] = v
le = lambda ws: b''.join(w.to_bytes(8, 'little') for w in ws)
raw = le([j.get(1100 + i, 0) for i in range(16)]); xi = le([j.get(1160 + i, 0) for i in range(4)])
a = [T[-32:][2 * i] | (T[-32:][2 * i + 1] << 32) for i in range(16)] == [j.get(1100 + i, 0) for i in range(16)]
b = hashlib.shake_256(raw).digest(32) == xi
subprocess.run([os.path.expanduser('~/rv/pqc_oracle'), 'keygen', xi.hex(), '/tmp/kpk.bin', '/tmp/ksk.bin'], check=True, capture_output=True)
c = open('/tmp/kpk.bin', 'rb').read() == open(pkf, 'rb').read()
print(f'raw==TRNG words[-32:]={a} (consumed {len(T)})  xi==SHAKE256(raw)={b}  PQClean KeyGen(xi).pk==PL pk={c}')
print('P3_DERIVATION', 'PASS' if a and b and c else 'FAIL')
