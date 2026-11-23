// WEPWAWET-CORE dashboard: log parsers and replay models. Nothing here invents a value:
// every field comes from a file under 05_RESULTS; missing data stays null.
"use strict";
const HW_COLS = ["mono_us","op","backend","rc","verdict","attempts","pl_cycles","trng_us","preload_us","wait_us","readback_us","host_total_us"];

async function fetchText(url){ const r = await fetch(url); if(!r.ok) return null; return await r.text(); }
async function fetchJSON(url){ const t = await fetchText(url); if(t==null) return null; try{ return JSON.parse(t);}catch(e){ return null; } }

function parseHwRow(line){
  const f = line.trim().split(",");
  if (f.length < 12) return null;
  const o = {}; HW_COLS.forEach((c,i)=>{ o[c] = (i===1||i===2) ? f[i] : Number(f[i]); });
  return o;
}
function parseHwCsv(text){ if(!text) return []; return text.split(/\r?\n/).map(parseHwRow).filter(Boolean); }

function parseCsvHeader(text){
  if(!text) return [];
  const L = text.split(/\r?\n/).filter(s=>s.length); if(!L.length) return [];
  const h = L[0].split(","); const out=[];
  for(let i=1;i<L.length;i++){ const f=L[i].split(","); if(f.length<h.length) continue; const o={}; h.forEach((k,j)=>o[k]=isNaN(+f[j])?f[j]:+f[j]); out.push(o); }
  return out;
}
// cpu_util.csv: epoch,cpuN,util  -> [{e, u:[c0,c1,c2,c3]}]
function parseCpu(text){
  if(!text) return [];
  const m = new Map();
  for(const line of text.split(/\r?\n/)){ const f=line.split(","); if(f.length<3) continue;
    const e=+f[0], k=+String(f[1]).replace("cpu",""), v=+f[2]; if(!isFinite(e)||!isFinite(k)) continue;
    if(!m.has(e)) m.set(e,[null,null,null,null]); m.get(e)[k]=v; }
  return [...m.entries()].sort((a,b)=>a[0]-b[0]).map(([e,u])=>({e,u}));
}
// F' console log: WCORE lines get the epoch of the next F' EVENT line (EVENT carries (2:sec,usec)).
function parseFsw(text){
  const res = {signs:[], verifies:[], recv:[], assert:null, assertEpoch:null, firstEpoch:null, lastEpoch:null};
  if(!text) return res;
  const raw = text.split(/\r?\n/);
  const items = []; // {kind, data, idx}
  const evEpoch = new Array(raw.length).fill(null);
  for(let i=0;i<raw.length;i++){
    const m = raw[i].match(/\(2:(\d+),(\d+)\)/);
    if(m){ evEpoch[i] = (+m[1]) + (+m[2])/1e6; if(res.firstEpoch==null) res.firstEpoch=evEpoch[i]; res.lastEpoch=evEpoch[i]; }
  }
  const nextEv = new Array(raw.length).fill(null), prevEv = new Array(raw.length).fill(null);
  let nx=null; for(let i=raw.length-1;i>=0;i--){ if(evEpoch[i]!=null) nx=evEpoch[i]; nextEv[i]=nx; }
  let pv=null; for(let i=0;i<raw.length;i++){ if(evEpoch[i]!=null) pv=evEpoch[i]; prevEv[i]=pv; }
  for(let i=0;i<raw.length;i++){
    const segs = raw[i].split("\\n");
    for(const s of segs){
      let m;
      if((m = s.match(/WCORE: sign backend=(\S+) rc=(-?\d+) verdict=(-?\d+) attempts=(\d+) pl_cycles=(\d+) pl_us=([\d.]+) host_total_us=([\d.]+)/)))
        res.signs.push({line:i, epoch: nextEv[i]!=null?nextEv[i]:prevEv[i], backend:m[1], rc:+m[2], attempts:+m[4], pl_cycles:+m[5], host_ms:+m[7]/1000});
      else if((m = s.match(/WCORE: verify backend=(\S+) rc=(-?\d+) verdict=(-?\d+) attempts=(\d+) pl_cycles=(\d+) pl_us=([\d.]+) host_total_us=([\d.]+)/)))
        res.verifies.push({line:i, epoch: nextEv[i]!=null?nextEv[i]:prevEv[i], backend:m[1], rc:+m[2], verdict:+m[3], pl_cycles:+m[5], host_ms:+m[7]/1000});
      else if((m = s.match(/authenticated receive verdict=(\w+)/)))
        res.recv.push({line:i, epoch: nextEv[i]!=null?nextEv[i]:prevEv[i], verdict:m[1]});
      if(res.assert==null && s.indexOf("Assert:")>=0){ res.assert = s.trim(); res.assertEpoch = prevEv[i]; }
    }
  }
  return res;
}
// AUP2 global hw-stats CSV -> clusters of verify events separated by > 20 s of silence
function clusterVerifies(rows){
  const v = rows.filter(r=>r.op==="verify"); const cl=[]; let cur=[];
  for(const r of v){ if(cur.length && r.mono_us - cur[cur.length-1].mono_us > 20e6){ cl.push(cur); cur=[]; } cur.push(r); }
  if(cur.length) cl.push(cur); return cl;
}
function quantile(arr,q){ if(!arr.length) return null; const a=[...arr].sort((x,y)=>x-y); const p=(a.length-1)*q, lo=Math.floor(p), hi=Math.ceil(p); return a[lo]+(a[hi]-a[lo])*(p-lo); }

