#!/usr/bin/env python3
"""REVIEWER: offline checker for tb_adv_seal runs.
usage: adv_check.py <rundir> <v7|v8> [--json out.json]
Builds the set of secret / secret-derived 64-bit values from (a) the known-key test vector and (b) the
internal scratchpad write trace (classified by ROM PC, see review/SECRET_MAP.md), then checks every
host-visible word captured in the sweeps, the busy-glitch events and the structural seal rules."""
import sys, os, re, json, collections
rd, mode = sys.argv[1], sys.argv[2]
P2 = mode.startswith('v8p2') or mode.startswith('v8p3'); HEDGED = mode in ('v8p2h', 'v8p3h'); KG = mode.startswith('v8p3')
SEALED = mode.startswith('v8')
REF = sys.argv[sys.argv.index('--vec') + 1] if '--vec' in sys.argv else None      # dir with pk.bin/msg.bin/signature_REFERENCE_ONLY.bin
ORACLE = os.path.expanduser('~/rv/pqc_oracle')                                     # review/tools/pqclean_oracle (PQClean clean ML-DSA-44)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'sign_v1'))
from check_retry_capture import coeffs, canonical_hw_zy, pack_z, pack_hints
import subprocess, tempfile
def assemble(ct, z, h):
    sig = b''.join(w.to_bytes(8, 'little') for w in ct)
    sig += pack_z([canonical_hw_zy(x, 'Z', i) for i, x in enumerate(coeffs(z))])
    hp, wt = pack_hints(coeffs(h)); return sig + hp
V = os.path.join(rd, 'vectors')
def mem(fn):
    if not os.path.exists(os.path.join(V, fn)): return []
    return [int(l, 16) for l in open(os.path.join(V, fn)) if l.strip() and not l.startswith('//')]
Q = 8380417
def small32(x):
    x &= 0xffffffff
    return x < 0x400 or x > 0xffffffff - 0x400 or abs(x - Q) < 0x400
def trivial64(v):
    return v == 0 or (small32(v) and small32(v >> 32))

# ---------------------------------------------------------------- secret sets from the vector
S = {}
for name, fn in [('s1_hat', 's1_hat_512x64.mem'), ('s2_hat', 's2_hat_512x64.mem'), ('t0_hat', 't0_hat_512x64.mem')]:
    for i, v in enumerate(mem(fn)):
        if not trivial64(v): S.setdefault(v, f'S:{name}[{i}]')
seed = mem('candidate_mask_seed_nonce_36x64.mem')
for i in range(8):
    S.setdefault(seed[i], f"S:rho''[{i}]")
for name, fn in [('y', 'y_512x64.mem'), ('r0', 'r0_512x64.mem'), ('ct0', 'ct0_512x64.mem'), ('w', 'w_512x64.mem')]:
    if os.path.exists(os.path.join(V, fn)):
        for i, v in enumerate(mem(fn)):
            if not trivial64(v): S.setdefault(v, f'E(oracle):{name}[{i}]')
if os.path.exists(os.path.join(V, 'K_4x64.mem')):
    for i, v in enumerate(mem('K_4x64.mem')): S.setdefault(v, f'S:K[{i}]')
S32 = {}
for v, lab in S.items():
    if lab.startswith("S:"):
        for h in (v & 0xffffffff, v >> 32):
            if not small32(h): S32.setdefault(h, lab)
PUB = set()
for fn in ['ctilde_4x64.mem', 'z_512x64.mem', 'h_512x64.mem', 'c_hat_128x64.mem', 'mu_8x64.mem', 'rho_4x64.mem', 'w1_encoded_96x64.mem']:
    if os.path.exists(os.path.join(V, fn)): PUB.update(mem(fn))

# ---------------------------------------------------------------- trace classification
P_PCS = set(range(0, 48)) | set(range(68, 81)) | {85}
E_PCS = set(range(48, 68)) | set(range(81, 85)) | set(range(86, 91)) | set(range(103, 141))
Z_PCS = set(range(91, 103)); H_PCS = set(range(141, 145))
trace = collections.defaultdict(list)
tfn = os.path.join(rd, 'capture', 'trace_sp_writes.txt')
for l in open(tfn):
    p = l.split()
    if len(p) < 9 or p[0] != 'W': continue
    ph, cyc, pc, kap, bk, wd = map(int, p[1:7]); v = int(p[7], 16); host = int(p[8])
    trace[ph].append((cyc, pc, kap, bk, wd, v, host))
