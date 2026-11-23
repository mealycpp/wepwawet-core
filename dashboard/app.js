// WEPWAWET-CORE dashboard: UI, replay engine, live engine.
"use strict";
const $ = (s)=>document.querySelector(s);
const FPRIME_PIN = {0:"F′ sign task", 1:"F′ verify task", 2:"F′ transport", 3:"F′ gateway"}; // instances.fpp cpu 0..3
const fmtInt = (x)=> x==null||!isFinite(x) ? "—" : Math.round(x).toLocaleString("en-US");
const fmt = (x,d=1)=> x==null||!isFinite(x) ? "—" : Number(x).toFixed(d);
const fmtUs = (us)=> us==null||!isFinite(us) ? "—" : (us>=1e6 ? (us/1e6).toFixed(2)+" s" : us>=1e3 ? (us/1e3).toFixed(1)+" ms" : us.toFixed(0)+" µs");
const ND = '<span class="nodata">no data</span>';

const S = { mode:"replay", M:null, T:0, playing:false, speed:5, lastWall:null, stage:null, runs:null,
  cur:null, packets:[], log:[], live:null, tlBase:null };

// ---------------- panels ----------------
function boardPanel(id, name){
  const p = $("#p-"+id);
  p.innerHTML = `
   <div class="bhead"><span class="bname">${name.toUpperCase()}</span><span class="badge none" data-r="badge">—</span>
     <span class="muted" data-r="role"></span>
     <div class="flags"><span class="flag" data-r="fFsw">F′</span><span class="flag" data-r="fAdcs">ADCS</span><span class="flag" data-r="fPay">PAYLOAD</span></div></div>
   <div class="ptitle">Four Cortex-A53 cores <span class="muted" data-r="cpuNote"></span></div>
   <div class="cores">${[0,1,2,3].map(k=>`<div class="core"><span class="lbl" data-r="cl${k}"><b>core ${k}</b></span><span class="bar"><i data-r="cb${k}"></i></span><span class="v" data-r="cv${k}">—</span></div>`).join("")}</div>
   <div class="cards">
     <div class="card" data-r="cSigned"><div class="k">Frames signed</div><div class="n" data-r="signed">—</div><div class="d" data-r="signedD"></div></div>
     <div class="card" data-r="cVer"><div class="k">Peer frames verified here</div><div class="n" data-r="ver">—</div><div class="d" data-r="verD"></div></div>
     <div class="card"><div class="k">Sign time (host, end to end)</div><div class="n" data-r="lat">—</div><div class="d" data-r="latD"></div></div>
     <div class="card"><div class="k">PL fabric, last operation</div><div class="n" data-r="pl">—</div><div class="d" data-r="plD"></div></div>
     <div class="card" data-r="cAdcs"><div class="k">ADCS release jitter, last second</div><div class="n" data-r="adcs">—</div><div class="d" data-r="adcsD"></div></div>
     <div class="card" data-r="cPay"><div class="k">Payload deadline misses</div><div class="n" data-r="pay">—</div><div class="d" data-r="payD"></div></div>
   </div>`;
  const R = {}; p.querySelectorAll("[data-r]").forEach(e=>R[e.dataset.r]=e); return R;
}
function centerPanel(){
  const p = $("#p-link");
  p.innerHTML = `<div class="ptitle">Crosslink</div>
   <div class="big3">
     <div class="card"><div class="k">Frames sent</div><div class="n" data-r="sent">—</div><div class="d" data-r="sentD"></div></div>
     <div class="card good"><div class="k">FPGA verify accept</div><div class="n" data-r="acc">—</div><div class="d" data-r="accD"></div></div>
     <div class="card"><div class="k">Reject / no record</div><div class="n" data-r="rej">—</div><div class="d" data-r="rejD"></div></div>
   </div>
   <div class="ptitle">Run</div><div class="kv" data-r="kv"></div>
   <div class="legend"><span><i style="background:#d4af37"></i>frame in flight</span><span><i style="background:#3fd38a"></i>accepted by peer FPGA verify</span><span><i style="background:#ff5d5d"></i>rejected</span><span><i style="background:#7b869f"></i>no verify record</span></div>
   <div class="legend">On each CubeSat: the gold chip is the PL fabric (lights on every sign or verify), the LED is the on-die TRNG draw, the lens lights when the imager pipeline finishes a frame.</div>
   <div class="muted" data-r="notes" style="margin-top:6px"></div>`;
  const R = {}; p.querySelectorAll("[data-r]").forEach(e=>R[e.dataset.r]=e); return R;
}
function setNum(el, html, cls){ el.innerHTML = html; if(cls!==undefined){ const c=el.closest(".card"); if(c){ c.classList.remove("good","bad","warn"); if(cls) c.classList.add(cls);} } }
function coreLabels(R, M, board){
  let roles = {0:[],1:[],2:[],3:[]};
  const P = M && M[board] ? M[board].params : null;
  if(P){
    const co = String(P.core_order||"").split(/\s+/).map(Number); const L = P.load_level||0;
    if(L>=1 && co.length) roles[co[0]].push(`ADCS (FIFO ${P.adcs_prio||""})`);
    for(let i=1;i<Math.min(L,co.length);i++) roles[co[i]].push("payload CCSDS-121");
  }
  for(let k=0;k<4;k++){ roles[k].push(FPRIME_PIN[k]); R["cl"+k].innerHTML = `<b>core ${k}</b> · ${roles[k].join(" + ")}`; }
}
function badge(R, backend, what){
  const b = R.badge; b.className = "badge " + (backend==="fpga"?"fabric": backend? "cpu":"none");
  const w = what||"SIGNER";
  b.textContent = backend==="fpga" ? "FABRIC "+w : backend ? ((backend==="cpu-neon"||backend==="cpu")?"CPU-NEON":backend.toUpperCase())+" "+w : "NO CRYPTO ACTIVITY";
}
function logLine(t, html){
  S.log.push(`<div><span class="t">${t}</span> ${html}</div>`); if(S.log.length>400) S.log.splice(0,S.log.length-400);
  S.logDirty = true;
}
function flushLog(){ if(!S.logDirty) return; const L=$("#log"); const stick = L.scrollTop+L.clientHeight >= L.scrollHeight-20; L.innerHTML=S.log.join(""); if(stick) L.scrollTop=L.scrollHeight; S.logDirty=false; }
function banner(text, cls){ const b=$("#banner"); if(!text){ b.hidden=true; return;} b.hidden=false; b.className=cls||""; b.textContent=text; }

// ---------------- stage effects ----------------
function pulseChip(sat, kind){
  sat.chip.setAttribute("fill", kind==="verify" ? "#2fd38a" : "#f2d27a"); sat.chip.setAttribute("filter","url(#glow)");
  clearTimeout(sat._ct); sat._ct = setTimeout(()=>{ sat.chip.setAttribute("fill","#1c3a2c"); sat.chip.removeAttribute("filter"); }, 260);
}
function flashTrng(sat){ sat.trng.setAttribute("fill","#7dffb5"); sat.trng.setAttribute("filter","url(#glow)");
  clearTimeout(sat._tt); sat._tt = setTimeout(()=>{ sat.trng.setAttribute("fill","#203a2c"); sat.trng.removeAttribute("filter"); }, 180); }
function flashLens(sat){ sat.lensFlash.setAttribute("opacity","0.55"); clearTimeout(sat._lt); sat._lt=setTimeout(()=>sat.lensFlash.setAttribute("opacity","0"),90); }

const PK = []; // svg packet pool
function drawPackets(list, T, travel){
  const st = S.stage, g = st.packets;
  while(PK.length < list.length){ const grp=el("g",{},g); const halo=el("circle",{r:11,opacity:0.25},grp); const dot=el("circle",{r:5.5},grp); const tx=el("text",{y:-14,"text-anchor":"middle","font-size":10,"font-family":"Consolas,monospace",fill:"#e8ecf5"},grp); PK.push({grp,halo,dot,tx}); }
  for(let i=0;i<PK.length;i++){
    const P = PK[i];
    if(i>=list.length){ P.grp.setAttribute("visibility","hidden"); continue; }
    const L = list[i]; P.grp.setAttribute("visibility","visible");
    let p = Math.min(1, Math.max(0,(T - L.tSign)/travel));
    const pos = L.from==="aup1" ? st.path.getPointAtLength(p*st.len) : st.path2.getPointAtLength(p*st.len2);
    let col = "#d4af37", op = 1;
    const arrive = L.tSign + travel;
    if(p>=1){
      if(L.tVerify!=null && T >= L.tVerify){ col = L.verdict===1 ? "#3fd38a" : "#ff5d5d"; const age = T - Math.max(L.tVerify, arrive); op = Math.max(0, 1 - age/(travel*0.9)); }
      else if(L.tVerify==null){ col="#7b869f"; op = Math.max(0, 1-(T-arrive)/(travel*1.5)); }
      else { col = "#ffffff"; op = 0.6+0.4*Math.sin(T*12); }
    }
    P.dot.setAttribute("cx",pos.x); P.dot.setAttribute("cy",pos.y); P.dot.setAttribute("fill",col);
    P.halo.setAttribute("cx",pos.x); P.halo.setAttribute("cy",pos.y); P.halo.setAttribute("fill",col);
    P.tx.setAttribute("x",pos.x); P.tx.setAttribute("y",pos.y-13); P.tx.textContent = "#"+L.idx;
    P.grp.setAttribute("opacity", op.toFixed(2));
  }
}

