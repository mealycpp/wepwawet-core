#!/usr/bin/env python3
"""Final-sweep analysis (2026-11-22, F' sha 70879daa, v7 image). Reads run folders only; writes CSV + MD."""
import csv, json, os, re, statistics as st, glob
ROOT=os.path.abspath(os.path.join(os.path.dirname(__file__),'..'))
B=os.path.join(ROOT,'05_RESULTS','board_logs')
OUT=os.path.join(ROOT,'05_RESULTS','final_analysis')
def q(xs,p):
    xs=sorted(xs); return xs[min(len(xs)-1,int(p*len(xs)))] if xs else None
def lj(p):
    if not os.path.exists(p): return None
    for line in reversed(open(p,errors='replace').read().splitlines()):
        line=line.strip()
        if line.startswith('{'):
            try: return json.loads(line)
            except Exception: pass
def run_rows(host,pat):
    for d in sorted(glob.glob(os.path.join(B,host,'wepwawet-core/logs/mission_runs',pat))):
        name=os.path.basename(d); P=json.load(open(os.path.join(d,'params.json')))
        fp=os.path.join(d,'fsw.log'); fsw=open(fp,errors='replace').read() if os.path.exists(fp) else ''
        crashed=bool(re.search(r'Assert:|abort signal',fsw))
        hp=os.path.join(d,'hw_stats_run.csv')
        sign=[r for r in csv.reader(open(hp)) if len(r)>=12 and r[1]=='sign'] if os.path.exists(hp) else []
        ok=[r for r in sign if r[3]=='0']; lat=[float(r[11])/1e3 for r in ok]
        A=lj(os.path.join(d,'adcs.json')) or {}; Pl=lj(os.path.join(d,'payload.json')) or {}
        ap=os.path.join(d,'adcs.csv'); jit=[float(r[3]) for r in list(csv.reader(open(ap)))[1:]] if os.path.exists(ap) else []
        cfg=('nocrypto' if P['rate']==0 else P['backend']+('_rt%d'%P.get('signer_prio',0) if P.get('signer_prio',0) else '')+('_unpinned' if P.get('pinning')=='none' else ''))
        util={}
        for r in csv.reader(open(os.path.join(d,'cpu_util.csv'))):
            if len(r)==3: util.setdefault(r[1],[]).append(float(r[2]))
        yield dict(run=name,host=host,cfg=cfg,tag=P.get('tag'),crashed=crashed,requested=P['rate']*P['seconds'],signed=len(ok),
            sign_med_ms=q(lat,.5),sign_p99_ms=q(lat,.99),sign_max_ms=max(lat) if lat else None,
            attempts_mean=(st.mean(int(r[5]) for r in ok) if ok and P['backend']=='fpga' else None),
            adcs_jit_med_us=q(jit,.5),adcs_jit_p99_us=q(jit,.99),adcs_jit_p999_us=q(jit,.999),
            adcs_jit_max_ms=(max(jit)/1e3 if jit else None),adcs_stalls_gt100ms=sum(1 for j in jit if j>1e5),adcs_skipped=A.get('skipped_releases'),adcs_misses=A.get('deadline_misses'),
            pay_wall_s=Pl.get('wall_s'),pay_proc_med_ms=Pl.get('proc_ms_p50'),pay_proc_p99_ms=Pl.get('proc_ms_p99'),pay_MBps_busy=Pl.get('throughput_MBps_busy'),
            cpu_mean=round(st.mean(st.mean(v) for v in util.values()),1) if util else None)
rows=list(run_rows('aup1','*_f[123]'))+list(run_rows('aup1','*fbase[123]'))+list(run_rows('aup1','*duplex'))+list(run_rows('aup2','*duplex'))+list(run_rows('aup1','*duplexv8*'))+list(run_rows('aup1','2026112302[2-3]*_v8f[123]'))+list(run_rows('aup1','*_v8base[123]'))+list(run_rows('aup2','*duplexv8*'))  # first v8f attempt (02:02-02:08 UTC) had a stale peer key on the receiver: excluded by the 02[2-3] glob
os.makedirs(OUT,exist_ok=True)
with open(os.path.join(OUT,'final_runs.csv'),'w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
def fmt(v): return '-' if v is None else (f'{v:.3g}' if isinstance(v,float) else str(v))
keys=['cfg','host','tag','crashed','signed','sign_med_ms','sign_p99_ms','sign_max_ms','attempts_mean','adcs_jit_p99_us','adcs_jit_p999_us','adcs_jit_max_ms','adcs_stalls_gt100ms','adcs_skipped','pay_wall_s','pay_proc_med_ms','pay_proc_p99_ms','pay_MBps_busy','cpu_mean']
with open(os.path.join(OUT,'final_runs.md'),'w') as f:
    f.write('| '+' | '.join(keys)+' |\n|'+'---|'*len(keys)+'\n')
    for r in sorted(rows,key=lambda r:(r['tag'] or '',r['cfg'])): f.write('| '+' | '.join(fmt(r[k]) for k in keys)+' |\n')
print(open(os.path.join(OUT,'final_runs.md')).read())
