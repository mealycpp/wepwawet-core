#!/usr/bin/env python3
"""Aggregate profile_trace.csv (tb_profile.sv monitor) into per-instruction, per-stage, per-category tables."""
import csv, sys, json, collections
from pathlib import Path
def f(v, hi, lo): return (v >> lo) & ((1 << (hi - lo + 1)) - 1)
LANE = {0: 'NTT', 1: 'INTT', 2: 'PMUL', 3: 'SHAKE256', 4: 'SHAKE128'}
AUX = {0x01: 'FREEZE', 0x02: 'CENTER', 0x03: 'HIGHBITS', 0x04: 'LOWBITS', 0x10: 'ADD', 0x11: 'SUB', 0x12: 'MAKE_HINT',
       0x13: 'USE_HINT', 0x20: 'NORM_Z', 0x21: 'NORM_W0', 0x22: 'NORM_CT0', 0x30: 'REJNTT', 0x31: 'SAMPLEINBALL',
       0x32: 'GAMMA1_UNPACK', 0x33: 'DOT4', 0x34: 'ETA2', 0x35: 'EXPANDA_IN', 0x36: 'W1ENCODE', 0x37: 'CHAL_MSG',
       0x38: 'C*S1', 0x39: 'C*S2', 0x3A: 'C*T0'}
def stage(pc):
    if pc == 999: return 'retry restore / ack / inter-attempt'
    if pc <= 47: return 'ExpandA (SHAKE128+RejNTT, 16 polys)'
    if pc <= 55: return 'ExpandMask (SHAKE256+Gamma1 unpack)'
    if pc <= 59: return 'NTT(y)'
    if pc <= 67: return 'A*y DOT4' if pc % 2 == 0 else 'INTT(w)'
    if pc <= 71: return 'HighBits(w)'
    if pc == 72: return 'w1Encode'
    if pc == 73: return 'mu||w1 message build'
    if pc == 74: return 'H(mu||w1) -> c~'
    if pc == 75: return 'SHAKE256(c~) XOF for SampleInBall'
    if pc == 76: return 'SampleInBall'
    if pc <= 80: return 'copy w1 (FREEZE)'
    if pc <= 84: return 'LowBits(w)'
    if pc == 85: return 'NTT(c)'
    if pc in (86, 103, 120): return {86: 'c*s1 DOT', 103: 'c*s2 DOT', 120: 'c*t0 DOT'}[pc]
    if 87 <= pc <= 90: return 'INTT(cs1)'
    if 104 <= pc <= 107: return 'INTT(cs2)'
    if 121 <= pc <= 124: return 'INTT(ct0)'
    if 91 <= pc <= 102: return 'z = y+cs1, center, ||z|| check'
    if 108 <= pc <= 119: return 'r0 = w0-cs2, center, ||r0|| check'
    if 125 <= pc <= 140: return 'ct0 center/norm, w0-cs2+ct0'
    if 141 <= pc <= 144: return 'MakeHint'
    return 'control (branch/inc/halt)'
