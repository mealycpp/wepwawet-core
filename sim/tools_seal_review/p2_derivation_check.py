#!/usr/bin/env python3
"""REVIEWER: check the phase-2 PL derivation from the internal trace of a hedged run:
raw = the 1024 bits the PL wrote to b2[1100..1115]; rnd (b2[1044..1047]) == SHAKE256(raw, 32);
rho'' (b2[1056..1063] etc.) == SHAKE256(K || rnd || mu, 64); raw == TRNG words 32..63 of the accepted draw (T lines).
usage: p2_derivation_check.py <rundir>"""
import sys, os, hashlib, collections
rd = sys.argv[1]
K = [int(l, 16) for l in open(os.path.join(rd, 'vectors', 'K_4x64.mem')) if l.strip()]
mu = [int(l, 16) for l in open(os.path.join(rd, 'vectors', 'mu_8x64.mem')) if l.strip()]
le = lambda ws: b''.join(w.to_bytes(8, 'little') for w in ws)
jobs = collections.defaultdict(dict); tw = collections.defaultdict(list); job = 0; last = None
for l in open(os.path.join(rd, 'capture', 'trace_sp_writes.txt')):
    p = l.split()
    if p[0] == 'T': tw[int(p[1])].append(int(p[3], 16)); continue
    ph, cyc, pc, kap, bk, wd, v = int(p[1]), int(p[2]), int(p[3]), int(p[4]), int(p[5]), int(p[6]), int(p[7], 16)
    if ph not in (2, 5) or bk != 2: continue
    jobs[ph][wd] = v if wd not in jobs[ph] or not (1100 <= wd <= 1115 or 1044 <= wd <= 1047 or 1056 <= wd <= 1091) else jobs[ph].get(wd) if False else v
ok = True
for ph in sorted(jobs):
    j = jobs[ph]
    raw = [j.get(1100 + i, 0) for i in range(16)]; rnd = [j.get(1044 + i, 0) for i in range(4)]
    exp_rnd = hashlib.shake_256(le(raw)).digest(32)
    r1 = le(rnd) == exp_rnd
    m = le(K) + le(rnd) + le(mu); exp_rp = hashlib.shake_256(m).digest(64)
    blocks = [le([j.get(1056 + 9 * r + i, 0) for i in range(8)]) == exp_rp for r in range(4)]
    words = tw[ph]
    # raw must be the last 32 TRNG words consumed in this phase (warm-up 32 then 32 kept), pairs (even=low, odd=high)
    kept = words[-32:] if len(words) >= 64 else []
    r3 = kept and [kept[2 * i] | (kept[2 * i + 1] << 32) for i in range(16)] == raw
    print(f'phase {ph}: rnd==SHAKE256(raw)={r1}  rho\'\'==SHAKE256(K||rnd||mu) per block={blocks}  raw==TRNG words[-32:]={bool(r3)} (words consumed {len(words)}) rnd={le(rnd).hex()[:16]}...')
    ok &= r1 and all(blocks)
print('P2_DERIVATION', 'PASS' if ok else 'FAIL')