// ---------------- run picker ----------------
function runLabel(name){
  const m = name.match(/^(\d{8})_(\d{2})(\d{2})(\d{2})_(\w+?)_r(\d+)_L(\d+)(?:_(.+))?$/);
  if(!m) return name;
  const be = m[5]==="fpga" ? "FABRIC" : "CPU-NEON";
  const what = m[6]==="0" ? "no signing (baseline)" : `${be} · ${m[6]} frames/s`;
  return `${m[2]}:${m[3]} UTC · ${what} · load ${m[7]}${m[8]?" · "+m[8]:""}`;
}
function exclList(){ let x=S.runs&&S.runs.excluded; if(x && !Array.isArray(x) && Array.isArray(x.value)) x=x.value; /* PowerShell 5.1 wraps re-serialised JSON arrays as {value,Count} */ const a=Array.isArray(x)? x.flat() : x? [x] : []; return a.filter(e=>e && typeof e.match==='string' && e.match.length); }
function exclOf(name){ for(const e of exclList()){ try{ if(new RegExp(e.match).test(name)) return e; }catch(x){} } return null; }
function runTag(run){ const e=exclOf(run.name||run.aup1); return (run.crashed?"✖ CRASHED — excluded · ":"") + (e?"⚠ "+e.tag+" · ":""); }
async function loadRuns(){
  const r = await fetch("api/runs"); S.runs = await r.json();
  const pick = $("#runPick"); pick.innerHTML = "";
  const dupNames = new Set((S.runs.duplex||[]).map(d=>d.aup1));
  if(S.runs.duplex && S.runs.duplex.length){
    const og=document.createElement("optgroup"); og.label="Duplex under mission load · both boards sign and verify (both boards' logs)";
    S.runs.duplex.forEach((d,i)=>{ const o=document.createElement("option"); o.value="d:"+i; o.textContent=runTag(d)+runLabel(d.aup1); og.appendChild(o); });
    pick.appendChild(og);
  }
  const groups = {};
  for(const run of S.runs.mission){
    const day = run.name.slice(0,8); const g = run.name.indexOf("smoke")>=0 ? "Smoke runs" : "Mission-load sweep";
    const key = g+" "+day; (groups[key]=groups[key]||[]).push(run);
  }
  for(const key of Object.keys(groups).sort().reverse()){
    const og = document.createElement("optgroup"); og.label = key.replace(/(\d{4})(\d{2})(\d{2})$/,"$1-$2-$3")+" · AUP1 sends, AUP2 verifies";
    for(const run of groups[key]){ const o=document.createElement("option"); o.value="m:"+run.name;
      o.textContent=runTag(run)+runLabel(run.name)+(/duplex/.test(run.name)?" · AUP1 half only"+(dupNames.has(run.name)?" (see duplex group)":""):""); og.appendChild(o); }
    pick.appendChild(og);
  }
  if(S.runs.node && S.runs.node.length){
    const og=document.createElement("optgroup"); og.label="Bidirectional F′ exchange (no mission load)";
    S.runs.node.forEach((n,i)=>{ const o=document.createElement("option"); o.value="n:"+i; o.textContent=`${n.aup1.slice(14,16)}:${n.aup1.slice(16,18)} · ${n.aup1} ↔ ${n.aup2}`; og.appendChild(o); });
    pick.appendChild(og);
  }
  // default: newest usable duplex pair, else newest usable fabric signing run
  const okDup = (S.runs.duplex||[]).map((d,i)=>[d,i]).filter(([d])=>!d.crashed && !exclOf(d.aup1));
  const good = S.runs.mission.filter(r=>!r.crashed && !exclOf(r.name) && /_fpga_r[1-9]/.test(r.name) && !/duplex/.test(r.name)).map(r=>r.name).sort();
  if(okDup.length) pick.value = "d:"+okDup.sort((a,b)=>a[0].aup1<b[0].aup1?-1:1)[okDup.length-1][1];
  else if(good.length) pick.value = "m:"+good[good.length-1];
  for(const sel of [$("#cmpA"),$("#cmpB")]){ sel.innerHTML = ""; S.runs.mission.forEach(run=>{ const o=document.createElement("option"); o.value=run.name; o.textContent=runTag(run)+runLabel(run.name); sel.appendChild(o); }); }
}