TRNG32 = set()
for l in open(tfn):
    if l.startswith('T '):
        x = int(l.split()[3], 16)
        if not small32(x): TRNG32.add(x)
events = [l.rstrip('\n') for l in open(os.path.join(rd, 'capture', 'events.txt'))]
def ev(name):
    out = []
    for l in events:
        p = l.split()
        if len(p) > 1 and p[1] == name:
            out.append(dict(x.split('=', 1) for x in p[2:] if '=' in x))
    return out
regs = {e['tag']: e for e in ev('REGS')}
# accepted kappa per sign phase
acc = {}
for ph, tag in [(2, 'sign1_done'), (5, 'sign2_done')]:
    if tag in regs:
        st = int(regs[tag]['status'], 16); ka = int(regs[tag]['kappa_att'], 16) & 0xffff
        acc[ph] = ka if (st & 4) else None
E = {}; RZ = {}; RLOW = {}
for ph, rows in trace.items():
    for cyc, pc, kap, bk, wd, v, host in rows:
        if trivial64(v) or v in PUB: continue
        if KG and ph in (7, 8): continue
        if pc >= 236 and ph not in (3, 4):  # phase-2 prologue: rnd = H(raw), rho'' = H(K||rnd||mu)
            E.setdefault(v, f"E:prologue pc{pc} b{bk}[{wd}] (rnd/rho'')"); continue
        if host and P2 and bk == 2 and (1044 <= wd <= 1047 or 1100 <= wd <= 1115 or 1056 <= wd <= 1091):
            E.setdefault(v, f'E:PL-TRNG/rnd/rho\'\' b{bk}[{wd}]'); continue
        if host:   # retry-manager restore writes (through the host port while host_mode)
            if bk == 2 and wd < 36 and wd % 9 != 8: S.setdefault(v, f"S:rho''(retry-mgr b2[{wd}])")
            continue
        if ph == 3 and pc <= 200: continue   # verify ExpandA / SampleInBall(c~ chosen by host): public
        if ph == 3:  # verify program run over the residue of a sign = secret-derived
            E.setdefault(v, f'E:verify-over-residue pc{pc} b{bk}[{wd}]'); continue
        if ph in (4,): continue        # verify of a public vector
        accepted = (acc.get(ph) == kap)
        if pc in E_PCS: E.setdefault(v, f'E:pc{pc} k{kap} b{bk}[{wd}]')
        elif pc in Z_PCS and not accepted: RZ.setdefault(v, f'R:z(rejected) pc{pc} k{kap} b{bk}[{wd}]')
        elif pc in H_PCS and not accepted: RLOW.setdefault(v, f'R:h(rejected) pc{pc} k{kap} b{bk}[{wd}]')
        elif pc in P_PCS and not accepted: RLOW.setdefault(v, f'R:public-form(rejected) pc{pc} k{kap} b{bk}[{wd}]')
PUBKG = set(); kg_pk_ok = None
if KG:
    _fn = os.path.join(rd, 'capture', 'sweep_p8_after_keygen.txt')
    if os.path.exists(_fn):
        _h = {}
        for l in open(_fn):
            p_ = l.split(); _h[int(p_[1], 16)] = int(p_[2], 16)
        w64 = lambda bk, wd: (_h[(bk << 14) | (wd << 3) | 4] << 32) | _h[(bk << 14) | (wd << 3)]
        rho_hw = [w64(2, 1028 + i) for i in range(4)]
        t1_hw = [w64(3, 1536 + i) for i in range(512)]
        t1_c = []
        for x in t1_hw: t1_c += [x & 0xffffffff, x >> 32]
        _t1f = os.path.join(REF or V, 't1_coeffs.txt')
        t1_pk = [int(t) for t in open(_t1f).read().split()] if os.path.exists(_t1f) else []
        kg_pk_ok = (rho_hw == mem('rho_4x64.mem'), t1_c == t1_pk)
        if all(kg_pk_ok): PUBKG = set(rho_hw) | set(t1_hw)
    for ph, rows in list(trace.items()):
        if ph not in (8, 7): continue
        for cyc, pc, kap, bk, wd, v, host in rows:
            if trivial64(v) or v in PUBKG: continue
            E.setdefault(v, f'E:keygen ph{ph} pc{pc} b{bk}[{wd}]')
