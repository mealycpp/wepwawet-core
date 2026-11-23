#!/usr/bin/env python3
"""Collect mission_run folders (run_summary.json) into one CSV and print CPU-signer vs FPGA-signer table.
usage: python3 analyze.py RUNS_DIR [--tag TAG] [--csv out.csv]
Load-program JSON field names are matched by candidate keys (see FIELDS); unknown names -> blank."""
import argparse, csv, glob, json, os

FIELDS = {   # metric -> (section, candidate keys in the load's JSON summary)
    'adcs_deadline_misses': ('adcs', ['deadline_misses', 'misses', 'missed_deadlines', 'overruns']),
    'adcs_cycles':          ('adcs', ['cycles', 'iterations', 'ticks', 'n']),
    'adcs_exec_p99_us':     ('adcs', ['exec_us.p99', 'exec_p99_us', 'p99_exec_us', 'exec_us_p99', 'compute_p99_us']),
    'adcs_jitter_p99_us':   ('adcs', ['release_jitter_us.p99', 'jitter_p99_us', 'p99_jitter_us', 'latency_p99_us', 'wakeup_jitter_p99_us']),
    'payload_deadline_misses': ('payload', ['deadline_misses', 'misses', 'missed_deadlines', 'late_frames']),
    'payload_frames':       ('payload', ['frames', 'frames_done', 'n_frames']),
    'adcs_final_pointing_err_deg': ('adcs', ['final_pointing_error_deg']),
    'payload_proc_p99_ms':  ('payload', ['proc_ms_p99']),
    'payload_busy_frac':    ('payload', ['cpu_busy_fraction_per_thread']),
    'payload_MBps':         ('payload', ['throughput_MBps_busy', 'MBps', 'mbps', 'throughput_MBps', 'throughput_mbps', 'input_MBps']),
}


def pick(d, keys):
    if not isinstance(d, dict): return None
    for k in keys:                            # dotted keys address nested fields, e.g. exec_us.p99
        if '.' in k:
            a, b = k.split('.', 1)
            if isinstance(d.get(a), dict) and b in d[a]: return d[a][b]
    for k in keys:
        if k in d: return d[k]
    for v in d.values():                      # one level of nesting (e.g. {"summary": {...}})
        if isinstance(v, dict):
            for k in keys:
                if k in v: return v[k]
    return None


ap = argparse.ArgumentParser(); ap.add_argument('runs'); ap.add_argument('--tag'); ap.add_argument('--csv')
a = ap.parse_args()
rows = []
for f in sorted(glob.glob(os.path.join(a.runs, '*', 'run_summary.json'))):
    S = json.load(open(f)); P = S.get('params') or {}
    if a.tag and a.tag not in (P.get('tag') or ''): continue
    r = dict(run=os.path.basename(os.path.dirname(f)), mock=bool(P.get('mock')), backend=P.get('backend'),
             rate=P.get('rate'), load=P.get('load_level'), seconds=P.get('seconds'))
    for m, (sec, keys) in FIELDS.items(): r[m] = pick(S.get(sec), keys)
    sg = S.get('sign') or {}; fp = S.get('fprime') or {}; dr = S.get('driver') or {}
    r.update(sign_requested=sg.get('requested'), sign_ok=sg.get('ok'), sign_failed=sg.get('failed'),
             sign_p50_ms=sg.get('lat_ms_p50'), sign_p99_ms=sg.get('lat_ms_p99'), sign_max_ms=sg.get('lat_ms_max'),
             peer_accepted=fp.get('peer_accepted'), peer_failed=fp.get('peer_failed'),
             cycle_slips=fp.get('cycle_slips'), hw_errors=fp.get('hw_errors'), queue_full=fp.get('queue_full'),
             driver_rate=dr.get('achieved_rate'), driver_late=dr.get('late_sends'))
    for core, u in (S.get('cpu_util_mean') or {}).items(): r['util_' + core] = u
    rows.append(r)
if not rows:
    raise SystemExit('no run_summary.json found')
cols = sorted({k for r in rows for k in r}, key=lambda k: list(rows[0]).index(k) if k in rows[0] else 999)
out = a.csv or os.path.join(a.runs, f"all_runs{('_' + a.tag) if a.tag else ''}.csv")
with open(out, 'w', newline='') as fh:
    w = csv.DictWriter(fh, fieldnames=cols); w.writeheader(); w.writerows(rows)
fmt = lambda v: '-' if v is None else (f'{v:.2f}' if isinstance(v, float) else str(v))
show = ['rate', 'load', 'adcs_deadline_misses', 'adcs_jitter_p99_us', 'payload_deadline_misses', 'payload_MBps',
        'sign_ok', 'sign_p50_ms', 'sign_p99_ms', 'peer_accepted', 'cycle_slips'] + sorted(k for k in cols if k.startswith('util_'))
if any(r['mock'] for r in rows): print('*** MOCK DATA PRESENT: NOT A MEASUREMENT ***')
print('CPU signer (PQClean on A53) vs FPGA signer (fabric), same load and rate; means over repeats\n')
cells = {}
for r in rows: cells.setdefault((r['rate'], r['load']), {}).setdefault(r['backend'], []).append(r)
def mean(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return sum(xs) / len(xs) if xs else None
print(' | '.join(['backend'] + show))
for key in sorted(cells, key=lambda k: (k[0] or 0, k[1] or 0)):
    for b in ('cpu', 'fpga'):
        rs = cells[key].get(b)
        if not rs: continue
        print(' | '.join([b] + [fmt(mean([x.get(c) for x in rs])) for c in show]))
    print('-' * 40)
print('CSV:', out)