// ---------------- replay ----------------
async function openReplay(val){
  S.playing=false; $("#play").textContent="▶";
  banner("Loading run…","info");
  let M;
  if(val.startsWith("m:")) M = await loadMission(val.slice(2));
  else if(val.startsWith("d:")) M = await loadDuplex(S.runs.duplex[+val.slice(2)]);
  else M = await loadNode(S.runs.node[+val.slice(2)]);
  S.M = M; S.T = 0; S.log = []; S.logDirty=true;
  S.cur = { s1:0, v1:0, s2:0, v2:0, pay:0, pay2:0, adcs:0, crashLogged:false };
  S.R1 = boardPanel("aup1","AUP1"); S.R2 = boardPanel("aup2","AUP2"); S.RC = centerPanel();
  coreLabels(S.R1, M, "aup1"); coreLabels(S.R2, M, "aup2");
  badge(S.R1, M.aup1.backend && (M.aup1.signs.length? M.aup1.backend : (M.params&&M.params.rate===0? null : M.aup1.backend)));
  if(M.kind==="mission") badge(S.R2, "fpga", "VERIFIER"); else badge(S.R2, M.aup2.signs.length ? M.aup2.backend : null);
  if(M.kind==="duplex"){ badge(S.R1, M.aup1.backend, "SIGN + VERIFY"); badge(S.R2, M.aup2.backend, "SIGN + VERIFY"); }
  S.R1.role.textContent = M.aup1.role; S.R2.role.textContent = M.aup2.role;
  for(const R of [S.R1,S.R2]) for(const f of ["fFsw","fAdcs","fPay"]) R[f].style.display="none";
  if(M.kind==="mission" && M.params && M.params.rate===0) badge(S.R1, null);
  const kv = [];
  if(M.kind==="mission"){
    const p=M.params||{};
    kv.push(["Run", M.name], ["Signer on AUP1", p.rate===0? "none (baseline)": (p.backend==="fpga"?"FPGA fabric":"CPU NEON (PQClean)")],
      ["Verifier on AUP2","FPGA fabric"], ["Signing rate", p.rate!=null? p.rate+" frames/s requested":"—"],
      ["Mission load", p.load_level!=null? `level ${p.load_level}: ADCS ${p.adcs_rate} Hz on core ${String(p.core_order).split(" ")[0]}, imager ${p.payload_rate} frames/s per payload core`:"—"],
      ["Imager data", M.payJ? `${M.payJ.frame}, ${M.payJ.algorithm.split(" (")[0]}`:"—"],
      ["Recorded span", fmt(M.duration,1)+" s"]);
  } else if(M.kind==="duplex"){
    const p=M.params||{}, q=M.aup2.params||{}; const sg=(x)=> x.backend==="fpga"?"FPGA fabric":"CPU NEON (PQClean)";
    kv.push(["Run", M.name+(M.pair.aup2!==M.pair.aup1?" / "+M.pair.aup2:"")], ["Mode","duplex: both boards sign, both verify, both under mission load"],
      ["Signer AUP1 / AUP2", sg(p)+" / "+sg(q)], ["Signing rate", p.rate!=null? p.rate+" frames/s requested each way":"—"],
      ["Mission load (each board)", p.load_level!=null? `level ${p.load_level}: ADCS ${p.adcs_rate} Hz, imager ${p.payload_rate} frames/s per payload core`:"—"],
      ["Recorded span", fmt(M.duration,1)+" s"]);
  } else kv.push(["Run", M.name], ["Mode","both boards sign and verify"], ["Recorded span", fmt(M.duration,1)+" s"]);
  // key custody + public-key file, only from evidence
  for(const [b,nm,Sat] of [["aup1","AUP1",S.stage.A],["aup2","AUP2",S.stage.B]]){
    const k = M[b].key; setKeyBadge(Sat, k, k? "" : (M.kind==="mission"&&b==="aup2" ? "key custody: not recorded in this run" : ""));
    if(k) kv.splice(Math.min(2,kv.length), 0, [nm+" signing key", k.text+" — "+k.evidence]);
    const pk = S.runs.pk && S.runs.pk[b];
    if(k && k.state==="sealed" && pk && pk.mtime <= M.t0+5) kv.push([nm+" public key file", `${pk.file} · sha256 ${pk.sha256.slice(0,16)}… · exported ${new Date(pk.mtime*1000).toISOString().slice(11,19)} UTC, before this run`]);
  }
  setupGround(M);
  S.RC.kv.innerHTML = kv.map(([a,b])=>`<span>${a}</span><span>${b}</span>`).join("");
  S.RC.notes.innerHTML = M.notes.map(n=>"• "+n).join("<br>");
  const ex = exclOf(M.name);
  if(M.crash) banner(`This run is excluded from the paper: F′ stopped on an assertion${M.crash.t!=null?" at t = "+fmt(M.crash.t,1)+" s":""} — ${M.crash.text}`);
  else if(ex) banner(`${ex.tag}: ${ex.reason}`);
  else banner(null);
  S.stage.sub.textContent = M.kind==="mission" ? "replay of a recorded run · times from board logs" : M.kind==="duplex" ? "replay of a recorded duplex run · each board's own logs · verdict colour from the receiver" : "replay of a recorded bidirectional exchange";
  const one = M.kind==="mission"; S.stage.path2.style.opacity = S.stage.glowPath2.style.opacity = S.stage.dirB.style.opacity = one ? "0.25" : "1";
  S.tlBase = null; drawTimeline();
  renderReplay(true);
}
function sliceCount(arr, T, key="t"){ let n=0; for(const x of arr){ if(x[key]!=null && x[key]<=T) n++; else if(x[key]>T) break; } return n; }
function renderReplay(force){
  const M = S.M; if(!M) return; const T = S.T, C = S.cur;
  const travel = Math.min(1.5, Math.max(0.6, 0.3*S.speed));   // drawn travel time in run seconds (visibility only)
  // fire new events since last render
  const batch = [];
  const fire = (arr, ptrKey, fn)=>{ while(C[ptrKey] < arr.length && arr[C[ptrKey]].t <= T){ const x=arr[C[ptrKey]]; batch.push([x.t,()=>fn(x)]); C[ptrKey]++; } };
  const ts = (t)=>"T+"+fmt(t,2).padStart(6)+" s";
  fire(M.aup1.signs,"s1",(s)=>{ pulseChip(S.stage.A,"sign"); if(s.backend==="fpga"&&s.trng_us>0) flashTrng(S.stage.A);
     S.stage.A.readout.textContent = s.backend==="fpga" ? `PL sign #${s.idx} · ${fmtInt(s.pl_cycles)} cycles · ${s.attempts} attempt${s.attempts>1?"s":""}` : `CPU-NEON sign #${s.idx} · ${fmt(s.host_ms,2)} ms (fabric idle)`;
     logLine(ts(s.t), `<span class="s">AUP1</span> signed frame #${s.idx} on ${s.backend==="fpga"?"FABRIC":"CPU-NEON"}${s.backend==="fpga"?` · ${s.attempts} attempt(s) · ${fmtInt(s.pl_cycles)} cycles`:""} · ${fmt(s.host_ms,2)} ms`+(s.rc!==0?` <span class="bad">rc=${s.rc}</span>`:"")); });
  fire(M.aup2.verifies,"v2",(v)=>{ pulseChip(S.stage.B,"verify"); S.stage.B.readout.textContent = `PL verify #${v.idx} · ${fmtInt(v.pl_cycles)} cycles · ${v.verdict===1?"ACCEPT":"REJECT"}`;
     logLine(ts(v.t), `<span class="s">AUP2</span> FPGA verify #${v.idx}: ${v.verdict===1?'<span class="ok">ACCEPT</span>':'<span class="bad">REJECT</span>'} · ${fmtInt(v.pl_cycles)} cycles`); });
  fire(M.aup2.signs,"s2",(s)=>{ pulseChip(S.stage.B,"sign"); if(s.backend==="fpga") flashTrng(S.stage.B); S.stage.B.readout.textContent = `PL sign #${s.idx} · ${fmtInt(s.pl_cycles)} cycles · ${s.attempts} attempt(s)`;
     logLine(ts(s.t), `<span class="s">AUP2</span> signed frame #${s.idx} on ${s.backend==="fpga"?"FABRIC":"CPU-NEON"} · ${fmt(s.host_ms,2)} ms`); });
  fire(M.aup1.verifies,"v1",(v)=>{ pulseChip(S.stage.A,"verify"); S.stage.A.readout.textContent = `PL verify #${v.idx} · ${fmtInt(v.pl_cycles)} cycles · ${v.verdict===1?"ACCEPT":"REJECT"}`;
     logLine(ts(v.t), `<span class="s">AUP1</span> FPGA verify #${v.idx}: ${v.verdict===1?'<span class="ok">ACCEPT</span>':'<span class="bad">REJECT</span>'} · ${fmtInt(v.pl_cycles)} cycles`); });
  let payN = 0; fire(M.pay,"pay",(f)=>{ payN++; });
  let payN2 = 0; if(M.aup2.pay && M.aup2.pay.length) fire(M.aup2.pay,"pay2",(f)=>{ payN2++; });
  fire(M.adcs,"adcs",(a)=>{ if(a.miss) logLine(ts(a.t), `<span class="w">ADCS</span> missed its 10 ms deadline (release jitter ${fmtUs(a.jit)})`); });
  if(M.crash && M.crash.t!=null && T>=M.crash.t && !C.crashLogged){ C.crashLogged=true; batch.push([M.crash.t,()=>logLine(ts(M.crash.t), `<span class="bad">F′ ASSERT — flight software stopped: ${M.crash.text}</span>`)]); }
  batch.sort((x,y)=>x[0]-y[0]); for(const [,f] of batch) f();
  if(payN && S.stage) flashLens(S.stage.A);
  if(payN2 && S.stage) flashLens(S.stage.B);
  // packets
  const act = M.links.filter(L=> L.tSign<=T && T <= Math.max(L.tVerify||0, L.tSign+travel) + travel*1.6);
  drawPackets(act.slice(-120), T, travel);
  // panels (throttled)
  const now = performance.now(); if(!force && S._lastPanel && now - S._lastPanel < 120) { flushLog(); return; } S._lastPanel = now;
  updateBoard(S.R1, M, "aup1", T); updateBoard(S.R2, M, "aup2", T);
  const sent = M.links.filter(L=>L.tSign<=T); const acc = sent.filter(L=>L.tVerify!=null&&L.tVerify<=T&&L.verdict===1).length;
  const rej = sent.filter(L=>L.tVerify!=null&&L.tVerify<=T&&L.verdict!==1).length; const none = M.links.filter(L=>L.tVerify==null && L.tSign<=T).length;
  setNum(S.RC.sent, fmtInt(sent.length)); S.RC.sentD.textContent = M.kind==="mission" && M.summary && M.summary.sign ? `of ${M.summary.sign.requested} commanded` : "";
  setNum(S.RC.acc, fmtInt(acc));
  if(M.kind==="mission") S.RC.accD.textContent = sent.length? fmt(100*acc/sent.length,1)+"% of sent":"";
  else { const d=(f)=>{ const x=sent.filter(L=>L.from===f); return `${x.filter(L=>L.tVerify!=null&&L.tVerify<=T&&L.verdict===1).length}/${x.length}`; };
    S.RC.accD.textContent = `AUP1→AUP2 ${d("aup1")} · AUP2→AUP1 ${d("aup2")} (accepted/sent)`; }
  setNum(S.RC.rej, `${rej} / ${none}`, rej? "bad" : none? "warn" : ""); S.RC.rejD.textContent = "rejected / sign without verify record";
  $("#clock").textContent = `T+${fmt(T,1)} s / ${fmt(M.duration,0)} s`;
  drawPlayhead(); flushLog();
}
function updateBoard(R, M, b, T){
  const B = M[b];
  // cores
  if(B.cpu && B.cpu.length){ let c=null; for(const x of B.cpu){ if(x.t<=T) c=x; else break; }
    R.cpuNote.textContent = "measured 1 Hz from /proc/stat";
    for(let k=0;k<4;k++){ const v = c? c.u[k] : null; R["cb"+k].style.width = (v==null?0:v)+"%"; R["cv"+k].textContent = v==null? "—" : fmt(v,0)+"%"; } }
  else { R.cpuNote.innerHTML = "not recorded on this board in this run"; for(let k=0;k<4;k++){ R["cb"+k].style.width="0%"; R["cv"+k].textContent="—"; } }
  // signing
  const sg = B.signs.filter(s=>s.t<=T);
  if(B.signs.length || (M.kind==="mission"&&b==="aup1"&&M.params&&M.params.rate>0)){
    setNum(R.signed, fmtInt(sg.length)); R.signedD.textContent = sg.length ? `${sg.filter(s=>s.rc!==0).length} errors` : "";
    const lat = sg.filter(s=>s.rc===0).map(s=>s.host_ms);
    if(lat.length){ setNum(R.lat, `${fmt(quantile(lat,.5),2)} <small>ms median</small>`); R.latD.textContent = `99th percentile ${fmt(quantile(lat,.99),2)} ms · worst ${fmt(Math.max(...lat),2)} ms`; }
    else { setNum(R.lat, ND); R.latD.textContent=""; }
  } else { setNum(R.signed, M.kind==="mission"&&b==="aup2" ? '<span class="nodata">receiver only</span>' : ND); R.signedD.textContent=""; setNum(R.lat, ND); R.latD.textContent=""; }
  // verifies
  const vv = B.verifies.filter(v=>v.t<=T);
  if(B.verifies.length){ const a=vv.filter(v=>v.verdict===1).length; setNum(R.ver, `${fmtInt(a)} <small>accepted</small>`, vv.length-a? "bad":"good");
    const be=[...new Set(B.verifies.map(v=>v.backend).filter(Boolean))]; const where = be.length? (be.length===1&&be[0]==="fpga" ? "all on the FPGA verify program" : "verifier: "+be.join(", ")) : "all on the FPGA verify program";
    R.verD.textContent = `${vv.length-a} rejected · ${where.replace("all on the FPGA verify program","FPGA verify")}` + (B.recvLog ? ` · F′ log: ${B.recvLog.acc} acc / ${B.recvLog.rej} rej` : "");
    R.verD.title = B.recvLog ? "F′ log = “authenticated receive verdict=” lines over the whole F′ session; the card counts the per-run CSV records" : ""; }
  else { setNum(R.ver, M.kind==="mission"&&b==="aup1" ? '<span class="nodata">sender only</span>' : ND, ""); R.verD.textContent=""; }
  // last PL op
  const lastS = sg.length? sg[sg.length-1] : null, lastV = vv.length? vv[vv.length-1]:null;
  const last = (lastS && (!lastV || lastS.t>=lastV.t)) ? {k:"sign",o:lastS} : lastV ? {k:"verify",o:lastV} : null;
  if(last && (last.k==="verify" || last.o.backend==="fpga")){ setNum(R.pl, `${fmtInt(last.o.pl_cycles)} <small>cycles</small>`); R.plD.textContent = `${last.k} · ${fmt(last.o.pl_cycles/300,0)} µs at 300 MHz${last.k==="sign"?` · ${last.o.attempts} attempt(s)`:""}`; }
  else if(last){ setNum(R.pl, '<span class="nodata">idle (CPU signer)</span>'); R.plD.textContent=""; }
  else { setNum(R.pl, ND); R.plD.textContent=""; }
  // ADCS + payload (only where recorded)
  const AD = B.adcs || [], PY = B.pay || [];
  if(AD.length){
    let lo=0, hi=-1; for(let i=0;i<AD.length;i++){ if(AD[i].t<=T){ hi=i; } else break; }
    let w=null, miss=0; for(let i=hi;i>=0 && AD[i].t > T-1; i--){ w = w==null? AD[i].jit : Math.max(w, AD[i].jit); }
    for(let i=0;i<=hi;i++) if(AD[i].miss) miss++;
    setNum(R.adcs, w==null? ND : fmtUs(w), w==null?"": w>10000? "bad" : w>1000? "warn" : "good"); R.adcsD.textContent = hi>=0 ? `${miss} deadline misses in ${fmtInt(hi+1)} cycles (100 Hz)` : "";
  } else { setNum(R.adcs, b==="aup2"&&M.kind==="mission" ? '<span class="nodata">no mission load on this board</span>' : ND, ""); R.adcsD.textContent=""; }
  if(PY.length){
    let n=0, miss=0; for(const f of PY){ if(f.end<=T){ n++; if(f.miss) miss++; } }
    setNum(R.pay, n? fmt(100*miss/n,1)+"<small>%</small>" : ND, n? (miss/n>0.2?"bad":miss/n>0.05?"warn":"good"):""); R.payD.textContent = n? `${miss} of ${fmtInt(n)} frames late (${B.payJ&&B.payJ.deadline_ms? fmt(B.payJ.deadline_ms,0) : (M.payJ&&M.payJ.deadline_ms? fmt(M.payJ.deadline_ms,0):"?")} ms deadline)` : "";
  } else { setNum(R.pay, b==="aup2"&&M.kind==="mission" ? '<span class="nodata">no mission load on this board</span>' : ND, ""); R.payD.textContent=""; }
}