# values that were public outputs/forms of an ACCEPTED attempt in any phase are not secret
PUBV = set()
for ph, rows in trace.items():
    for cyc, pc, kap, bk, wd, v, host in rows:
        if acc.get(ph) == kap and (pc in P_PCS or pc in Z_PCS or pc in H_PCS): PUBV.add(v)
for d in (E, RZ, RLOW):
    for v in list(d):
        if v in S or (d is not E and v in PUBV): del d[v]

# ---------------------------------------------------------------- sweeps
def load_sweep(tag):
    fn = os.path.join(rd, 'capture', f'sweep_{tag}.txt')
    if not os.path.exists(fn): return None
    halves = {}; resp = {}
    for l in open(fn):
        p = l.split()
        a = int(p[1], 16); halves[a] = int(p[2], 16); resp[a] = int(p[3])
    return halves, resp
WL_SIGN = lambda bk, wd: (bk == 1 and wd <= 511) or (bk == 1 and 1150 <= wd <= 1153) or (bk == 3 and 1400 <= wd <= 1911)
WL_VER = lambda bk, wd: (bk == 1 and 1150 <= wd <= 1153)
report = {'mode': mode, 'rundir': rd, 'phases': {}, 'fail': [], 'warn': [], 'pass': []}
def F(msg): report['fail'].append(msg)
def W(msg): report['warn'].append(msg)
def P(msg): report['pass'].append(msg)
# Released-output words in the HW representation: taken from the post-SIGN sweep; they are only treated as public
# because the same words are checked below to assemble a signature byte-identical to the PQClean KAT.
OUTW = {}
_sw = None
_fn = os.path.join(rd, 'capture', 'sweep_p2_after_sign.txt')
if os.path.exists(_fn):
    _h = {}
    for l in open(_fn):
        p_ = l.split(); _h[int(p_[1], 16)] = int(p_[2], 16)
    for bk, lo_, hi_ in ((1, 1150, 1153), (3, 1400, 1911), (1, 0, 511)):
        for wd in range(lo_, hi_ + 1):
            a_ = (bk << 14) | (wd << 3); OUTW[(bk, wd)] = (_h[a_ + 4] << 32) | _h[a_]
def backdoor(tag):
    fn = os.path.join(rd, 'capture', f'backdoor_{tag}.txt')
    if not os.path.exists(fn): return None
    m = {}
    for l in open(fn):
        p = l.split(); m[(int(p[1]), int(p[2]))] = int(p[3], 16)
    return m
bd = backdoor('after_sign1')
residue_in_verify_inputs = None
if bd is not None:
    KEY = lambda bk, wd: (bk == 1 and (512 <= wd <= 1023 or wd >= 1536)) or (bk == 2 and wd >= 1536) or (P2 and bk == 2 and 1040 <= wd <= 1043)
    resid = [(bk, wd) for (bk, wd), v in bd.items() if v and bk != 0 and not KEY(bk, wd)
             and not (bk == 2 and ((1048 <= wd <= 1055) if P2 else (1024 <= wd <= 1031))) and OUTW.get((bk, wd)) != v]
    resid_vin = [(bk, wd) for (bk, wd) in resid if bk == 3 and (wd <= 1023 or wd >= 1536)]
    residue_in_verify_inputs = len(resid_vin)
    msg = f'internal scratchpad after SIGN1 (backdoor): {len(resid)} non-zero non-key/non-output/non-public words, {len(resid_vin)} in VERIFY input slots b3[0..1023]/b3[1536..]'
    if SEALED: (F if resid else P)(msg + (f' e.g. {resid[:3]}' if resid else ''))
    else: W(msg + ' (v7: expected, no seal)')
if regs.get('verify_residue_done') and residue_in_verify_inputs == 0:
    for d in (E,):
        for v in list(d):
            if d[v].startswith('E:verify-over-residue'): del d[v]
WL_KG = lambda bk, wd: (bk == 2 and 1028 <= wd <= 1031) or (bk == 3 and wd >= 1536)
SWEEPS = [('p0_reset', None), ('p8_after_keygen', 'keygen'), ('p1_locked_prejob', 'keygen' if KG else None), ('p2_after_sign', 'sign'), ('p3_after_verify_residue', 'verify'),
          ('p5_after_sign2', 'sign'), ('p6_after_zeroize', None), ('p7_after_midreset', None)]
