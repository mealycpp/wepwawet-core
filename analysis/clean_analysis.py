#!/usr/bin/env python3
"""Analysis of the mission runs reported in the paper (results/mission_runs_clean). Reads run folders only.
usage: clean_analysis.py"""
import csv, json, os, re, statistics as st, glob, sys
ROOT=os.path.abspath(os.path.join(os.path.dirname(__file__),'..'))
B=os.path.join(ROOT,'results','mission_runs_clean'); OUT=os.path.join(ROOT,'results','final_analysis')
MIN=sys.argv[1] if len(sys.argv)>1 else ''
def q(xs,p):
    xs=sorted(xs); return xs[min(len(xs)-1,int(p*len(xs)))] if xs else None
def lj(p):
    if not os.path.exists(p): return {}
    for line in reversed(open(p,errors='replace').read().splitlines()):
        line=line.strip()
        if line.startswith('{'):
            try: return json.loads(line)
            except Exception: pass
    return {}
def row(d,host):
    name=os.path.basename(d); P=json.load(open(os.path.join(d,'params.json')))
    fp=os.path.join(d,'fsw.log'); fsw=open(fp,errors='replace').read() if os.path.exists(fp) else ''
    hp=os.path.join(d,'hw_stats_run.csv')
    rows=[r for r in csv.reader(open(hp)) if len(r)>=12] if os.path.exists(hp) else []
    sign=[r for r in rows if r[1]=='sign' and r[3]=='0']; ver=[r for r in rows if r[1]=='verify']
    lat=[float(r[11])/1e3 for r in sign]
    ts=[float(r[0])/1e6 for r in sign]; gap=max([b-a for a,b in zip(ts,ts[1:])],default=0)
    A=lj(os.path.join(d,'adcs.json')); Pl=lj(os.path.join(d,'payload.json'))
    ap=os.path.join(d,'adcs.csv'); jit=[float(r[3]) for r in list(csv.reader(open(ap)))[1:]] if os.path.exists(ap) else []
    util={}
    cu=os.path.join(d,'cpu_util.csv')
    if os.path.exists(cu):
        for r in csv.reader(open(cu)):
            if len(r)==3: util.setdefault(r[1],[]).append(float(r[2]))
    return dict(run=name,host=host,tag=P.get('tag'),backend=P['backend'],rate=P['rate'],
        crashed=bool(re.search(r'Assert:|abort signal',fsw)),signed=len(sign),
        sign_med_ms=q(lat,.5),sign_p99_ms=q(lat,.99),sign_max_ms=max(lat) if lat else None,sign_gap_max_s=round(gap,2),
        attempts=(round(st.mean(int(r[5]) for r in sign),3) if sign and P['backend']=='fpga' else None),
        verified=len(ver),accepted=sum(1 for r in ver if r[4]=='1'),rejected=sum(1 for r in ver if r[4]=='0'),
        ver_med_ms=q([float(r[11])/1e3 for r in ver],.5),
        adcs_p99_us=q(jit,.99),adcs_max_ms=(max(jit)/1e3 if jit else None),adcs_misses=A.get('deadline_misses'),adcs_skipped=A.get('skipped_releases'),
        pay_wall_s=Pl.get('wall_s'),pay_late_pct=(round(100*Pl['miss_rate'],1) if 'miss_rate' in Pl else None),pay_proc_med_ms=Pl.get('proc_ms_p50'),
        cpu_mean=round(st.mean(st.mean(v) for v in util.values()),1) if util else None)
rows=[]
for host in ('aup1','aup2'):
    for d in sorted(glob.glob(os.path.join(B,host,'*'))):
        n=os.path.basename(d)
        if not os.path.isdir(d) or not re.search(r'_(clean_|cduplex)',n) or n[:len(MIN)]<MIN: continue
        try: rows.append(row(d,host))
        except Exception as e: print('skip',n,e)
os.makedirs(OUT,exist_ok=True)
if rows:
    with open(os.path.join(OUT,'clean_runs.csv'),'w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
def f3(v): return '-' if v is None else (f'{v:.3g}' if isinstance(v,float) else str(v))
keys=['host','tag','signed','sign_med_ms','sign_p99_ms','sign_gap_max_s','attempts','accepted','rejected','adcs_p99_us','adcs_max_ms','adcs_misses','pay_wall_s','pay_late_pct','cpu_mean','crashed']
print(' | '.join(keys))
for r in rows: print(' | '.join(f3(r[k]) for k in keys))