// ---------------- timeline ----------------
function drawTimeline(){
  const cv = $("#timeline"); const W = cv.clientWidth, H = cv.clientHeight; const dpr = window.devicePixelRatio||1;
  cv.width = W*dpr; cv.height = H*dpr;
  const base = document.createElement("canvas"); base.width=cv.width; base.height=cv.height; const g = base.getContext("2d"); g.scale(dpr,dpr);
  g.fillStyle="#0a1430"; g.fillRect(0,0,W,H);
  const M = S.M; if(!M || S.mode!=="replay"){ S.tlBase = base; cv.getContext("2d").drawImage(base,0,0); return; }
  const L=120, Rr=12, D=M.duration; const X=(t)=>L+(W-L-Rr)*t/D;
  const lanes=[["Signs",0.2],["Verifies",0.1],["ADCS jitter",0.35],["Imager frames",0.35]];
  let y=6; const lane={};
  g.font="11px Segoe UI, Arial"; g.textBaseline="middle";
  for(const [n,f] of lanes){ const h=(H-12)*f; lane[n]=[y,h]; g.fillStyle="#0d1838"; g.fillRect(L,y,W-L-Rr,h-3); g.fillStyle="#8c9ab8"; g.fillText(n,8,y+h/2); y+=h; }
  // time axis ticks
  g.strokeStyle="#1d2c52"; g.fillStyle="#5f6d8d"; const step = D>120?20:D>40?10:5;
  for(let t=0;t<=D;t+=step){ const x=X(t); g.beginPath(); g.moveTo(x,6); g.lineTo(x,H-6); g.stroke(); g.fillText(t+" s",x+2,H-8); }
  // AUP1 sign ticks (height ~ log latency)
  let [y0,h]=lane["Signs"];
  const lg=(v,a,b)=>Math.max(0,Math.min(1,(Math.log10(v)-a)/(b-a)));
  for(const s of M.aup1.signs){ const x=X(s.t); const k=lg(s.host_ms,-0.3,2); g.strokeStyle = s.rc!==0?"#ff5d5d": s.backend==="fpga"?"#d4af37":"#f3a23a"; g.beginPath(); g.moveTo(x,y0+h-4); g.lineTo(x,y0+h-4-(h-8)*(0.15+0.85*k)); g.stroke(); }
  for(const s of M.aup2.signs){ const x=X(s.t); g.strokeStyle="#7cc7ff"; g.beginPath(); g.moveTo(x,y0+h-4); g.lineTo(x,y0+6); g.stroke(); }
  [y0,h]=lane["Verifies"];
  for(const v of [...M.aup2.verifies,...M.aup1.verifies]){ const x=X(v.t); g.strokeStyle=v.verdict===1?"#3fd38a":"#ff5d5d"; g.beginPath(); g.moveTo(x,y0+3); g.lineTo(x,y0+h-6); g.stroke(); }
  if(!M.aup2.verifies.length && !M.aup1.verifies.length){ g.fillStyle="#5f6d8d"; g.fillText("no data", L+8, y0+h/2); }
  // ADCS jitter: worst per 100 ms bucket, log scale 10 µs .. 10 s
  [y0,h]=lane["ADCS jitter"];
  if(M.adcs.length){ const nb=Math.ceil(D*10); const mx=new Array(nb).fill(null);
    for(const a of M.adcs){ const b=Math.floor(a.t*10); if(b>=0&&b<nb) mx[b]=mx[b]==null?a.jit:Math.max(mx[b],a.jit); }
    const Y=(us)=>y0+h-4-(h-8)*lg(Math.max(us,10),1,7);
    g.strokeStyle="#2b3d6b"; [100,1e3,1e4,1e5,1e6].forEach(u=>{ g.beginPath(); g.moveTo(L,Y(u)); g.lineTo(W-Rr,Y(u)); g.stroke(); });
    g.fillStyle="#5f6d8d"; [100,1e4,1e6].forEach(u=>g.fillText(fmtUs(u),L-44,Y(u)));
    g.strokeStyle = M.kind==="duplex" ? "#d4af37" : "#7cc7ff"; g.beginPath(); let st=false; mx.forEach((v,i)=>{ if(v==null){st=false;return;} const x=X(i/10), yy=Y(v); if(!st){g.moveTo(x,yy);st=true;} else g.lineTo(x,yy); }); g.stroke();
    g.fillStyle="#ff5d5d"; for(const a of M.adcs) if(a.miss){ g.beginPath(); g.arc(X(a.t),Y(a.jit),3,0,7); g.fill(); }
    if(M.aup2.adcs && M.aup2.adcs.length){ const m2=new Array(nb).fill(null);
      for(const a of M.aup2.adcs){ const b=Math.floor(a.t*10); if(b>=0&&b<nb) m2[b]=m2[b]==null?a.jit:Math.max(m2[b],a.jit); }
      g.strokeStyle="#7cc7ff"; g.globalAlpha=0.8; g.beginPath(); let s2=false; m2.forEach((v,i)=>{ if(v==null){s2=false;return;} const x=X(i/10), yy=Y(v); if(!s2){g.moveTo(x,yy);s2=true;} else g.lineTo(x,yy); }); g.stroke(); g.globalAlpha=1;
      g.fillStyle="#d4af37"; g.fillText("AUP1",W-Rr-74,y0+9); g.fillStyle="#7cc7ff"; g.fillText("AUP2",W-Rr-38,y0+9); }
  } else { g.fillStyle="#5f6d8d"; g.fillText("no data", L+8, y0+h/2); }
  // payload processing time per frame, 125 ms deadline
  [y0,h]=lane["Imager frames"];
  if(M.pay.length){ const Y=(ms)=>y0+h-4-(h-8)*Math.min(1,ms/400);
    g.strokeStyle="#d4af37"; g.setLineDash([4,4]); g.beginPath(); g.moveTo(L,Y(125)); g.lineTo(W-Rr,Y(125)); g.stroke(); g.setLineDash([]);
    g.fillStyle="#5f6d8d"; g.fillText("125 ms deadline",L+2,Y(125)-7); g.fillText("400 ms",L+2,y0+8);
    for(const f of M.pay){ g.fillStyle=f.miss?"#ff5d5d":"#3fd38a"; g.fillRect(X(f.t),Y(f.proc_ms),2,2); } }
  else { g.fillStyle="#5f6d8d"; g.fillText("no data", L+8, y0+h/2); }
  if(M.crash && M.crash.t!=null){ const x=X(M.crash.t); g.strokeStyle="#ff5d5d"; g.lineWidth=2; g.beginPath(); g.moveTo(x,4); g.lineTo(x,H-4); g.stroke(); g.lineWidth=1; g.fillStyle="#ff5d5d"; g.fillText("F′ assert",x+4,12); }
  S.tlBase = base; S.tlX = X; S.tlL=L; S.tlR=Rr;
  $("#tlHint").textContent = "sign ticks: height = sign time (log)"+(M.kind==="duplex"?", gold AUP1 / blue AUP2":"")+" · ADCS: worst jitter per 100 ms (log) · imager: per-frame compression time"+(M.kind==="duplex"?" (AUP1)":"")+" · click to seek";
  drawPlayhead();
}
function drawPlayhead(){
  const cv=$("#timeline"); if(!S.tlBase) return; const c=cv.getContext("2d"); c.setTransform(1,0,0,1,0,0); c.drawImage(S.tlBase,0,0);
  if(S.mode==="replay" && S.M && S.tlX){ const dpr=window.devicePixelRatio||1; const x=S.tlX(S.T)*dpr; c.strokeStyle="#f2d27a"; c.lineWidth=2*dpr; c.beginPath(); c.moveTo(x,0); c.lineTo(x,cv.height); c.stroke(); }
}

