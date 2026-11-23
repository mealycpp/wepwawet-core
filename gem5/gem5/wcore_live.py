#!/usr/bin/env python3
"""
WEPWAWET-CORE live comparison.

Runs the three driver-replay cases in gem5, one after another, and serves a
page whose graphs advance while each simulation is running:

    B  Stage 8 as the backend drives it today
    C  proposed chaining, conservative   (MODEL-PREDICTED hardware behaviour)
    C  proposed chaining, optimistic     (MODEL-PREDICTED hardware behaviour)

From the gem5 folder:
    python3 wcore_gem5/gem5/wcore_live.py
    then open  http://localhost:8766

    python3 wcore_gem5/gem5/wcore_live.py --mmio-latency 1000ns --interval-us 2000

Every number on the page is SIMULATED in gem5 with stand-in register blocks.
None is a measurement from AUP1. Stop with Ctrl+C.
"""

import argparse
import base64
import json
import re
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
END_MARK = "End Simulation Statistics"
WANTED = {
    "ticks": r"^simTicks$", "insts": r"^simInsts$",
    "mmio_r": r"membus\.transDist::ReadReq$", "mmio_w": r"membus\.transDist::WriteReq$",
    "ddr_r": r"mem_ctrl\.readReqs$", "ddr_w": r"mem_ctrl\.writeReqs$",
}


def parse_block(text):
    found = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            value = float(parts[1])
        except ValueError:
            continue
        for key, pattern in WANTED.items():
            if key not in found and re.search(pattern, parts[0]):
                found[key] = value
    return found


class Case:
    def __init__(self, name, scenario):
        self.name = name
        self.label = scenario["case"]
        self.binary = scenario["binary"] or f"wcore_replay_{name}"
        self.expected_r = scenario["expected_mmio_reads"]
        self.expected_w = scenario["expected_mmio_writes"]
        acc = scenario["accounting"]
        self.dispatches, self.programs = acc["kernel_dispatches"], acc["programs"]
        self.sleep_s = acc["driver_sleep_seconds"]
        self.state, self.intervals, self.wall, self.error, self.check = "waiting", [], 0.0, "", ""


