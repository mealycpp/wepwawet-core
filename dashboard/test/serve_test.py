# Python server that mirrors the replay routes of wcore_dash.ps1 (Linux/macOS/Windows; replay only, no live mode).
# Usage: python3 dashboard/test/serve_test.py   ->  http://127.0.0.1:8088/
import http.server, json, os, re, sys, urllib.parse, datetime, glob, time, hashlib
ROOT=os.environ.get("WCORE_ROOT",os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))); HERE=ROOT+"/dashboard"; RES=ROOT+"/results"
LIVE=os.environ.get("WCORE_LIVE_DIR","/tmp/wcore_live")  # /api/live serves probe lines found in this folder
def run_epoch(n):
    try: return datetime.datetime.strptime(n[:15],"%Y%m%d_%H%M%S").timestamp()
    except Exception: return None
def extras():
    # duplex pairs: same run on both boards (board_logs/<board>/wepwawet-core/logs/mission_runs), names within 5 s, same suffix
    m1=RES+"/board_logs/aup1/wepwawet-core/logs/mission_runs"; m2=RES+"/board_logs/aup2/wepwawet-core/logs/mission_runs"; dup=[]
    n2=[os.path.basename(x.rstrip("/")) for x in glob.glob(m2+"/*/")]
    for a in sorted(os.path.basename(x.rstrip("/")) for x in glob.glob(m1+"/*/")):
        ta=run_epoch(a)
        if ta is None: continue
        for b in n2:
            tb=run_epoch(b)
            if tb is not None and a[15:]==b[15:] and abs(ta-tb)<=5:
                crash=any(os.path.exists(f) and "Assert:" in open(f,errors="ignore").read() for f in (m1+"/"+a+"/fsw.log", m2+"/"+b+"/fsw.log"))
                dup.append({"aup1":a,"aup2":b,"crashed":crash}); break
    try: excl=json.load(open(HERE+"/excluded_runs.json",encoding="utf-8"))
    except Exception: excl=[]
    # certificate-check evidence: console output of wcore_cert_check saved as cert_check*.log
    cert={}
    for b in ("aup1","aup2"):
        fl=glob.glob(RES+"/ground_ca/evidence/cert_check*"+b+"*.log")+glob.glob(RES+"/board_logs/"+b+"/wepwawet-core/logs/cert_check*.log")+glob.glob(RES+"/board_logs/"+b+"/aup_kit_v8_duplex/cert_check*.log")
        cert[b]=[{"file":os.path.relpath(f,RES).replace(os.sep,"/"),"mtime":os.path.getmtime(f),"text":open(f,errors="ignore").read()[:4000]} for f in sorted(fl)]
    issued=[{"file":os.path.basename(f),"mtime":os.path.getmtime(f)} for f in sorted(glob.glob(RES+"/certificates/*.cert"))]
    pk={}
    for b in ("aup1","aup2"):
        f=RES+"/certificates/"+b+"_node_pk_v8.bin"
        if os.path.isfile(f): pk[b]={"file":os.path.basename(f),"sha256":hashlib.sha256(open(f,"rb").read()).hexdigest(),"mtime":os.path.getmtime(f),"bytes":os.path.getsize(f)}
    return dup,excl,{"checks":cert,"issued":issued},pk
def runs():
    lst=[]
    for d in sorted(glob.glob(RES+"/mission_runs_v7_sweep/*/")):
        f=d+"fsw.log"; crash=os.path.exists(f) and "Assert:" in open(f,errors="ignore").read()
        lst.append({"name":os.path.basename(d.rstrip("/")),"crashed":crash,"files":os.listdir(d)})
    n1=RES+"/board_logs/aup1/wepwawet-core/logs"; n2=RES+"/board_logs/aup2/wepwawet-core/logs"; nodes=[]
    T=lambda n: datetime.datetime.strptime(n[5:],"%Y%m%d_%H%M%S")
    c2=[os.path.basename(x) for x in glob.glob(n2+"/node_*")]
    for a in sorted(os.path.basename(x) for x in glob.glob(n1+"/node_*")):
        best=min(c2,key=lambda c:abs((T(c)-T(a)).total_seconds()),default=None)
        if best and abs((T(best)-T(a)).total_seconds())<=120: nodes.append({"aup1":a,"aup2":best})
    dup,excl,cert,pk=extras()
    return {"mission":lst,"node":nodes,"aup2_hw":os.path.exists(n2+"/fprime_hw_stats.csv"),"duplex":dup,"excluded":excl,"cert":cert,"pk":pk}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,code,body,ctype):
        b=body if isinstance(body,bytes) else body.encode(); self.send_response(code); self.send_header("Content-Type",ctype); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self): self.do_GET()
    def do_GET(self):
        p=urllib.parse.urlparse(self.path).path
        if p=="/": p="/index.html"
        if p=="/api/runs": return self.send(200,json.dumps(runs()),"application/json")
        if p=="/api/live/stop": return self.send(200,'{"stopped":true}',"application/json")
        if p=="/api/live":
            o={}
            for b in ("aup1","aup2"):
                f=f"{LIVE}/{b}.jsonl"; lines=[l.strip() for l in open(f)][-15:] if os.path.exists(f) else []
                o[b]={"alive":True,"lines":lines,"err":"","now":time.time()}
            return self.send(200,json.dumps(o),"application/json")
        m=re.match(r"^/data/(.+)$",p)
        if m:
            rel=urllib.parse.unquote(m.group(1)); f=os.path.realpath(os.path.join(RES,rel))
            if re.search(r"(?i)identity|node_sk|ground_sk|\.bin$|\.bit$|\.tgz$",rel): return self.send(403,'{"error":"blocked"}',"application/json")
            if not f.startswith(RES) or not os.path.isfile(f): return self.send(404,'{"error":"not found"}',"application/json")
            return self.send(200,open(f,"rb").read(),"text/plain")
        f=os.path.realpath(HERE+p)
        if not os.path.isfile(f): return self.send(404,"nf","text/plain")
        ct={".html":"text/html",".js":"application/javascript",".css":"text/css",".png":"image/png",".json":"application/json"}.get(os.path.splitext(f)[1],"application/octet-stream")
        return self.send(200,open(f,"rb").read(),ct)
http.server.ThreadingHTTPServer(("127.0.0.1",8088),H).serve_forever()