// ---------------- visual layer (Earth drift, lighting, attitude wobble) ----------------
let driftX = 0;
function adcsAt(M, T, b){ const A=(b && M[b] && M[b].adcs) ? M[b].adcs : M.adcs; if(!A||!A.length) return null; let lo=0, hi=A.length-1; if(T<A[0].t) return null; if(T>A[hi].t+0.5) return null;
  while(lo<hi){ const m=(lo+hi+1)>>1; if(A[m].t<=T) lo=m; else hi=m-1; } return A[lo]; }
function visualLayer(now, dtWall){
  const st=S.stage; if(!st) return;
  const rate = S.mode==="replay" ? (S.playing ? Math.min(S.speed,5) : 0) : 1;   // drift follows playback, steady in live
  driftX = (driftX + dtWall*14*rate) % st.TILE; st.drift.setAttribute("transform", `translate(${(-driftX).toFixed(1)},0)`);
  const ph = 2*Math.PI*((S.mode==="replay"? S.T : now/1000) / 7);
  for(const b of ["aup1","aup2"]){
    const sat = b==="aup1"? st.A : st.B;
    let sunlit = true, wob = 0, cap = "lighting: illustrative · attitude: no ADCS log";
    if(S.mode==="replay" && S.M && S.M[b] && S.M[b].adcs && S.M[b].adcs.length){
      const r = adcsAt(S.M, S.T, b);
      if(r && r.point_err!=null){ sunlit = r.sunlit!==0; const amp = Math.min(WOBBLE_MAX_DEG, r.point_err*WOBBLE_GAIN); wob = amp*Math.sin(ph);
        cap = `lighting: ADCS log (${sunlit?"sunlit":"eclipse"}) · attitude error ×${WOBBLE_GAIN} exaggerated, clamped at ${WOBBLE_MAX_DEG}° (logged ${r.point_err.toFixed(3)}°)`; }
      else cap = "lighting: illustrative · attitude: outside ADCS log span";
    } else if(S.mode==="replay" && S.M && S.M.kind==="mission" && b==="aup2") cap = "lighting: illustrative · attitude: no ADCS load on this board";
    else if(S.mode==="live") cap = "lighting: illustrative · attitude: not streamed live";
    setSatVisual(st, sat, sunlit, wob, cap);
  }
  st.sun.style.opacity = (S.mode==="replay" && S.M && S.M.adcs.length && adcsAt(S.M,S.T) && adcsAt(S.M,S.T).sunlit===0) ? "0" : "1";
  updateLink(st);
}