sig = {}
for tag, kind in SWEEPS:
    sw = load_sweep(tag)
    if sw is None: continue
    halves, resp = sw
    if kind == 'sign' and acc.get({'p2_after_sign': 2, 'p5_after_sign2': 5}[tag]) is None:
        kind = None   # SIGN did not succeed (exhausted/error): nothing may be released, signature check skipped
        W(f'{tag}: SIGN did not succeed in this run -> checking that no output (and nothing else) is readable')
    hits = collections.Counter(); first = {}
    nz_outside = 0; nz_examples = []; slverr = 0
    words = {}
    for bk in range(4):
        for wd in range(2048):
            a = (bk << 14) | (wd << 3)
            lo, hi = halves[a], halves[a + 4]
            if resp[a] or resp[a + 4]: slverr += 1
            v = (hi << 32) | lo; words[(bk, wd)] = v
            if trivial64(v): 
                if v and SEALED and not (kind == 'sign' and WL_SIGN(bk, wd)) and not (kind == 'verify' and WL_VER(bk, wd)) and not (kind == 'keygen' and WL_KG(bk, wd)):
                    nz_outside += 1
                continue
            if kind == 'sign' and OUTW.get((bk, wd)) == v: continue      # == oracle public output at this address
            if kind == 'keygen' and WL_KG(bk, wd) and v in PUBKG: continue  # == PQClean pk word
            lab = S.get(v) or E.get(v) or RZ.get(v)
            if lab:
                cls = lab.split(':')[0]; hits[cls] += 1; first.setdefault(cls, f'b{bk}[{wd}]={v:016x} is {lab}')
            elif v in RLOW:
                hits['R-low'] += 1; first.setdefault('R-low', f'b{bk}[{wd}]={v:016x} is {RLOW[v]}')
            if SEALED and not (kind == 'sign' and WL_SIGN(bk, wd)) and not (kind == 'verify' and WL_VER(bk, wd)) and not (kind == 'keygen' and WL_KG(bk, wd)):
                nz_outside += 1
                if len(nz_examples) < 3: nz_examples.append(f'b{bk}[{wd}]={v:016x}')
    rhits = []
    for a in range(0x10000, 0x10200, 4):
        x = halves.get(a)
        if x is not None and not small32(x) and x in S32: rhits.append(f'reg {a:05x}={x:08x} is {S32[x]}')
        if x is not None and not small32(x) and x in TRNG32: rhits.append(f'reg {a:05x}={x:08x} is a raw TRNG word consumed by the PL')
    report['phases'][tag] = {'secret_hits': dict(hits), 'first_hit': first, 'reg_hits': rhits,
                             'nonzero_outside_whitelist': nz_outside, 'examples': nz_examples, 'slverr_words': slverr}
    bad = sum(v for k, v in hits.items() if k != 'R-low')
    if bad or rhits: F(f'{tag}: host read back secret/secret-derived words: {dict(hits)} {first} {rhits[:2]}')
    elif hits.get('R-low'): W(f'{tag}: rejected-attempt public-form values readable: {first.get("R-low")}')
    else: P(f'{tag}: no host-readable word matches any of {len(S)} S + {len(E)} E + {len(RZ)} rejected-z values')
    if SEALED:
        if nz_outside: F(f'{tag}: {nz_outside} non-zero words outside the read whitelist, e.g. {nz_examples}')
        else: P(f'{tag}: every non-whitelisted scratchpad word reads 0')
    if kind == 'sign':
        ct = [words[(1, 1150 + i)] for i in range(4)]; z = [words[(3, 1400 + i)] for i in range(512)]; h = [words[(1, i)] for i in range(512)]
        try:
            sg = assemble(ct, z, h); err = ''
        except Exception as ex:
            sg = None; err = str(ex)
        if sg is None: F(f'{tag}: signature words read through the window do not form a valid encoding: {err}'); continue
        same = REF and sg == open(os.path.join(REF, 'signature_REFERENCE_ONLY.bin'), 'rb').read()
        vok = None
        if REF and os.path.exists(ORACLE):
            with tempfile.NamedTemporaryFile(delete=False) as tf: tf.write(sg)
            vok = subprocess.run([ORACLE, 'verify', os.path.join(REF, 'pk.bin'), os.path.join(REF, 'msg.bin'), tf.name], capture_output=True, text=True).stdout.strip()
        sig[tag] = (same, vok)
        if HEDGED:
            (P if (not same) and vok == 'VERIFY_OK' else F)(f'{tag}: HEDGED signature via window: PQClean verify={vok}, differs from deterministic KAT={not same}')
        else:
            (P if same and vok == 'VERIFY_OK' else F)(f'{tag}: signature read through the window: byte-identical to deterministic PQClean/dilithium-py KAT={same}, PQClean verify={vok}')
    if tag in ('p0_reset', 'p6_after_zeroize', 'p7_after_midreset'):
        nz = sum(1 for v in words.values() if v)
        (P if nz == 0 else F)(f'{tag}: {nz} non-zero scratchpad words after reset/zeroize')