const RunCache = new Map();
let AUP2HW = undefined;
async function aup2HwRows(){
  if(AUP2HW!==undefined) return AUP2HW;
  const t = await fetchText("data/board_logs/aup2/wepwawet-core/logs/fprime_hw_stats.csv");
  AUP2HW = t ? parseHwCsv(t) : null; return AUP2HW;
}

// ---------- mission run (AUP1 sender under mission load, AUP2 receiver) ----------
async function loadMission(name){
  if(RunCache.has(name)) return RunCache.get(name);
  const base = "data/mission_runs/"+encodeURIComponent(name)+"/";
  const [params, summary, cpuT, hwT, adcsT, payT, fswT, adcsJ, payJ, chkT] = await Promise.all([
    fetchJSON(base+"params.json"), fetchJSON(base+"run_summary.json"), fetchText(base+"cpu_util.csv"),
    fetchText(base+"hw_stats_run.csv"), fetchText(base+"adcs.csv"), fetchText(base+"payload.csv"),
    fetchText(base+"fsw.log"), fetchJSON(base+"adcs.json"), fetchJSON(base+"payload.json"), fetchText(base+"check_before.txt")]);
  const notes = [];
  const cpu = parseCpu(cpuT);
  const fsw = parseFsw(fswT);
  let t0;
  if(cpu.length){ t0 = cpu[0].e - 1.0; notes.push("Time zero = mission-load start, taken as the first 1 Hz CPU sample minus one second (±0.5 s)."); }
  else if(params && params.started_epoch){ t0 = params.started_epoch; notes.push("Time zero = harness start (no CPU samples)."); }
  else if(fsw.firstEpoch){ t0 = fsw.firstEpoch; } else t0 = 0;
  // AUP1 signs from hw_stats_run.csv (monotonic µs) aligned to wall clock through the F' log
  const hw = parseHwCsv(hwT).filter(r=>r.op==="sign");
  let off = null;
  const n = Math.min(hw.length, fsw.signs.length);
  for(let i=0;i<n;i++){ const e=fsw.signs[i].epoch; if(e==null) continue; const o=e - hw[i].mono_us/1e6; if(off==null||o<off) off=o; }
  if(off==null && summary && summary.driver && summary.driver.t_first && hw.length){ off = summary.driver.t_first - hw[0].mono_us/1e6; notes.push("Sign times aligned to the first PeerPing command (no F′ event pairing)."); }
  const signs = hw.map((r,i)=>({ t: off!=null ? r.mono_us/1e6 + off - t0 : null, mono:r.mono_us, backend:r.backend, rc:r.rc,
     attempts:r.attempts, pl_cycles:r.pl_cycles, trng_us:r.trng_us, host_ms:r.host_total_us/1000, idx:i+1 })).filter(s=>s.t!=null);
  // AUP2 verifies: cluster in AUP2's own hw-stats log, matched by time (boards share boot time) and checked by count
  let verifies = [], vnote = "AUP2 verify log not available.";
  const rows2 = await aup2HwRows();
  if(rows2 && hw.length){
    const cl = clusterVerifies(rows2); const s0 = hw[0].mono_us;
    let best=null, bd=Infinity; for(const c of cl){ const d=Math.abs(c[0].mono_us - s0); if(d<bd){bd=d;best=c;} }
    if(best && bd < 30e6){
      const m = Math.min(best.length, hw.length); let dmin=Infinity;
      for(let i=0;i<m;i++) dmin=Math.min(dmin,(best[i].mono_us-hw[i].mono_us)/1e6);
      const shift = (dmin<0||dmin>1) ? dmin : 0;
      verifies = best.map((r,i)=>({ t: r.mono_us/1e6 - shift + off - t0, verdict:r.verdict, rc:r.rc, pl_cycles:r.pl_cycles, host_ms:r.host_total_us/1000, idx:i+1 })).sort((x,y)=>x.t-y.t);
      vnote = `AUP2 verify records matched: ${best.length} verifies for ${hw.length} signs (AUP2 clock mapped through AUP1's; matched in order).`;
    } else vnote = "No AUP2 verify records found near this run.";
  }
  notes.push(vnote);
  const links = signs.map((s,i)=>({ from:"aup1", to:"aup2", tSign:s.t, tVerify: verifies[i] ? Math.max(verifies[i].t, s.t) : null,
      verdict: verifies[i] ? verifies[i].verdict : null, idx:s.idx }));
  const adcs = parseCsvHeader(adcsT).map(r=>({t:r.t_s, exec:r.exec_us, jit:r.jitter_us, miss:r.miss, point_err:r.point_err_deg, sunlit:r.sunlit})).sort((x,y)=>x.t-y.t);
  const pay = parseCsvHeader(payT).map(r=>({t:r.start_s, end:r.start_s + r.proc_us/1e6, proc_ms:r.proc_us/1000, miss:r.deadline_miss, thread:r.thread, cpu:r.cpu})).sort((x,y)=>x.t-y.t);
  const crash = fsw.assert ? { t: fsw.assertEpoch!=null ? fsw.assertEpoch - t0 : null, text: fsw.assert } : null;
  const ends = [cpu.length?cpu[cpu.length-1].e-t0:0, adcs.length?adcs[adcs.length-1].t:0, pay.length?pay[pay.length-1].end:0,
                signs.length?signs[signs.length-1].t:0, verifies.length?verifies[verifies.length-1].t:0];
  const M = { kind:"mission", name, params, summary, adcsJ, payJ, t0, duration: Math.max(...ends)+1, notes, crash,
    aup1:{ cpu: cpu.map(c=>({t:c.e-t0,u:c.u})), signs, verifies:[], backend: params?params.backend:null, role:"sender",
           adcs, pay, params, key: keyEvidence(fswT, chkT, params?params.backend:null, params&&params.rate===0) },
    aup2:{ cpu: null, signs:[], verifies, backend:"fpga", role:"receiver", adcs:[], pay:[], params:null, key:null },
    links, adcs, pay };
  RunCache.set(name, M); return M;
}