// ---------------- ground station + certificate lane (evidence only) ----------------
// Evidence = saved console output of wcore_cert_check (CERT_CHECK lines), see README. Time of the check =
// a "DATE_EPOCH <seconds>" line in the file if present, else the file's modification time.
function certEvidence(b){
  const list = (S.runs && S.runs.cert && S.runs.cert.checks && S.runs.cert.checks[b]) || [];
  return list.map(e=>{ const m=e.text.match(/DATE_EPOCH\s+(\d+)/); const t = m? +m[1] : e.mtime;
    const lines = e.text.split(/\r?\n/).filter(x=>/CERT_CHECK/.test(x));
    const res = (e.text.match(/CERT_CHECK RESULT:\s*(\w+)/)||[])[1] || null;
    const ver = lines.filter(x=>/verifier=/.test(x)).map(x=>{ const v=(x.match(/verifier=(\w+)/)||[])[1]; const ok=/valid=1/.test(x)&&/tampered_pk_rejected=1/.test(x)&&/tampered_cert_rejected=1/.test(x); return v+(ok?" ✓":" ✗"); });
    const peer = (e.text.match(/peer=(\w+)/)||[])[1] || null;
    return { file:e.file, t, res, ver, peer, timed: !!m }; }).filter(e=>e.res);
}
function setupGround(M){
  const G = S.stage.ground; S.gAnim = null; G.tokA.setAttribute("visibility","hidden"); G.tokB.setAttribute("visibility","hidden");
  const grey = (msg, l2)=>{ G.g.setAttribute("opacity","0.32"); G.status.textContent = msg; G.line2.textContent = l2||""; };
  if(!M){ grey("certificate lane: replay only"); return; }
  const use = {}; let late = null;
  for(const b of ["aup1","aup2"]){
    const ev = certEvidence(b); if(!ev.length) continue;
    const sealed = M[b] && M[b].key && M[b].key.state==="sealed";
    const before = ev.filter(e=>e.t <= M.t0+5).sort((x,y)=>y.t-x.t)[0];
    if(sealed && before) use[b]=before; else if(!before) late = ev[0];
  }
  const bs = Object.keys(use);
  if(!bs.length){ grey("no certificate exchange recorded for this run", late ? `(a certificate check dated ${new Date(late.t*1000).toISOString().slice(11,19)} UTC exists, after this run started)` : ""); return; }
  G.g.setAttribute("opacity","1"); S.gAnim = { start: performance.now(), use };
}
function animateGround(now){
  const A = S.gAnim; if(!A) return; const G = S.stage.ground; const t = (now-A.start)/1000;
  const place = (tok, path, len, p)=>{ const q=path.getPointAtLength(Math.max(0,Math.min(1,p))*len); tok.setAttribute("cx",q.x); tok.setAttribute("cy",q.y); tok.setAttribute("visibility","visible"); };
  const on = (b)=>!!A.use[b];
  if(t < 2.5){ const p = 1 - t/2.5;                     // public keys down: satellite -> ground
    if(on("aup1")) place(G.tokA, G.pathA, G.lenA, p); if(on("aup2")) place(G.tokB, G.pathB, G.lenB, p);
    G.status.textContent = "public keys down to the ground (generated in each fabric)"; G.line2.textContent = "replay of the recorded exchange; it took place before this run"; }
  else if(t < 5){ const p = (t-2.5)/2.5;               // peer key + certificate up: ground -> satellite
    if(on("aup1")) place(G.tokA, G.pathA, G.lenA, p); if(on("aup2")) place(G.tokB, G.pathB, G.lenB, p);
    G.status.textContent = "peer key + ground-signed certificate up (WCORE-CERT-V1, ML-DSA-44)"; }
  else { G.tokA.setAttribute("visibility","hidden"); G.tokB.setAttribute("visibility","hidden");
    const txt = Object.keys(A.use).map(b=>{ const e=A.use[b]; return `${b.toUpperCase()} checked ${e.peer||"peer"}: ${e.res}${e.ver.length?" ("+e.ver.join(", ")+")":""}`; }).join(" · ");
    G.status.textContent = txt;
    const e0 = A.use[Object.keys(A.use)[0]];
    G.line2.textContent = `recorded ${new Date(e0.t*1000).toISOString().slice(11,19)} UTC${e0.timed?"":" (file time)"}, before this run · ground key is a file on the board`;
    S.gAnim = null; }
}
function imgLabel(img){
  if(!img || img==="not checked") return "image not checked";
  const v = (img.match(/VERSION=0x([0-9a-fA-F]{8})/)||[])[1]; if(!v) return img.replace("WCORE_CHECK ","");
  if(/^0003000[23]$/.test(v)) return `sealed design 0x${v}${v.endsWith("3")?" (KeyGen image)":""} · ${/locked=1/.test(img)?"key SEALED (locked=1)":"no key loaded (locked=0)"}`;
  if(/^0002/.test(v)) return `v7 image 0x${v}`;
  return "image 0x"+v;
}
function liveKey(img){
  if(!img) return null; const v=(img.match(/VERSION=0x([0-9a-fA-F]{8})/)||[])[1]; if(!v) return null;
  if(/^0003000[23]$/.test(v) && /locked=1/.test(img)) return { state:"sealed", text:"sealed in fabric (live register read: locked=1)", evidence:"" };
  if(/^0003000[23]$/.test(v)) return { state:"host", text:"sealed design loaded, no key locked", evidence:"" };
  if(/^0002/.test(v)) return { state:"host", text:"provisioned by host (v7 image)", evidence:"" };
  return null;
}

// ---------------- animation loop ----------------
function frame(now){
  visualLayer(now, S.lastWall==null?0:(now-S.lastWall)/1000); animateGround(now);
  if(S.mode==="replay" && S.M){
    if(S.playing){ const dt = S.lastWall==null?0:(now-S.lastWall)/1000; S.T = Math.min(S.M.duration, S.T + dt*S.speed); if(S.T>=S.M.duration){ S.playing=false; $("#play").textContent="▶"; } }
    renderReplay(false);
  } else if(S.mode==="live" && S.live) renderLive(now);
  S.lastWall = now; requestAnimationFrame(frame);
}
function seek(t){ const M=S.M; if(!M) return; S.T=Math.max(0,Math.min(M.duration,t));
  // rebuild pointers and log up to T
  S.cur = { s1:0, v1:0, s2:0, v2:0, pay:0, pay2:0, adcs:0, crashLogged:false }; S.log=[]; const keep=S.playing; S.playing=false;
  const sp=S.speed; renderReplay(true); S.speed=sp; S.playing=keep; }

