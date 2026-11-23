#!/usr/bin/env python3
"""Recompute every final-window number cited in the paper. Writes paper_numbers.txt.
Final window = mission_runs folders with tags f1,f2,f3,fbase1-3,duplex (snapshot 20261122_1405)."""
import csv, glob, os, re, statistics as st, math, collections
B = '../05_RESULTS/board_logs'
out = []
def P(*a): s = ' '.join(str(x) for x in a); print(s); out.append(s)
def q(v, p):
    v = sorted(v); return v[int(round(p * (len(v) - 1)))]
def runs(host, pat):
    return sorted(d for d in glob.glob(f'{B}/{host}/wepwawet-core/logs/mission_runs/*') if re.search(pat, os.path.basename(d)))
def hw(d):
    f = os.path.join(d, 'hw_stats_run.csv')
    if not os.path.exists(f): return []
    return [r for r in csv.reader(open(f)) if len(r) >= 12 and r[0][:1].isdigit()]
groups = {'pinned': ('aup1', r'fpga_r10_L4_f[123]$'), 'unpinned': ('aup1', r'fpga_r10_L4_unpinned_f[123]$'),
          'duplex_aup1': ('aup1', r'fpga_r10_L4_duplex$'), 'duplex_aup2': ('aup2', r'fpga_r10_L4_duplex$')}
allatt = []
for g, (h, pat) in groups.items():
    R = [r for d in runs(h, pat) for r in hw(d) if r[1] == 'sign' and r[2] == 'fpga' and r[3] == '0']
    if not R: P(g, 'no rows', runs(h, pat)); continue
    att = [int(r[5]) for r in R]; cyc = [int(r[6]) for r in R]
    per = [c / a for c, a in zip(cyc, att)]
    tot = [float(r[11]) for r in R]; wait = [float(r[9]) for r in R]
    pl_us = [c / 300.0 for c in cyc]
    over_pl = [t - p for t, p in zip(tot, pl_us)]
    P(f'[{g}] runs={len(runs(h,pat))} n={len(R)} attempts mean={st.mean(att):.3f} max={max(att)} | per-attempt cycles median={st.median(per):.0f} p99={q(per,.99):.0f} min={min(per):.0f} max={max(per):.0f}')
    P(f'   service total ms median={st.median(tot)/1e3:.2f} p99={q(tot,.99)/1e3:.1f} max={max(tot)/1e3:.1f} | host overhead (total-PL) ms median={st.median(over_pl)/1e3:.2f} p99={q(over_pl,.99)/1e3:.2f}')
    P(f'   prep_us med={st.median([float(r[7]) for r in R]):.0f} preload_us med={st.median([float(r[8]) for r in R]):.0f} readback_us med={st.median([float(r[10]) for r in R]):.0f} wait_ms med={st.median(wait)/1e3:.2f}')
    allatt += att
# geometric goodness of fit, p = 1/4.25
n = len(allatt); p = 1 / 4.25; K = 10
obs = collections.Counter(min(a, K + 1) for a in allatt)
chi = 0; rows = []
for k in range(1, K + 2):
    e = n * ((1 - p) ** (k - 1) * p if k <= K else (1 - p) ** K)
    o = obs.get(k, 0); chi += (o - e) ** 2 / e; rows.append((k, o, round(e, 1)))
mean = st.mean(allatt); se = st.pstdev(allatt) / math.sqrt(n)
P(f'[attempts GOF] n={n} mean={mean:.3f} (FIPS 4.25) SE={se:.3f} z={(mean-4.25)/se:.2f} chi2={chi:.1f} df={K} (5% crit 18.31, 1% crit 23.21) bins={rows}')
# MLE p and its fit
pm = 1 / mean; chi2 = 0
for k in range(1, K + 2):
    e = n * ((1 - pm) ** (k - 1) * pm if k <= K else (1 - pm) ** K); chi2 += (obs.get(k, 0) - e) ** 2 / e
P(f'[attempts GOF, fitted p] p_hat={pm:.4f} chi2={chi2:.1f} df={K-1}')
# duplex verdicts
for h in ('aup1', 'aup2'):
    for d in runs(h, r'_duplex$'):
        t = open(os.path.join(d, 'fsw.log'), errors='replace').read() if os.path.exists(os.path.join(d, 'fsw.log')) else ''
        acc = len(re.findall(r'authenticated receive verdict=ACCEPT', t)); rej = len(re.findall(r'authenticated receive verdict=REJECT', t))
        vf = re.findall(r'WCORE: verify backend=(\S+) rc=(-?\d+) verdict=(-?\d+)', t)
        P(f'[duplex receive {h} {os.path.basename(d)}] ACCEPT={acc} REJECT={rej} verify lines={collections.Counter(vf)}')
# selftests
for f in sorted(glob.glob(f'{B}/aup*/wepwawet-core/logs/selftest_v7_*.log')):
    t = open(f, errors='replace').read()
    P(f'[selftest {os.path.basename(f)}]', ' | '.join(l.strip() for l in t.splitlines() if re.search(r'RESULT|OMEGA|REDRAW|sha|PASS|FAIL|verify', l, re.I))[:600])
open('paper_numbers.txt', 'w').write('\n'.join(out) + '\n')