// ---------- key custody, stated only from evidence in the run folder ----------
// sealed: F' log line "signing key SEALED in the PL" AND the image check (VERSION 0x0003000x / "key SEALED").
function keyEvidence(fswText, checkText, backend, noSigning){
  const f = fswText||"", c = checkText||"";
  const ver = (c.match(/VERSION=0x([0-9a-fA-F]{8})/)||[])[1] || null;
  if(/signing key SEALED in the PL/.test(f) && (/key SEALED/.test(c) || (ver && /^0003000[23]$/.test(ver)))){
    const kg = ver && ver.toLowerCase()==="00030003";
    return { state:"sealed", version: ver, text: kg ? "key generated + sealed in fabric" : "key sealed in fabric",
             evidence: "F′ log: “signing key SEALED in the PL” · image check VERSION 0x"+(ver||"?")+(/locked=1/.test(c)?" locked=1":"") };
  }
  if(noSigning) return null;
  if(backend==="fpga" && ver && /^0002/.test(ver)) return { state:"host", version:ver, text:"key provisioned by host", evidence:"image check VERSION 0x"+ver+" (no seal)" };
  if(backend && backend!=="fpga") return { state:"cpu", version:ver, text:"key in host memory (CPU signer)", evidence:"F′ backend "+backend };
  return null;
}