// ---------------- live ----------------
function startLive(){
  S.live = { t0: performance.now(), boards:{aup1:mkLB(),aup2:mkLB()}, links:[], idx:{aup1:0,aup2:0}, lastPoll:0, timer:null, hist:[] };
  S.R1 = boardPanel("aup1","AUP1"); S.R2 = boardPanel("aup2","AUP2"); S.RC = centerPanel();
  coreLabels(S.R1,null,"aup1"); coreLabels(S.R2,null,"aup2"); badge(S.R1,null); badge(S.R2,null);
  S.R1.role.textContent = S.R2.role.textContent = "live";
  S.RC.kv.innerHTML = "<span>Source</span><span>read-only ssh probe, one line per second per board</span>";
  S.RC.notes.innerHTML = "• ADCS and imager timings are kept in RAM on the board and written when a run ends, so they are not streamed live; the cards show whether those tasks are running.<br>• Sign and verify events come from F′'s hw-stats CSV on each board as they are appended.";
  S.log=[]; S.logDirty=true; banner(null); S.stage.sub.textContent="LIVE · ground station polling both boards";
  setKeyBadge(S.stage.A,null,""); setKeyBadge(S.stage.B,null,""); setupGround(null);
  S.stage.path2.style.opacity = S.stage.glowPath2.style.opacity = S.stage.dirB.style.opacity = "1";
  pollLive(); S.live.timer = setInterval(pollLive, 1000);
  S.tlBase=null; drawTimeline();
}
function mkLB(){ return { lastSeq:-1, line:null, signs:0, signErr:0, lat:[], acc:0, rej:0, verN:0, backend:null, lastPl:null, err:"", alive:false, seen:false }; }
async function pollLive(){
  let j; try{ const r=await fetch("api/live"); j=await r.json(); } catch(e){ $("#liveState").textContent="ground-station server not reachable"; return; }
  const L=S.live; if(!L) return; const tnow=(performance.now()-L.t0)/1000;
  const states=[], evs=[];
  for(const b of ["aup1","aup2"]){
    const st=j[b]; const B=L.boards[b]; B.alive=st.alive; B.err=st.err||"";
    const lines = (st.lines||[]).map(s=>{ try{return JSON.parse(s);}catch(e){return null;} }).filter(Boolean);
    for(const ln of lines){
      if(ln.seq <= B.lastSeq && !(ln.seq < 3 && B.lastSeq > 10)) continue;
      B.lastSeq = ln.seq; B.line = ln; B.seen = true; B.lineAt = tnow;
      for(const row of ln.hw||[]){ const r=parseHwRow(row); if(!r) continue; const ep = ln.epoch - (ln.uptime - r.mono_us/1e6); evs.push([ep,b,r]); }
    }
    states.push(`${b.toUpperCase()}: ${B.seen? (tnow-(B.lineAt||0) < 4 ? "streaming" : "stale") : B.alive? "connecting…" : "not connected"}`);
  }
  evs.sort((x,y)=>x[0]-y[0]); for(const [ep,b,r] of evs) liveEvent(b, r, ep, tnow);
  $("#liveState").textContent = states.join(" · ");
  const errs = ["aup1","aup2"].filter(b=>!L.boards[b].alive && L.boards[b].err).map(b=>`${b.toUpperCase()}: ${L.boards[b].err.split("\n").pop()}`);
  banner(errs.length? "Live probe problem — "+errs.join(" | ") : null);
}
function liveEvent(b, r, epoch, tnow){
  const L=S.live, B=L.boards[b], other = b==="aup1"?"aup2":"aup1", sat = b==="aup1"?S.stage.A:S.stage.B;
  const ts = new Date(epoch*1000).toISOString().slice(11,23)+" UTC";
  if(r.op==="sign"){
    B.signs++; if(r.rc!==0) B.signErr++; else B.lat.push(r.host_total_us/1000); B.backend=r.backend; B.lastPl={k:"sign",o:r};
    L.idx[b]++; L.links.push({from:b,to:other,tSign:tnow,tVerify:null,verdict:null,idx:L.idx[b],pending:true});
    pulseChip(sat,"sign"); if(r.backend==="fpga"&&r.trng_us>0) flashTrng(sat);
    sat.readout.textContent = r.backend==="fpga" ? `PL sign #${L.idx[b]} · ${fmtInt(r.pl_cycles)} cycles · ${r.attempts} attempt(s)` : `CPU-NEON sign #${L.idx[b]} · ${fmt(r.host_total_us/1000,2)} ms`;
    logLine(ts, `<span class="s">${b.toUpperCase()}</span> signed frame #${L.idx[b]} on ${r.backend==="fpga"?"FABRIC":"CPU-NEON"} · ${fmt(r.host_total_us/1000,2)} ms`+(r.rc!==0?` <span class="bad">rc=${r.rc}</span>`:""));
  } else if(r.op==="verify"){
    B.verN++; if(r.verdict===1) B.acc++; else B.rej++; B.lastPl={k:"verify",o:r}; B.vbackend=r.backend;
    const pend = L.links.find(x=>x.pending && x.to===b);
    if(pend){ pend.pending=false; pend.tVerify=tnow; pend.verdict=r.verdict; }
    pulseChip(sat,"verify"); sat.readout.textContent = `PL verify · ${fmtInt(r.pl_cycles)} cycles · ${r.verdict===1?"ACCEPT":"REJECT"}`;
    logLine(ts, `<span class="s">${b.toUpperCase()}</span> ${r.backend.toUpperCase()} verify: ${r.verdict===1?'<span class="ok">ACCEPT</span>':'<span class="bad">REJECT</span>'} · ${fmtInt(r.pl_cycles)} cycles`);
  }
}
function renderLive(now){
  const L=S.live; const T=(now-L.t0)/1000; const travel=0.9;
  for(const x of L.links) if(x.pending && T - x.tSign > 10){ x.pending=false; } // no verify seen within 10 s → shown grey
  L.links = L.links.filter(x=> T <= Math.max(x.tVerify||0, x.tSign+travel) + (x.pending? 60 : travel*1.6));
  drawPackets(L.links.slice(-120).map(x=>x.pending? Object.assign({},x,{tVerify:Infinity}) : x), T, travel);
  if(S._lastPanel && now - S._lastPanel < 250){ flushLog(); return; } S._lastPanel = now;
  $("#clock").textContent = new Date().toISOString().slice(11,19)+" UTC";
  let sent=0,acc=0,rej=0; for(const b of ["aup1","aup2"]){ const B=L.boards[b]; sent+=B.signs; acc+=B.acc; rej+=B.rej; }
  setNum(S.RC.sent, fmtInt(sent)); S.RC.sentD.textContent="since this page opened";
  setNum(S.RC.acc, fmtInt(acc)); S.RC.accD.textContent="";
  setNum(S.RC.rej, `${rej}`, rej?"bad":""); S.RC.rejD.textContent="rejected by peer verify";
  for(const b of ["aup1","aup2"]){ const B=L.boards[b], R = b==="aup1"?S.R1:S.R2, ln=B.line;
    if(B.backend && B.vbackend) badge(R,B.backend,"SIGN + VERIFY"); else if(B.backend) badge(R,B.backend); else if(B.vbackend) badge(R,B.vbackend,"VERIFIER");
    if(ln){ R.cpuNote.textContent = "live, 1 Hz from /proc/stat"; for(let k=0;k<4;k++){ const v=ln.cpu[k]; R["cb"+k].style.width=(v==null?0:v)+"%"; R["cv"+k].textContent= v==null?"—":fmt(v,0)+"%"; }
      R.fFsw.classList.toggle("on",!!ln.fsw); R.fAdcs.classList.toggle("on",!!ln.adcs); R.fPay.classList.toggle("on",!!ln.payload);
      R.role.textContent = imgLabel(ln.img) + (ln.run? " · newest run "+ln.run : ""); setKeyBadge(b==="aup1"?S.stage.A:S.stage.B, liveKey(ln.img), ""); }
    else { R.cpuNote.innerHTML = "waiting for board"; }
    setNum(R.signed, B.seen? fmtInt(B.signs) : ND); R.signedD.textContent = B.signErr? `${B.signErr} errors`:"";
    setNum(R.ver, B.seen? `${fmtInt(B.acc)} <small>accepted</small>` : ND, B.rej?"bad":B.acc?"good":""); R.verD.textContent = B.verN? `${B.rej} rejected`:"";
    if(B.lat.length){ setNum(R.lat, `${fmt(quantile(B.lat,.5),2)} <small>ms median</small>`); R.latD.textContent=`99th percentile ${fmt(quantile(B.lat,.99),2)} ms · ${B.lat.length} signs`; } else { setNum(R.lat, ND); R.latD.textContent=""; }
    if(B.lastPl && (B.lastPl.k==="verify"||B.lastPl.o.backend==="fpga")){ setNum(R.pl, `${fmtInt(B.lastPl.o.pl_cycles)} <small>cycles</small>`); R.plD.textContent=`${B.lastPl.k} · ${fmt(B.lastPl.o.pl_cycles/300,0)} µs at 300 MHz`; } else { setNum(R.pl, ND); R.plD.textContent=""; }
    setNum(R.adcs, ln? (ln.adcs? '<span class="nodata">running · written at end of run</span>' : '<span class="nodata">not running</span>') : ND, "");
    setNum(R.pay, ln? (ln.payload? '<span class="nodata">running · written at end of run</span>' : '<span class="nodata">not running</span>') : ND, "");
    R.adcsD.textContent=""; R.payD.textContent="";
  }
  // live timeline: CPU mean per board, last 120 s
  L.hist.push({t:T, a: L.boards.aup1.line? avg(L.boards.aup1.line.cpu):null, b: L.boards.aup2.line? avg(L.boards.aup2.line.cpu):null});
  L.hist = L.hist.filter(h=>h.t > T-120); drawLiveTimeline(T); flushLog();
}
function avg(a){ const v=(a||[]).filter(x=>x!=null); return v.length? v.reduce((x,y)=>x+y,0)/v.length : null; }
function drawLiveTimeline(T){
  const cv=$("#timeline"); const W=cv.clientWidth,H=cv.clientHeight,dpr=window.devicePixelRatio||1; if(cv.width!==W*dpr){cv.width=W*dpr;cv.height=H*dpr;}
  const g=cv.getContext("2d"); g.setTransform(dpr,0,0,dpr,0,0); g.fillStyle="#0a1430"; g.fillRect(0,0,W,H);
  const L=60, X=(t)=>L+(W-L-10)*(1-(T-t)/120), Y=(v)=>H-14-(H-28)*v/100;
  g.strokeStyle="#1d2c52"; g.fillStyle="#5f6d8d"; g.font="11px Segoe UI"; [0,50,100].forEach(v=>{g.beginPath();g.moveTo(L,Y(v));g.lineTo(W-10,Y(v));g.stroke();g.fillText(v+"%",8,Y(v));});
  for(const [k,col] of [["a","#d4af37"],["b","#7cc7ff"]]){ g.strokeStyle=col; g.lineWidth=2; g.beginPath(); let st=false; for(const h of S.live.hist){ if(h[k]==null){st=false;continue;} const x=X(h.t),y=Y(h[k]); if(!st){g.moveTo(x,y);st=true;} else g.lineTo(x,y);} g.stroke(); }
  g.lineWidth=1; g.fillStyle="#d4af37"; g.fillText("AUP1 mean CPU",W-210,12); g.fillStyle="#7cc7ff"; g.fillText("AUP2 mean CPU",W-110,12);
  $("#tlHint").textContent="live · last 120 s";
}
async function stopLive(){ if(S.live){ clearInterval(S.live.timer); S.live=null; } try{ await fetch("api/live/stop"); }catch(e){} }