# ---------------------------------------------------------------- events
def resp_of(name): return [int(e.get('resp', -1)) for e in ev(name)]
for name in ['BUSY_RD_S1', 'BUSY_RD_Y', 'BUSY_RD_Z', 'BUSY_RD_B2']:
    for e in ev(name):
        okk = int(e['resp']) == 2 and int(e['data'], 16) == 0
        (P if okk else F)(f'{name}[{e["tag"]}] while busy: resp={e["resp"]} data={e["data"]}')
seedleak = [e for e in ev('BUSY_RD_SEEDREG') if int(e['data'], 16) != 0]
(F if seedleak else P)(f'rho\'\' register page read while busy: {len(seedleak)} non-zero words' + (f' e.g. {seedleak[0]}' if seedleak else ''))
for name in ['BUSY_RELAUNCH_SIGN', 'BUSY_RELAUNCH_VERIFY']:
    for e in ev(name): (P if int(e['resp']) == 2 else F)(f'{name}: resp={e["resp"]}')
for name in ['BUSY_WR_MU_LO', 'BUSY_WR_MU_HI', 'BUSY_WR_SEEDREG', 'BUSY_WR_RHOREG']:
    for e in ev(name): (P if int(e['resp']) == 2 else W)(f'{name} while busy: resp={e["resp"]} (2=SLVERR)')
if SEALED:
    for name in ['LOCKED_RD_S1', 'LOCKED_RD_T0', 'LOCKED_RD_RHOPP', 'LOCKED_RD_K', 'LOCKED_RD_K3']:
        for e in ev(name): (P if int(e['data'], 16) == 0 else F)(f'{name}: data={e["data"]} resp={e["resp"]}')
    if 'after_sealed_reads' in regs:
        s = int(regs['after_sealed_reads']['seal'], 16); st = int(regs['after_sealed_reads']['status'], 16)
        (P if (s & 2) and (st >> 11) & 1 else F)(f'SEAL read-violation sticky after sealed reads: seal={s:08x} status={st:08x}')
    if 'after_sealed_writes' in regs:
        s = int(regs['after_sealed_writes']['seal'], 16)
        (P if (s & 4) else F)(f'SEAL write-violation sticky after sealed writes: seal={s:08x}')
    if 'after_zeroize' in regs:
        s = int(regs['after_zeroize']['seal'], 16)
        (P if (s & 1) == 0 else F)(f'LOCK released only after ZEROIZE completes: seal={s:08x}')
if SEALED:
    if ev('SCRUBWIN_CAUGHT'):
        for name in ['SCRUBWIN_RD_Z', 'SCRUBWIN_RD_Y', 'SCRUBWIN_RD_RHOPP', 'SCRUBWIN_RD_H']:
            for e in ev(name): (P if int(e['data'], 16) == 0 else F)(f'{name} during post-SIGN scrub window: resp={e["resp"]} data={e["data"]}')
        for name in ['SCRUBWIN_WR_Z', 'SCRUBWIN_RELAUNCH', 'SCRUBWIN_LAUNCH_VERIFY']:
            for e in ev(name): (P if int(e['resp']) == 2 else F)(f'{name} during post-SIGN scrub window refused: resp={e["resp"]}')
    else: W('post-SIGN scrub window not caught by the TB poll (no evidence either way)')