class Monitor:
    def __init__(self, args, meta):
        self.args, self.meta = args, meta
        self.cases = [Case(n, s) for n, s in meta["scenarios"].items()]
        self.lock = threading.Lock()
        self.proc = None
        self.done = False

    def follow(self, case, path, started):
        offset, pending = 0, ""
        while True:
            running = self.proc.poll() is None
            if path.exists():
                with open(path, "rb") as f:
                    f.seek(offset)
                    raw = f.read()
                offset += len(raw)
                pending += raw.decode(errors="replace")
                while END_MARK in pending:
                    block, pending = pending.split(END_MARK, 1)
                    b = parse_block(block)
                    if b.get("ticks", 0) > 0:
                        with self.lock:
                            case.intervals.append([b["ticks"], b.get("insts", 0), b.get("mmio_r", 0),
                                                   b.get("mmio_w", 0), b.get("ddr_r", 0) + b.get("ddr_w", 0)])
                            case.wall = round(time.time() - started, 2)
            if not running:
                if path.exists() and path.stat().st_size > offset:
                    continue
                break
            time.sleep(0.2)

    def run(self):
        a = self.args
        out = Path(a.out)
        shutil.rmtree(out, ignore_errors=True)
        for case in self.cases:
            outdir = out / case.name
            outdir.mkdir(parents=True)
            cmd = [str(a.gem5), f"--outdir={outdir}", str(HERE / "wcore_se.py"), "--binary",
                   str(HERE / "build" / case.binary), "--mmio-latency", a.mmio_latency, "--cpu", a.cpu,
                   "--dump-ticks", str(int(a.interval_us * 1_000_000))]
            started = time.time()
            with self.lock:
                case.state = "running"
            with open(outdir / "run.log", "w") as log:
                self.proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
            self.follow(case, outdir / "stats.txt", started)
            code = self.proc.wait()
            log_text = (outdir / "run.log").read_text(errors="replace")
            with self.lock:
                case.wall = round(time.time() - started, 2)
                got_r, got_w = sum(i[2] for i in case.intervals), sum(i[3] for i in case.intervals)
                if code != 0 or "wcore_replay jobs" not in log_text:
                    case.state = "failed"
                    case.error = f"gem5 exit {code}. Last lines of {outdir / 'run.log'}:\n" + "\n".join(log_text.splitlines()[-8:])
                else:
                    case.state = "finished"
                    ok = got_r == case.expected_r and got_w == case.expected_w
                    case.check = ("MATCH" if ok else "MISMATCH") + \
                        f": bus saw {got_r:,.0f} reads and {got_w:,.0f} writes, expected {case.expected_r:,} and {case.expected_w:,}"
            print(f"  {case.name:16s} {case.state:9s} {len(case.intervals):5d} intervals  {case.wall:7.1f} s  {case.check or case.error}", flush=True)
        self.done = True

    def snapshot(self, starts):
        with self.lock:
            a = self.args
            cases = []
            for k, c in enumerate(self.cases):
                start = starts[k] if k < len(starts) else 0
                cases.append(dict(name=c.name, label=c.label, state=c.state, count=len(c.intervals), start=start,
                                  intervals=c.intervals[start:], wall=c.wall, expected=c.expected_r + c.expected_w,
                                  dispatches=c.dispatches, programs=c.programs, sleep_s=c.sleep_s,
                                  check=c.check, error=c.error))
            return dict(done=self.done, cases=cases,
                        config=dict(latency=a.mmio_latency, cpu=a.cpu, interval_us=a.interval_us,
                                    workload=self.meta["workload"], iterations=self.meta["rejection_iterations"]))


def make_handler(monitor, page):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, body, kind):
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/data":
                try:
                    starts = [max(0, int(x)) for x in parse_qs(url.query).get("from", ["0"])[0].split(",")]
                except ValueError:
                    starts = []
                self.send(json.dumps(monitor.snapshot(starts)).encode(), "application/json")
            elif url.path in ("/", "/index.html"):
                self.send(page, "text/html; charset=utf-8")
            else:
                self.send_error(404)

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gem5", default="build/ARM/gem5.opt")
    ap.add_argument("--mmio-latency", default="200ns", help="response latency of every register access (a parameter)")
    ap.add_argument("--cpu", default="timing", choices=["timing", "o3"])
    ap.add_argument("--interval-us", type=float, default=500.0, help="simulated microseconds per graph point")
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--out", default="wcore_live_runs")
    args = ap.parse_args()
    args.gem5 = Path(args.gem5)
    if not args.gem5.exists():
        sys.exit(f"gem5 binary not found at {args.gem5}. Run this from the gem5 folder or pass --gem5.")
    meta = json.loads((HERE / "build" / "scenarios.json").read_text())
    seal = HERE / "rscl-seal.png"
    seal_uri = "data:image/png;base64," + base64.b64encode(seal.read_bytes()).decode() if seal.exists() else ""
    page = (HERE / "wcore_live_template.html").read_text().replace("__SEAL_URI__", seal_uri).encode()

    monitor = Monitor(args, meta)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(monitor, page))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Live page:  http://localhost:{args.port}")
    print(f"Register latency {args.mmio_latency} (parameter), one point per {args.interval_us:g} simulated microseconds\n")
    worker = threading.Thread(target=monitor.run, daemon=True)
    worker.start()
    try:
        worker.join()
        print(f"\nAll cases done. Page still at http://localhost:{args.port}. Press Ctrl+C to stop.")
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        if monitor.proc and monitor.proc.poll() is None:
            monitor.proc.terminate()
        print("\nStopped.")


if __name__ == "__main__":
    main()