// ---------- duplex mission run: the same run recorded on BOTH boards (board_logs/<board>/.../mission_runs/<run>) ----------
async function loadBoardRun(board, name){
  const base = "data/board_logs/"+board+"/wepwawet-core/logs/mission_runs/"+encodeURIComponent(name)+"/";
  const [params, summary, cpuT, hwT, adcsT, payT, fswT, adcsJ, payJ, chkT] = await Promise.all([
    fetchJSON(base+"params.json"), fetchJSON(base+"run_summary.json"), fetchText(base+"cpu_util.csv"),
    fetchText(base+"hw_stats_run.csv"), fetchText(base+"adcs.csv"), fetchText(base+"payload.csv"),
    fetchText(base+"fsw.log"), fetchJSON(base+"adcs.json"), fetchJSON(base+"payload.json"), fetchText(base+"check_before.txt")]);
  const cpu = parseCpu(cpuT), fsw = parseFsw(fswT), hw = parseHwCsv(hwT);
  const sHw = hw.filter(r=>r.op==="sign"), vHw = hw.filter(r=>r.op==="verify");
  // monotonic -> wall clock on this board, through the F' EVENT timestamps (smallest offset = tightest bound)
  let off = null;
  const pairOff = (rows, evs)=>{ const n=Math.min(rows.length, evs.length); for(let i=0;i<n;i++){ const e=evs[i].epoch; if(e==null) continue; const o=e-rows[i].mono_us/1e6; if(off==null||o<off) off=o; } };
  pairOff(sHw, fsw.signs); if(off==null) pairOff(vHw, fsw.verifies);
  const recvAcc = fsw.recv.filter(r=>r.verdict==="ACCEPT").length, recvRej = fsw.recv.filter(r=>r.verdict!=="ACCEPT").length;
  return { board, name, params, summary, adcsJ, payJ, cpu, fsw, sHw, vHw, off, adcsT, payT, chkT, fswT, recvAcc, recvRej, hasFsw: fswT!=null };
}
// Each PeerPing is synchronous (sign -> send -> the receiver verifies -> acknowledge), so a verify on the receiver
// belongs to the latest earlier sign of the sender. A constant clock difference between the boards is estimated
// only if pairing at zero difference fails for more than 2% of the verifies; the value used is reported on screen.
function pairByTime(S, V, win){
  const run = (d)=>{ const m=new Array(S.length).fill(-1); let i=0, last=-1, n=0;
    for(let k=0;k<V.length;k++){ const tv=V[k].t-d; while(i<S.length && S[i].t<=tv){ last=i; i++; }
      if(last>=0 && m[last]<0 && tv-S[last].t<=win){ m[last]=k; n++; } }
    return {m,n,d}; };
  let best = run(0);
  if(V.length && best.n < 0.98*V.length){ for(let d=-3; d<=3.0001; d+=0.02){ const r=run(d); if(r.n>best.n || (r.n===best.n && Math.abs(r.d)<Math.abs(best.d))) best=r; } }
  return best;
}
async function loadDuplex(pair){
  const key = "duplex:"+pair.aup1+"|"+pair.aup2;
  if(RunCache.has(key)) return RunCache.get(key);
  const [b1,b2] = await Promise.all([loadBoardRun("aup1",pair.aup1), loadBoardRun("aup2",pair.aup2)]);
  const starts = [b1,b2].map(b=> b.cpu.length ? b.cpu[0].e-1 : (b.params&&b.params.started_epoch) || b.fsw.firstEpoch).filter(x=>x!=null);
  const t0 = starts.length ? Math.min(...starts) : 0;
  const notes = ["Duplex run: both boards carry the mission load, sign to each other and verify each other's frames. Time zero = the earlier board's first 1 Hz CPU sample minus one second (±0.5 s)."];
  const mk = (b)=>{
    const loadStart = b.cpu.length ? b.cpu[0].e-1 : t0;
    const signs = b.sHw.map((r,i)=>({ t: b.off!=null ? r.mono_us/1e6 + b.off - t0 : null, backend:r.backend, rc:r.rc, attempts:r.attempts, pl_cycles:r.pl_cycles,
        trng_us:r.trng_us, host_ms:r.host_total_us/1000, idx:i+1 })).filter(s=>s.t!=null);
    const verifies = b.vHw.map((r,i)=>({ t: b.off!=null ? r.mono_us/1e6 + b.off - t0 : null, verdict:r.verdict, rc:r.rc, backend:r.backend, pl_cycles:r.pl_cycles,
        host_ms:r.host_total_us/1000, idx:i+1 })).filter(v=>v.t!=null);
    const sh = loadStart - t0;
    const adcs = parseCsvHeader(b.adcsT).map(r=>({t:r.t_s+sh, exec:r.exec_us, jit:r.jitter_us, miss:r.miss, point_err:r.point_err_deg, sunlit:r.sunlit})).sort((x,y)=>x.t-y.t);
    const pay = parseCsvHeader(b.payT).map(r=>({t:r.start_s+sh, end:r.start_s+sh + r.proc_us/1e6, proc_ms:r.proc_us/1000, miss:r.deadline_miss, thread:r.thread, cpu:r.cpu})).sort((x,y)=>x.t-y.t);
    const backend = b.params ? b.params.backend : (signs[0]?signs[0].backend:null);
    return { cpu: b.cpu.map(c=>({t:c.e-t0,u:c.u})), signs, verifies, backend, role:"sender + receiver · mission load", adcs, pay, params:b.params,
             summary:b.summary, adcsJ:b.adcsJ, payJ:b.payJ, recvLog: b.hasFsw ? {acc:b.recvAcc, rej:b.recvRej} : null,
             key: keyEvidence(b.fswT, b.chkT, backend, false),
             crash: b.fsw.assert ? { t: b.fsw.assertEpoch!=null ? b.fsw.assertEpoch-t0 : null, text: b.fsw.assert } : null };
  };
  const A = mk(b1), B = mk(b2);
  const dir = (S, V, from, to)=>{ const P = pairByTime(S, V, 2.5);
    const L = S.map((s,i)=>{ const k=P.m[i]; return { from, to, tSign:s.t, tVerify: k>=0 ? Math.max(V[k].t-P.d, s.t) : null, verdict: k>=0 ? V[k].verdict : null, idx:s.idx }; });
    notes.push(`${from.toUpperCase()}→${to.toUpperCase()}: ${S.length} signs, ${V.length} verify records on the receiver, ${P.n} paired (each verify matched to the sender's latest earlier sign within 2.5 s; board clock difference used: ${P.d.toFixed(2)} s).`);
    return L; };
  const links = [...dir(A.signs, B.verifies, "aup1", "aup2"), ...dir(B.signs, A.verifies, "aup2", "aup1")].sort((x,y)=>x.tSign-y.tSign);
  const win = (X)=> X.signs.length ? [X.signs[0].t, X.signs[X.signs.length-1].t] : null; const w1=win(A), w2=win(B);
  if(w1 && w2){ const ov = Math.max(0, Math.min(w1[1],w2[1]) - Math.max(w1[0],w2[0]));
    notes.push(`Sending windows from the logs: AUP1 T+${w1[0].toFixed(1)}–${w1[1].toFixed(1)} s, AUP2 T+${w2[0].toFixed(1)}–${w2[1].toFixed(1)} s; both boards were sending at the same time for ${ov.toFixed(1)} s. A frame sent while the peer's F′ was not up has no verify record.`); }
  for(const [nm,X] of [["AUP1",A],["AUP2",B]]) if(X.recvLog && X.recvLog.acc+X.recvLog.rej !== X.verifies.length)
    notes.push(`${nm} F′ log holds ${X.recvLog.acc} ACCEPT / ${X.recvLog.rej} REJECT receive verdicts for the whole F′ session; the per-run CSV (cut when the board's own window ended) holds ${X.verifies.length} verify records, and only those are drawn.`);
  const ends = [];
  for(const X of [A,B]){ if(X.cpu.length) ends.push(X.cpu[X.cpu.length-1].t); if(X.adcs.length) ends.push(X.adcs[X.adcs.length-1].t); if(X.pay.length) ends.push(X.pay[X.pay.length-1].end);
    if(X.signs.length) ends.push(X.signs[X.signs.length-1].t); if(X.verifies.length) ends.push(X.verifies[X.verifies.length-1].t); }
  const crash = A.crash ? {t:A.crash.t, text:"AUP1 "+A.crash.text} : B.crash ? {t:B.crash.t, text:"AUP2 "+B.crash.text} : null;
  const M = { kind:"duplex", name: pair.aup1, pair, params: b1.params, summary: b1.summary, adcsJ:b1.adcsJ, payJ:b1.payJ, t0,
    duration: (ends.length?Math.max(...ends):0)+1, notes, crash, aup1:A, aup2:B, links, adcs:A.adcs, pay:A.pay };
  RunCache.set(key, M); return M;
}