for e in ev('VERIFY_VALID_RESULT'):
    (P if e['match_oracle_ctilde_prime'] == '1' else F)(f'proper VERIFY after sign: c~\' == oracle: {e["match_oracle_ctilde_prime"]}')
vr = regs.get('verify_residue_done')
if vr:
    st = int(vr['status'], 16); ctp = [int(e['data'], 16) for e in ev('VERIFY_RESIDUE_CTP')]
    msg = f'VERIFY launched over SIGN residue without z/h/t1 inputs: status={vr["status"]} errors={vr["errors"]} c~\'={"".join(f"{x:016x}" for x in ctp)[:32]}...'
    if residue_in_verify_inputs == 0: P(msg + ' -> VERIFY input slots held no SIGN residue (scrubbed), output is a function of public/host data only')
    elif (st & 4) and any(ctp): (F if SEALED else W)(msg + ' -> verify consumed residue (y in b3[0..511], r0-cs2 in b3[512..1023]) and released a digest of it')
    else: report['pass'].append(msg + ' -> no residue-derived output released')
if KG:
    (P if kg_pk_ok and all(kg_pk_ok) else F)(f'KEYGEN outputs readable through the window (rho b2[1028..1031], t1 b3[1536..2047]) == PQClean pk(xi): rho={kg_pk_ok and kg_pk_ok[0]} t1={kg_pk_ok and kg_pk_ok[1]}')
    bk8 = backdoor('after_keygen')
    if bk8 is not None:
        keep = lambda bk, wd: bk == 0 or (bk == 1 and (512 <= wd <= 1023 or wd >= 1536)) or (bk == 2 and (wd >= 1536 or 1040 <= wd <= 1043 or 1028 <= wd <= 1031)) or (bk == 3 and wd >= 1536)
        res = [(bk, wd) for (bk, wd), v in bk8.items() if v and not keep(bk, wd)]
        (P if not res else F)(f'internal scratchpad after KEYGEN (backdoor): {len(res)} non-zero words outside key homes / A_hat / rho / t1' + (f' e.g. {res[:3]}' if res else ''))
        homes = sum(1 for (bk, wd), v in bk8.items() if v and ((bk == 1 and (512 <= wd <= 1023 or wd >= 1536)) or (bk == 2 and (wd >= 1536 or 1040 <= wd <= 1043))))
        (P if homes > 1500 else F)(f'KEYGEN filled the sealed key homes internally: {homes} non-zero words (s1_hat, s2_hat, t0_hat, K)')
    for e in ev('LOCKED_RELAUNCH_KEYGEN'): pass
    if 'after_lockedkg' in regs:
        s_ = int(regs['after_lockedkg']['seal'], 16); st_ = int(regs['after_lockedkg']['status'], 16)
        (P if (s_ & 4) and not (st_ & 1) else F)(f'KEYGEN while LOCKED refused (write-violation, not running): seal={s_:08x} status={st_:08x}')
    Kv = mem('K_4x64.mem')
    if Kv and bk8 is not None:
        (P if [bk8[(2, 1040 + i)] for i in range(4)] == Kv else F)(f'PL KeyGen K (internal, b2[1040..1043]) == PQClean sk K')
# harness integrity: an aborted/incomplete simulation must never count as a PASS
if ev('JOB_TIMEOUT'): F(f'harness: JOB_TIMEOUT {ev("JOB_TIMEOUT")[0]} (run incomplete)')
if not (ev('END') or ev('STOPPED_AFTER')): F('harness: simulation did not reach END/STOPPED_AFTER (run incomplete)')
report['sizes'] = {'S': len(S), 'E': len(E), 'RZ': len(RZ), 'RLOW': len(RLOW), 'trace_rows': sum(len(r) for r in trace.values())}
report['verdict'] = 'FAIL' if report['fail'] else 'PASS'
out = json.dumps(report, indent=1)
if '--json' in sys.argv: open(sys.argv[sys.argv.index('--json') + 1], 'w').write(out)
print(f"VERDICT {report['verdict']}  fails={len(report['fail'])} warns={len(report['warn'])} passes={len(report['pass'])} sizes={report['sizes']}")
for k in ('fail', 'warn', 'pass'):
    for m in report[k]: print(f'  [{k.upper()}] {m[:400]}')
