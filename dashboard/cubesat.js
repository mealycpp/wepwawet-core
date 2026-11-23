// WEPWAWET-CORE dashboard: stage drawing (two 3U CubeSats, Earth limb, crosslink, packets).
"use strict";
const SVGNS = "http://www.w3.org/2000/svg";
function el(tag, attrs, parent){ const e=document.createElementNS(SVGNS,tag); for(const k in (attrs||{})) e.setAttribute(k,attrs[k]); if(parent) parent.appendChild(e); return e; }
function lerp(a,b,t){ return [a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t]; }
function quad(p00,p10,p11,p01,u0,u1,v0,v1){ // bilinear sub-quad
  const P=(u,v)=>lerp(lerp(p00,p10,u),lerp(p01,p11,u),v);
  return [P(u0,v0),P(u1,v0),P(u1,v1),P(u0,v1)].map(p=>p[0].toFixed(1)+","+p[1].toFixed(1)).join(" ");
}
function solarPanel(g, p00,p10,p11,p01, cols, rows){
  el("polygon",{points:[p00,p10,p11,p01].map(p=>p.join(",")).join(" "),fill:"url(#frame)",stroke:"#9aa3b5","stroke-width":1.2},g);
  const m=0.035;
  for(let c=0;c<cols;c++) for(let r=0;r<rows;r++){
    const u0=m+(1-2*m)*c/cols+0.006, u1=m+(1-2*m)*(c+1)/cols-0.006, v0=m+(1-2*m)*r/rows+0.006, v1=m+(1-2*m)*(r+1)/rows-0.006;
    el("polygon",{points:quad(p00,p10,p11,p01,u0,u1,v0,v1),fill:"url(#cell)",stroke:"#3d5a9a","stroke-width":0.4},g);
  }
  // specular sweep
  el("polygon",{points:quad(p00,p10,p11,p01,0.05,0.95,0.05,0.35),fill:"url(#sheen)",opacity:0.35},g);
}
function defs(svg){
  const d=el("defs",{},svg);
  const lg=(id,stops,x2="1",y2="0")=>{const g=el("linearGradient",{id,x1:"0",y1:"0",x2,y2},d); stops.forEach(([o,c,a])=>el("stop",{offset:o,"stop-color":c,"stop-opacity":a==null?1:a},g)); return g;};
  lg("alFront",[["0","#9aa1ad"],["0.45","#d9dde4"],["1","#7d8491"]]);
  lg("alSide",[["0","#5d6471"],["1","#3c424d"]]);
  lg("alTop",[["0","#e8ebf0"],["1","#aab1bd"]]);
  lg("rail",[["0","#f4f5f7"],["0.5","#b8bec8"],["1","#80868f"]]);
  lg("cell",[["0","#1b2f6b"],["0.55","#10204f"],["1","#24407f"]],"1","1");
  lg("frame",[["0","#c4cad6"],["1","#7e8697"]],"1","1");
  lg("sheen",[["0","#ffffff",0.5],["1","#ffffff",0]],"0","1");
  lg("gold",[["0","#f2d27a"],["1","#9c7a1c"]],"1","1");
  const rg=el("radialGradient",{id:"earth",cx:"0.5",cy:"0.0",r:"0.9"},d);
  [["0","#2b6cb0"],["0.35","#123a73"],["1","#050b1a"]].forEach(([o,c])=>el("stop",{offset:o,"stop-color":c},rg));
  const at=el("radialGradient",{id:"atmo",cx:"0.5",cy:"0.5",r:"0.5"},d);
  [["0.94","#6ec3ff",0],["0.975","#6ec3ff",0.55],["1","#6ec3ff",0]].forEach(([o,c,a])=>el("stop",{offset:o,"stop-color":c,"stop-opacity":a},at));
  const es=el("radialGradient",{id:"earthShade",cx:"0.5",cy:"0.0",r:"0.9"},d);
  [["0","#000000",0],["0.35","#000000",0.25],["1","#000000",0.85]].forEach(([o,c,a])=>el("stop",{offset:o,"stop-color":c,"stop-opacity":a},es));
  const sg=el("radialGradient",{id:"sunGlow",cx:"0.5",cy:"0.5",r:"0.5"},d);
  [["0","#fff3c4",0.9],["0.3","#f2d27a",0.35],["1","#f2d27a",0]].forEach(([o,c,a])=>el("stop",{offset:o,"stop-color":c,"stop-opacity":a},sg));
  const lens=el("radialGradient",{id:"lens",cx:"0.4",cy:"0.35",r:"0.7"},d);
  [["0","#8fb6ff"],["0.35","#1a2b55"],["1","#03060d"]].forEach(([o,c])=>el("stop",{offset:o,"stop-color":c},lens));
  const glow=el("filter",{id:"glow",x:"-50%",y:"-50%",width:"200%",height:"200%"},d);
  el("feGaussianBlur",{stdDeviation:"4",result:"b"},glow); const mg=el("feMerge",{},glow); el("feMergeNode",{in:"b"},mg); el("feMergeNode",{in:"SourceGraphic"},mg);
  const sh=el("filter",{id:"shadow",x:"-20%",y:"-20%",width:"140%",height:"140%"},d);
  el("feDropShadow",{dx:"3",dy:"6",stdDeviation:"5","flood-color":"#000","flood-opacity":"0.55"},sh);
}
// one 3U CubeSat; local frame: front face (0,0)-(70,210); returns world positions of features
function cubesat(svg, x0, y0, flip, name){
  const s = flip?-1:1;
  const outer = el("g",{transform:`translate(${x0},${y0})`},svg);
  const wob = el("g",{},outer);                       // attitude wobble (visual layer)
  const light = el("g",{style:"transition:filter 1.2s ease"},wob); // sunlight / eclipse (visual layer)
  const g = el("g",{transform:`scale(${s},1)`,filter:"url(#shadow)"},light);
  // deployed wings (behind body)
  solarPanel(g,[-6,34],[-126,16],[-126,164],[-6,182],4,6);
  solarPanel(g,[-132,15],[-252,-3],[-252,145],[-132,163],4,6);
  el("line",{x1:-6,y1:60,x2:-2,y2:60,stroke:"#c8ccd4","stroke-width":3},g);
  el("line",{x1:-6,y1:156,x2:-2,y2:156,stroke:"#c8ccd4","stroke-width":3},g);
  solarPanel(g,[106,8],[226,-10],[226,138],[106,156],4,6);
  solarPanel(g,[232,-11],[352,-29],[352,119],[232,137],4,6);
  // body
  el("polygon",{points:"0,0 70,0 100,-22 30,-22",fill:"url(#alTop)",stroke:"#6b717c","stroke-width":0.8},g);
  el("polygon",{points:"70,0 100,-22 100,188 70,210",fill:"url(#alSide)",stroke:"#2c3139","stroke-width":0.8},g);
  // body-mounted cells on the side face
  for(let u=0;u<3;u++) el("polygon",{points:quad([72,u*70+3],[98,u*70-17],[98,u*70+47],[72,u*70+67],0.08,0.92,0.06,0.94),fill:"url(#cell)",stroke:"#3d5a9a","stroke-width":0.4},g);
  el("rect",{x:0,y:0,width:70,height:210,fill:"url(#alFront)",stroke:"#5a606b","stroke-width":0.8},g);
  [70,140].forEach(y=>{ el("line",{x1:2,y1:y,x2:68,y2:y,stroke:"#6f7682","stroke-width":1},g); el("line",{x1:70,y1:y,x2:100,y2:y-22,stroke:"#2b3038","stroke-width":1},g); });
  // rails
  el("rect",{x:-3,y:-2,width:7,height:214,fill:"url(#rail)",rx:1},g);
  el("rect",{x:66,y:-2,width:7,height:214,fill:"url(#rail)",rx:1},g);
  el("polygon",{points:"97,-24 103,-24 103,186 97,190",fill:"url(#rail)"},g);
  [[-3,-6],[66,-6],[-3,210],[66,210]].forEach(([x,y])=>el("rect",{x,y,width:7,height:6,fill:"#e3e6ea",stroke:"#8a909a","stroke-width":0.5},g));
  // screws
  [[8,8],[62,8],[8,202],[62,202],[8,78],[62,78],[8,148],[62,148]].forEach(([x,y])=>el("circle",{cx:x,cy:y,r:1.4,fill:"#4b515b"},g));
  // unit 1: TRNG LED + sun sensor; unit 2: PL fabric chip; unit 3: imager
  el("rect",{x:14,y:16,width:16,height:12,fill:"#1b1f27",stroke:"#9aa0aa","stroke-width":0.6},g);
  el("rect",{x:17,y:19,width:10,height:6,fill:"#2c3a66"},g);
  const trng = el("circle",{cx:50,cy:24,r:5,fill:"#203a2c",stroke:"#9aa0aa","stroke-width":0.8},g);
  const chipBg = el("rect",{x:12,y:88,width:46,height:34,rx:2,fill:"#111827",stroke:"url(#gold)","stroke-width":2},g);
  for(let i=0;i<6;i++){ el("line",{x1:16+i*7.5,y1:84,x2:16+i*7.5,y2:88,stroke:"#d4af37","stroke-width":1.2},g); el("line",{x1:16+i*7.5,y1:122,x2:16+i*7.5,y2:126,stroke:"#d4af37","stroke-width":1.2},g); }
  const chip = el("rect",{x:16,y:92,width:38,height:26,rx:1.5,fill:"#1c3a2c",stroke:"#2f8f5f","stroke-width":1},g);
  const lock = el("g",{visibility:"hidden"},g);          // key-sealed mark on the PL block (evidence-driven)
  el("path",{d:"M 44 96 v -4 a 5 5 0 0 1 10 0 v 4",fill:"none",stroke:"#f2d27a","stroke-width":2},lock);
  el("rect",{x:41.5,y:96,width:15,height:11,rx:1.5,fill:"#f2d27a",stroke:"#7a5d16","stroke-width":0.6},lock);
  el("circle",{cx:49,cy:101,r:1.6,fill:"#3b2c06"},lock);
  el("circle",{cx:35,cy:174,r:20,fill:"#20252e",stroke:"#9aa0aa","stroke-width":1.5},g);
  el("circle",{cx:35,cy:174,r:14,fill:"url(#lens)"},g);
  const lensFlash = el("circle",{cx:35,cy:174,r:14,fill:"#7cc7ff",opacity:0},g);
  el("circle",{cx:31,cy:169,r:3,fill:"#ffffff",opacity:0.5},g);
  // antenna (UHF whip + patch) on top face
  el("rect",{x:40,y:-19,width:22,height:10,fill:"#c39a3a",stroke:"#7a5d16","stroke-width":0.6,transform:"skewX(-50)"},g);
  el("line",{x1:52,y1:-14,x2:52,y2:-84,stroke:"#d9dde4","stroke-width":2},g);
  el("circle",{cx:52,cy:-86,r:3.2,fill:"#e9edf3"},g);
  const wx = (lx)=> x0 + s*lx;
  return { chip, chipBg, lock, trng, lensFlash, antenna:[wx(52), y0-86], ant0:[s*52,-86], pivot:[s*50,105], x0, y0, wob, light, bodyCx: wx(50), bottom: y0+215, name };
}
function buildStage(svg){
  svg.innerHTML=""; defs(svg);
  // Earth limb
  el("circle",{cx:940,cy:1590,r:1300,fill:"url(#earth)"},svg);
  const cp = el("clipPath",{id:"earthClip"},svg.querySelector("defs")); el("circle",{cx:940,cy:1590,r:1300},cp);
  const surf = el("g",{"clip-path":"url(#earthClip)"},svg);
  const drift = el("g",{},surf);
  // deterministic pseudo-random land masses and cloud bands (decorative texture only), two copies for a seamless loop
  let seed=7; const rnd=()=>{ seed=(seed*16807)%2147483647; return seed/2147483647; };
  const TILE=2700, shapes=[];
  for(let i=0;i<26;i++) shapes.push(["land", rnd()*TILE, 300+rnd()*170, 60+rnd()*170, 10+rnd()*26, rnd()*20-10]);
  for(let i=0;i<46;i++) shapes.push(["cloud", rnd()*TILE, 292+rnd()*175, 40+rnd()*160, 4+rnd()*9, rnd()*10-5]);
  for(const off of [0,TILE]) for(const [k,x,y,rx,ry,rot] of shapes)
    el("ellipse",{cx:(x+off-400).toFixed(1),cy:y.toFixed(1),rx:rx.toFixed(1),ry:ry.toFixed(1),transform:`rotate(${rot.toFixed(1)} ${(x+off-400).toFixed(1)} ${y.toFixed(1)})`,
      fill: k==="land" ? "#2c5a3e" : "#ffffff", opacity: k==="land" ? 0.45 : 0.16},drift);
  el("circle",{cx:940,cy:1590,r:1300,fill:"url(#earthShade)"},svg);
  el("circle",{cx:940,cy:1590,r:1330,fill:"url(#atmo)"},svg);
  const sun = el("g",{style:"transition:opacity 1.2s ease"},svg);
  el("circle",{cx:70,cy:70,r:60,fill:"url(#sunGlow)"},sun); el("circle",{cx:70,cy:70,r:13,fill:"#fff6d8"},sun);
  // satellites
  const A = cubesat(svg, 300, 150, false, "AUP1");
  const B = cubesat(svg, 1580, 150, true, "AUP2");
  // two crosslink arcs between the antenna tips: upper AUP1->AUP2, lower AUP2->AUP1
  const [ax,ay]=A.antenna, [bx,by]=B.antenna;
  const d = `M ${ax} ${ay} Q 940 ${ay-90} ${bx} ${by}`, d2 = `M ${bx} ${by} Q 940 ${by+56} ${ax} ${ay}`;
  const mk = el("marker",{id:"arr",viewBox:"0 0 10 10",refX:"9",refY:"5",markerWidth:"7",markerHeight:"7",orient:"auto-start-reverse"},svg.querySelector("defs"));
  el("path",{d:"M 0 1 L 10 5 L 0 9 z",fill:"#d4af37"},mk);
  const glowPath = el("path",{d,fill:"none",stroke:"#d4af37","stroke-opacity":0.18,"stroke-width":10},svg);
  const path = el("path",{d,fill:"none",stroke:"#d4af37","stroke-opacity":0.7,"stroke-width":1.4,"stroke-dasharray":"6 7",id:"linkPath","marker-end":"url(#arr)"},svg);
  const glowPath2 = el("path",{d:d2,fill:"none",stroke:"#7cc7ff","stroke-opacity":0.12,"stroke-width":10},svg);
  const path2 = el("path",{d:d2,fill:"none",stroke:"#7cc7ff","stroke-opacity":0.7,"stroke-width":1.4,"stroke-dasharray":"6 7",id:"linkPath2","marker-end":"url(#arr)"},svg);
  const dirA = el("text",{x:940,y:ay-52,"text-anchor":"middle",fill:"#d4af37","font-family":"Consolas,monospace","font-size":11},svg); dirA.textContent="AUP1 → AUP2";
  const dirB = el("text",{x:940,y:ay+44,"text-anchor":"middle",fill:"#7cc7ff","font-family":"Consolas,monospace","font-size":11},svg); dirB.textContent="AUP2 → AUP1";
  const label = el("text",{x:940,y:ay+70,"text-anchor":"middle",fill:"#d4af37","font-family":"Georgia,serif","font-size":15,"letter-spacing":"3"},svg);
  label.textContent = "PQC CROSSLINK · ML-DSA-44 SIGNED FRAMES · TCP 9091";
  const sub = el("text",{x:940,y:ay+92,"text-anchor":"middle",fill:"#8c9ab8","font-family":"Segoe UI,Arial","font-size":12},svg);
  sub.textContent = "";
  // ground station + certificate lane (greyed unless certificate evidence exists for the selected run)
  const ground = el("g",{opacity:0.32,style:"transition:opacity .6s ease"},svg);
  const gx=940, gy=318;
  const gpA = el("path",{d:`M ${gx-34} ${gy+6} Q ${(gx+A.bodyCx)/2+40} ${gy-70} ${A.bodyCx+118} ${A.y0+150}`,fill:"none",stroke:"#9fb4e0","stroke-opacity":0.55,"stroke-width":1.1,"stroke-dasharray":"2 6"},ground);
  const gpB = el("path",{d:`M ${gx+34} ${gy+6} Q ${(gx+B.bodyCx)/2-40} ${gy-70} ${B.bodyCx-118} ${B.y0+150}`,fill:"none",stroke:"#9fb4e0","stroke-opacity":0.55,"stroke-width":1.1,"stroke-dasharray":"2 6"},ground);
  el("path",{d:`M ${gx-26} ${gy-4} Q ${gx} ${gy+26} ${gx+26} ${gy-4} Z`,fill:"#c9ced8",stroke:"#6b717c","stroke-width":1},ground);       // dish
  el("line",{x1:gx,y1:gy-2,x2:gx,y2:gy-22,stroke:"#d9dde4","stroke-width":1.6},ground); el("circle",{cx:gx,cy:gy-24,r:2.6,fill:"#f2d27a"},ground);
  el("path",{d:`M ${gx-10} ${gy+34} L ${gx} ${gy+12} L ${gx+10} ${gy+34} Z`,fill:"#7e8697",stroke:"#4b515b","stroke-width":0.8},ground);    // mast
  el("rect",{x:gx-22,y:gy+34,width:44,height:5,fill:"#4b515b"},ground);
  const gT=(y,size,fill,fam)=>el("text",{x:gx,y,"text-anchor":"middle",fill,stroke:"#070d1c","stroke-width":3,"paint-order":"stroke","font-family":fam||"Segoe UI,Arial","font-size":size},ground);
  const gTitle = gT(gy+58,13,"#f2d27a","Georgia,serif"); gTitle.setAttribute("letter-spacing","2"); gTitle.textContent="GROUND · CERTIFICATE AUTHORITY";
  const gStatus = gT(gy+76,11.5,"#c7d2ea"); gStatus.textContent="no certificate exchange recorded for this run";
  const gLine2 = gT(gy+92,11,"#9fb0d3"); gLine2.textContent="";
  const tok = (col)=>{ const c=el("circle",{r:5,fill:col,visibility:"hidden",filter:"url(#glow)"},ground); return c; };
  const G = { g:ground, pathA:gpA, pathB:gpB, lenA:gpA.getTotalLength(), lenB:gpB.getTotalLength(), tokA:tok("#f2d27a"), tokB:tok("#f2d27a"), status:gStatus, line2:gLine2 };
  const packets = el("g",{},svg);
  // names + PL readouts under each satellite
  const nameText=(S,x,anchor)=>{ const t=el("text",{x,y:S.bottom+22,"text-anchor":anchor,fill:"#f2d27a",stroke:"#070d1c","stroke-width":3,"paint-order":"stroke","font-family":"Georgia,serif","font-size":20,"letter-spacing":"3"},svg); t.textContent=S.name+" · CubeSat"; 
      const r=el("text",{x,y:S.bottom+42,"text-anchor":anchor,fill:"#bfe9d2",stroke:"#070d1c","stroke-width":3,"paint-order":"stroke","font-family":"Consolas,monospace","font-size":13},svg); r.textContent="PL fabric idle";
      S.vis=el("text",{x,y:S.bottom+60,"text-anchor":anchor,fill:"#a9b6d3",stroke:"#070d1c","stroke-width":3,"paint-order":"stroke","font-family":"Segoe UI,Arial","font-size":11},svg); S.vis.textContent="";
      S.keyText=el("text",{x,y:S.bottom+77,"text-anchor":anchor,fill:"#8c9ab8",stroke:"#070d1c","stroke-width":3,"paint-order":"stroke","font-family":"Segoe UI,Arial","font-size":12},svg); S.keyText.textContent=""; return r; };
  A.readout = nameText(A, A.bodyCx, "middle"); B.readout = nameText(B, B.bodyCx, "middle");
  const vnote = el("text",{x:940,y:ay+112,"text-anchor":"middle",fill:"#6f7da0","font-family":"Segoe UI,Arial","font-size":11},svg);
  vnote.textContent = "visual layer: Earth drift illustrative · satellites hold attitude (ADCS pointing)";
  return { A, B, path, glowPath, path2, glowPath2, dirA, dirB, ground:G, packets, sub, sun, drift, TILE, len: path.getTotalLength(), len2: path2.getTotalLength() };
}