// ---------- bidirectional node run (wcore_node.sh on both boards, no mission load) ----------
async function loadNode(pair){
  const key = "node:"+pair.aup1+"|"+pair.aup2;
  if(RunCache.has(key)) return RunCache.get(key);
  const [t1,t2] = await Promise.all([
    fetchText("data/board_logs/aup1/wepwawet-core/logs/"+pair.aup1+"/fsw.log"),
    fetchText("data/board_logs/aup2/wepwawet-core/logs/"+pair.aup2+"/fsw.log")]);
  const f1=parseFsw(t1), f2=parseFsw(t2);
  const all=[...f1.signs,...f1.verifies,...f2.signs,...f2.verifies].map(x=>x.epoch).filter(x=>x!=null);
  const t0 = all.length ? Math.min(...all)-1 : 0;
  const mk = (arr)=>arr.filter(x=>x.epoch!=null).map((x,i)=>Object.assign({},x,{t:x.epoch-t0, idx:i+1}));
  const s1=mk(f1.signs), v1=mk(f1.verifies), s2=mk(f2.signs), v2=mk(f2.verifies);
  const pairUp=(S,V,from,to)=>S.map((s,i)=>({from,to,tSign:s.t,tVerify:V[i]?Math.max(V[i].t,s.t):null,verdict:V[i]?V[i].verdict:null,idx:s.idx}));
  const links=[...pairUp(s1,v2,"aup1","aup2"),...pairUp(s2,v1,"aup2","aup1")].sort((a,b)=>a.tSign-b.tSign);
  const ends=[...links.map(l=>l.tVerify||l.tSign)];
  const crash = f1.assert ? {t:f1.assertEpoch-t0,text:"AUP1 "+f1.assert} : (f2.assert ? {t:f2.assertEpoch-t0,text:"AUP2 "+f2.assert} : null);
  const M = { kind:"node", name:"bidirectional "+pair.aup1.slice(5)+" / "+pair.aup2.slice(5), params:null, summary:null, t0,
    duration:(ends.length?Math.max(...ends):0)+2, crash,
    notes:["Bidirectional F′ exchange (wcore_node.sh), no mission load. The console log has no timestamp on sign/verify lines, so each is placed at the next F′ EVENT timestamp on that board: an upper bound that can be seconds late. Counts, verdicts and cycle numbers are exact."],
    aup1:{cpu:null, signs:s1, verifies:v1, backend:s1[0]?s1[0].backend:null, role:"sender+receiver", adcs:[], pay:[], params:null, key:null},
    aup2:{cpu:null, signs:s2, verifies:v2, backend:s2[0]?s2[0].backend:null, role:"sender+receiver", adcs:[], pay:[], params:null, key:null},
    links, adcs:[], pay:[] };
  RunCache.set(key,M); return M;
}