// ---------------- compare ----------------
async function openCompare(){
  $("#cmp").hidden=false;
  const A=$("#cmpA"), B=$("#cmpB");
  if(S.M && S.M.kind==="mission" && !A._set){ A.value=S.M.name; A._set=true;
    const p=S.M.params||{}; const other=S.runs.mission.find(r=>!r.crashed && r.name!==S.M.name && new RegExp(`_${p.backend==="fpga"?"cpu":"fpga"}_r${p.rate}_`).test(r.name)); if(other) B.value=other.name; }
  await renderCompare();
}
async function renderCompare(){
  const a=$("#cmpA").value, b=$("#cmpB").value; $("#cmpBody").innerHTML='<div class="muted">loading…</div>';
  const [MA,MB]=await Promise.all([loadMission(a),loadMission(b)]); const A=runStats(MA), B=runStats(MB);
  const rows=[
    ["Frames signed (rc = 0)","signed",0,"hi"],["Accepted by AUP2 FPGA verify","accepted",0,"hi"],["Rejected by AUP2","rejected",0,"lo"],
    ["Sign time, median (ms)","signMed",2,"lo"],["Sign time, 99th percentile (ms)","sign99",2,"lo"],["Sign time, worst (ms)","signMax",2,"lo"],
    ["Mean signing attempts (fabric)","attempts",2,null],
    ["ADCS release jitter, median (µs)","adcsMed",1,"lo"],["ADCS release jitter, 99th percentile (µs)","adcs99",1,"lo"],["ADCS release jitter, worst (µs)","adcsMax",0,"lo"],
    ["ADCS deadline misses","adcsMiss",0,"lo"],["ADCS skipped releases (from adcs.json)","adcsSkipped",0,"lo"],
    ["Imager frames processed","payN",0,"hi"],["Imager deadline misses (%)","payMissPct",1,"lo"],["Imager compression time, median (ms)","payMed",1,"lo"],["Imager compression time, 99th percentile (ms)","pay99",1,"lo"]];
  const cell=(x,d)=> x==null? '<span class="nodata">no data</span>' : fmt(x,d).replace(/\B(?=(\d{3})+(?!\d))/g,",");
  let h=`<table class="ct"><tr><th>Metric (computed from the run files)</th><th>${runLabel(a)}${MA.crash?' <span class="crashTag">CRASHED — excluded</span>':''}</th><th>${runLabel(b)}${MB.crash?' <span class="crashTag">CRASHED — excluded</span>':''}</th></tr>`;
  for(const [n,k,d,better] of rows){ const x=A[k], y=B[k]; let ca="",cb=""; if(better&&x!=null&&y!=null&&x!==y){ const ax = better==="lo"? x<y : x>y; if(ax) ca="better"; else cb="better"; }
    h+=`<tr><td>${n}</td><td class="${ca}">${cell(x,d)}</td><td class="${cb}">${cell(y,d)}</td></tr>`; }
  if(A.cpu||B.cpu) h+=`<tr><td>Mean CPU per core 0/1/2/3 (%)</td><td>${A.cpu?A.cpu.map(v=>fmt(v,0)).join(" / "):"no data"}</td><td>${B.cpu?B.cpu.map(v=>fmt(v,0)).join(" / "):"no data"}</td></tr>`;
  h+=`</table><div class="cdfs"><canvas id="cdf1"></canvas><canvas id="cdf2"></canvas><canvas id="cdf3"></canvas></div>
     <div class="muted" style="margin-top:6px">Curves: share of events at or below a value. Gold solid = ${runLabel(a)}; blue dashed = ${runLabel(b)}. Single runs; repeats are needed before drawing conclusions.</div>`;
  $("#cmpBody").innerHTML=h;
  cdf($("#cdf1"),"ADCS release jitter",MA.adcs.map(x=>x.jit),MB.adcs.map(x=>x.jit),true,"µs");
  cdf($("#cdf2"),"Imager compression time",MA.pay.map(x=>x.proc_ms),MB.pay.map(x=>x.proc_ms),false,"ms",125);
  cdf($("#cdf3"),"Sign time (host, end to end)",MA.aup1.signs.filter(s=>s.rc===0).map(s=>s.host_ms),MB.aup1.signs.filter(s=>s.rc===0).map(s=>s.host_ms),true,"ms");
}
function cdf(cv,title,a,b,log,unit,mark){
  const W=cv.clientWidth,H=cv.clientHeight,dpr=window.devicePixelRatio||1; cv.width=W*dpr; cv.height=H*dpr; const g=cv.getContext("2d"); g.scale(dpr,dpr);
  g.fillStyle="#0a1430"; g.fillRect(0,0,W,H); g.font="12px Segoe UI"; g.fillStyle="#d4af37"; g.fillText(title+" ("+unit+")",10,16);
  const all=[...a,...b].filter(x=>x>0); if(!all.length){ g.fillStyle="#8c9ab8"; g.fillText("no data",W/2-20,H/2); return; }
  let lo=Math.min(...all), hi=Math.max(...all); if(!log){ lo=0; }
  const L=40,R=10,T=26,B=24; const tx=(v)=> log? (Math.log10(Math.max(v,lo))-Math.log10(lo))/(Math.log10(hi)-Math.log10(lo)||1) : (v-lo)/(hi-lo||1);
  const X=(v)=>L+(W-L-R)*tx(v), Y=(p)=>H-B-(H-B-T)*p;
  g.strokeStyle="#1d2c52"; g.fillStyle="#5f6d8d"; g.font="10.5px Segoe UI";
  [0,.5,.9,1].forEach(p=>{ g.beginPath(); g.moveTo(L,Y(p)); g.lineTo(W-R,Y(p)); g.stroke(); g.fillText((p*100)+"%",4,Y(p)+3); });
  const ticks = log? [1,10,100,1e3,1e4,1e5,1e6,1e7].filter(v=>v>=lo&&v<=hi) : [0,hi/4,hi/2,3*hi/4,hi];
  ticks.forEach(v=>{ g.fillText(v>=1e4? (v/1e3)+"k" : fmt(v, v<10&&!log?1:0), X(v)-8, H-8); });
  if(mark!=null && mark<=hi){ g.strokeStyle="#d4af37"; g.setLineDash([3,3]); g.beginPath(); g.moveTo(X(mark),T); g.lineTo(X(mark),H-B); g.stroke(); g.setLineDash([]); g.fillStyle="#d4af37"; g.fillText("deadline",X(mark)+3,T+10); }
  const line=(arr,col,dash)=>{ if(!arr.length) return; const s=[...arr].sort((x,y)=>x-y); g.strokeStyle=col; g.lineWidth=2; g.setLineDash(dash); g.beginPath();
    const n=s.length, step=Math.max(1,Math.floor(n/600)); for(let i=0;i<n;i+=step){ const x=X(s[i]),y=Y((i+1)/n); if(i===0) g.moveTo(x,y); else g.lineTo(x,y); } g.lineTo(X(s[n-1]),Y(1)); g.stroke(); g.setLineDash([]); g.lineWidth=1; };
  line(a,"#d4af37",[]); line(b,"#7cc7ff",[6,4]);
}

// ---------------- wiring ----------------
async function setMode(m){
  if(m===S.mode) return;
  document.querySelectorAll("#mode button").forEach(b=>b.classList.toggle("on",b.dataset.mode===m));
  $("#replayCtl").hidden = m!=="replay"; $("#liveCtl").hidden = m!=="live";
  for(const P of PK) P.grp.setAttribute("visibility","hidden");
  if(m==="live"){ S.mode="live"; S.playing=false; startLive(); }
  else { await stopLive(); S.mode="replay"; S.stage.A.readout.textContent="PL fabric idle"; S.stage.B.readout.textContent="PL fabric idle"; await openReplay($("#runPick").value); }
}
async function init(){
  S.stage = buildStage($("#stageSvg"));
  boardPanel("aup1","AUP1"); boardPanel("aup2","AUP2"); centerPanel();
  try{ await loadRuns(); } catch(e){ banner("Cannot read the run list from the ground-station server: "+e); }
  $("#runPick").onchange = (e)=>openReplay(e.target.value);
  $("#play").onclick = ()=>{ if(!S.M) return; if(S.T>=S.M.duration) seek(0); S.playing=!S.playing; $("#play").textContent=S.playing?"❚❚":"▶"; };
  $("#speed").onchange = (e)=>{ S.speed=+e.target.value; };
  $("#cmpBtn").onclick = openCompare; $("#cmpClose").onclick = ()=>{$("#cmp").hidden=true;};
  $("#cmpA").onchange = renderCompare; $("#cmpB").onchange = renderCompare;
  document.querySelectorAll("#mode button").forEach(b=>b.onclick=()=>setMode(b.dataset.mode));
  $("#liveStop").onclick = ()=>setMode("replay");
  $("#timeline").onclick = (e)=>{ if(S.mode!=="replay"||!S.M||!S.tlX) return; const r=e.target.getBoundingClientRect(); const x=e.clientX-r.left; const t=(x-S.tlL)/(r.width-S.tlL-S.tlR)*S.M.duration; seek(t); };
  window.addEventListener("resize", ()=>{ if(S.mode==="replay") drawTimeline(); });
  window.addEventListener("beforeunload", ()=>{ if(S.live) navigator.sendBeacon && navigator.sendBeacon("api/live/stop"); });
  if($("#runPick").value) await openReplay($("#runPick").value);
  requestAnimationFrame(frame);
}
init();