PER_SIG = {'ExpandA (SHAKE128+RejNTT, 16 polys)'}
def classify(r):
    pc = int(r['pc']); ins = int(r['instr'], 16); op = f(ins, 63, 60)
    st = [int(r[f'st{i}']) for i in range(32)]; tot = int(r['end']) - int(r['start'])
    c = collections.Counter()
    if pc == 999: c['CONTROL/GAP'] += tot; return c, 'RETRY', tot
    c['CONTROL/GAP'] += sum(st[1:5]) + st[15]                      # fetch/decode/ack
    if op == 0:
        cfg = sum(st[5:10]) + st[11] + st[12]                       # configure + ap_start AXI-Lite
        c['CONFIG'] += cfg
        kw = st[10] + st[13] + st[14]
        txb, rxb = int(r['tx_beats']), int(r['rx_beats'])
        tf, tl, rf, rl = (int(r[k]) for k in ('tx_first', 'tx_last', 'rx_first', 'rx_last'))
        tx = (tl - tf + 1) if txb else 0
        rx = (rl - rf + 1) if rxb else 0
        overlap = max(0, min(tl, rl) - max(tf, rf) + 1) if txb and rxb else 0
        comp = max(0, rf - tl - 1) if txb and rxb else 0
        trans = tx + rx - overlap
        c['TRANSPORT'] += min(trans, kw); c['COMPUTE'] += min(comp, max(0, kw - trans))
        c['CONTROL/GAP'] += max(0, kw - trans - comp)
        kind = 'K:' + LANE.get(f(ins, 59, 57), '?')
    elif op == 8:
        aw = st[28] + st[29]; a = f(ins, 59, 52)
        pmb = int(r['pm_busy'])
        if a in (0x33, 0x38, 0x39, 0x3A):
            c['COMPUTE'] += min(pmb, aw); c['AUX'] += max(0, aw - pmb)   # HLS polymul busy vs RTL dot4 (B fetch/acc/AXI-Lite)
        else:
            c['AUX'] += aw
        kind = 'A:' + AUX.get(a, hex(a))
    else:
        kind = {3: 'BRANCH', 4: 'INC', 7: 'HALT'}.get(op, f'op{op}')
    c['CONTROL/GAP'] += tot - sum(c.values())
    return c, kind, tot
def main(run):
    rows = list(csv.DictReader(open(Path(run) / 'capture' / 'profile_trace.csv')))
    # split attempts: a new attempt starts at each pc==0 record
    att, cur = [], []
    for r in rows:
        if int(r['pc']) == 0 and cur and any(int(x['pc']) == 0 for x in cur): att.append(cur); cur = []
        cur.append(r)
    att.append(cur)
    out = dict(run=str(run), attempts=len(att), total=sum(int(r['end']) - int(r['start']) for r in rows), per_attempt=[])
    per_instr = []
    for ai, a in enumerate(att):
        stg = collections.OrderedDict(); cat = collections.Counter(); tot_a = 0
        for r in a:
            c, kind, tot = classify(r); s = stage(int(r['pc'])); tot_a += tot
            d = stg.setdefault(s, collections.Counter()); d.update(c); d['_total'] += tot; d['_n'] += 1
            cat.update(c)
            if ai == 0:
                per_instr.append(dict(pc=int(r['pc']), kind=kind, start=int(r['start']), end=int(r['end']), cycles=tot,
                    cfg_axil_txn=int(r['cfg_hs']), tx_beats=int(r['tx_beats']), rx_beats=int(r['rx_beats']),
                    tx_window=(int(r['tx_last']) - int(r['tx_first']) + 1) if int(r['tx_beats']) else 0,
                    tx_to_rx_gap=(int(r['rx_first']) - int(r['tx_last']) - 1) if int(r['tx_beats']) and int(r['rx_beats']) else None,
                    rx_window=(int(r['rx_last']) - int(r['rx_first']) + 1) if int(r['rx_beats']) else 0,
                    hls_ap=(int(r['k_done']) - int(r['k_first']) + 1) if int(r['k_first']) >= 0 and int(r['k_done']) >= 0 else None,
                    hls_busy=int(r['k_busy']), polymul_busy=int(r['pm_busy']), polymul_axil_txn=int(r['pm_axil']),
                    aux_sp_rd=int(r['sp_rd']), aux_sp_wr=int(r['sp_wr']), cat=dict(c)))
        out['per_attempt'].append(dict(total=tot_a, categories=dict(cat),
            stages={k: dict(v) for k, v in stg.items()}))
    Path(run, 'profile_summary.json').write_text(json.dumps(dict(out, per_instr=per_instr), indent=1))
    print(json.dumps({k: v for k, v in out.items() if k != 'per_attempt'}))
    for i, a in enumerate(out['per_attempt']):
        print(f'attempt {i}: total={a["total"]} cat=' + json.dumps(a['categories']))
if __name__ == '__main__': main(sys.argv[1])