// ---- visual layer (never changes a number on screen) ----
const WOBBLE_GAIN = 50, WOBBLE_MAX_DEG = 4;
function setSatVisual(st, S, sunlit, wobbleDeg, caption){
  S.light.style.filter = sunlit===false ? "brightness(0.38) saturate(0.6)" : "none";
  S.wob.setAttribute("transform", `rotate(${wobbleDeg.toFixed(3)} ${S.pivot[0]} ${S.pivot[1]})`);
  const a = wobbleDeg*Math.PI/180, [ax,ay]=S.ant0, [px,py]=S.pivot;
  S.antenna = [S.x0 + px + (ax-px)*Math.cos(a) - (ay-py)*Math.sin(a), S.y0 + py + (ax-px)*Math.sin(a) + (ay-py)*Math.cos(a)];
  if(S.vis.textContent!==caption) S.vis.textContent = caption;
}
function updateLink(st){
  const [ax,ay]=st.A.antenna, [bx,by]=st.B.antenna;
  st.path.setAttribute("d", `M ${ax.toFixed(1)} ${ay.toFixed(1)} Q 940 ${(Math.min(ay,by)-90).toFixed(1)} ${bx.toFixed(1)} ${by.toFixed(1)}`);
  st.glowPath.setAttribute("d", st.path.getAttribute("d")); st.len = st.path.getTotalLength();
  st.path2.setAttribute("d", `M ${bx.toFixed(1)} ${by.toFixed(1)} Q 940 ${(Math.max(ay,by)+56).toFixed(1)} ${ax.toFixed(1)} ${ay.toFixed(1)}`);
  st.glowPath2.setAttribute("d", st.path2.getAttribute("d")); st.len2 = st.path2.getTotalLength();
}

// key custody mark on a satellite: only what the run's own files show (state: sealed | host | cpu | null)
function setKeyBadge(Sat, key, extra){
  if(!key){ Sat.lock.setAttribute("visibility","hidden"); Sat.chipBg.setAttribute("stroke","url(#gold)"); Sat.keyText.textContent = extra||""; Sat.keyText.setAttribute("fill","#8c9ab8"); return; }
  const sealed = key.state==="sealed";
  Sat.lock.setAttribute("visibility", sealed ? "visible" : "hidden");
  Sat.keyText.textContent = (sealed ? key.text.toUpperCase() : key.text) + (extra? " · "+extra : "");
  Sat.keyText.setAttribute("fill", sealed ? "#7dffb5" : key.state==="cpu" ? "#f3a23a" : "#c7d2ea");
}