// ---------- statistics for the compare view (computed from the files, not copied from summaries) ----------
function runStats(M){
  const S = {};
  const sg = M.aup1.signs.filter(s=>s.rc===0);
  S.signed = M.aup1.signs.length ? sg.length : null;
  S.requested = M.summary && M.summary.sign ? M.summary.sign.requested : null;
  const lat = sg.map(s=>s.host_ms);
  S.signMed = quantile(lat,.5); S.sign99 = quantile(lat,.99); S.signMax = lat.length?Math.max(...lat):null;
  const fab = sg.filter(s=>s.backend==="fpga");
  S.attempts = fab.length ? fab.reduce((a,s)=>a+s.attempts,0)/fab.length : null;
  const v = M.aup2.verifies;
  S.accepted = v.length ? v.filter(x=>x.verdict===1).length : (M.links.length?0:null);
  S.rejected = v.length ? v.filter(x=>x.verdict!==1).length : (M.links.length?0:null);
  const j = M.adcs.map(a=>a.jit);
  S.adcsMed = quantile(j,.5); S.adcs99 = quantile(j,.99); S.adcsMax = j.length?Math.max(...j):null;
  S.adcsMiss = M.adcs.length ? M.adcs.reduce((a,x)=>a+(x.miss?1:0),0) : null;
  S.adcsSkipped = M.adcsJ ? M.adcsJ.skipped_releases : null;
  const p = M.pay.map(x=>x.proc_ms);
  S.payN = M.pay.length || null;
  S.payMissPct = M.pay.length ? 100*M.pay.reduce((a,x)=>a+(x.miss?1:0),0)/M.pay.length : null;
  S.payMed = quantile(p,.5); S.pay99 = quantile(p,.99);
  if(M.aup1.cpu && M.aup1.cpu.length){ S.cpu = [0,1,2,3].map(k=>{ const a=M.aup1.cpu.map(c=>c.u[k]).filter(x=>x!=null); return a.length? a.reduce((x,y)=>x+y,0)/a.length : null; }); }
  S.crashed = !!M.crash;
  return S;
}
