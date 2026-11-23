#!/usr/bin/env python3
"""
Run the driver-replay scenarios in gem5 and collect a comparison CSV.

From the gem5 folder:
    python3 wcore_gem5/gem5/run_gem5.py --quick      # one latency, checks the setup (3 runs)
    python3 wcore_gem5/gem5/run_gem5.py              # 3 cases x 3 MMIO latencies (9 runs)

Output: wcore_gem5/results/gem5_case_comparison.csv
Every row is SIMULATED in gem5. None is a measurement from AUP1.
"""
import argparse
import csv
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASIS = ("SIMULATED: gem5 ARM SE, C replay of the driver bus sequence, stand-in register blocks "
         "with parameter latency; excludes driver sleeps and Python overhead; not AUP1")

WANTED = {
    "simSeconds": r"^simSeconds$", "simTicks": r"^simTicks$", "simInsts": r"^simInsts$",
    "hostSeconds": r"^hostSeconds$", "numCycles": r"\.numCycles$",
    "bus_ReadReq": r"membus\.transDist::ReadReq$", "bus_WriteReq": r"membus\.transDist::WriteReq$",
    "ddr_readReqs": r"mem_ctrl\.readReqs$", "ddr_writeReqs": r"mem_ctrl\.writeReqs$",
    "ddr_bytesRead": r"mem_ctrl\.bytesReadSys$", "ddr_bytesWritten": r"mem_ctrl\.bytesWrittenSys$",
    "ddr_avgMemAccLat": r"mem_ctrl\.dram\.avgMemAccLat$", "ddr_avgQLat": r"mem_ctrl\.dram\.avgQLat$",
    "l1d_misses": r"l1d-cache-0\.overallMisses::total$|l1dcaches\d*\.overallMisses::total$",
    "l1d_accesses": r"l1d-cache-0\.overallAccesses::total$|l1dcaches\d*\.overallAccesses::total$",
    "l1i_misses": r"l1i-cache-0\.overallMisses::total$|l1icaches\d*\.overallMisses::total$",
    "l2_misses": r"l2-cache-0\.overallMisses::total$|l2caches\d*\.overallMisses::total$",
}


def parse_stats(path):
    found = {}
    for line in path.read_text(errors="replace").splitlines():
        if "End Simulation Statistics" in line:
            break
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gem5", default="build/ARM/gem5.opt")
    ap.add_argument("--out", default="wcore_runs")
    ap.add_argument("--latencies", default="50ns,200ns,1000ns")
    ap.add_argument("--cpu", default="timing")
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()
    if not Path(args.gem5).exists():
        sys.exit(f"gem5 binary not found at {args.gem5}. Run this from the gem5 folder or pass --gem5.")
    meta = json.loads((HERE / "build" / "scenarios.json").read_text())
    latencies = ["200ns"] if args.quick else args.latencies.split(",")
    rows, problems = [], []
    for latency in latencies:
        for name, sc in meta["scenarios"].items():
            outdir = Path(args.out) / f"{name}_{latency}_{args.cpu}"
            outdir.mkdir(parents=True, exist_ok=True)
            cmd = [args.gem5, f"--outdir={outdir}", str(HERE / "wcore_se.py"), "--binary",
                   str(HERE / "build" / (sc["binary"] or "wcore_replay_" + name)), "--mmio-latency", latency, "--cpu", args.cpu]
            print("running", name, latency, "...", flush=True)
            with open(outdir / "run.log", "w") as log:
                code = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
            log_text = (outdir / "run.log").read_text(errors="replace")
            finished = "wcore_replay jobs" in log_text
            if code != 0 or not finished or not (outdir / "stats.txt").exists():
                problems.append(f"{name} {latency}: gem5 exit {code}, program finished: {finished}. See {outdir / 'run.log'}")
                print("  FAILED. Last lines of the log:\n    " + "\n    ".join(log_text.splitlines()[-8:]))
                continue
            s = parse_stats(outdir / "stats.txt")
            acc = sc["accounting"]
            bus_r, bus_w = s.get("bus_ReadReq"), s.get("bus_WriteReq")
            if bus_r is None or bus_w is None:
                mmio_check = "bus statistic not found"
            else:
                mmio_check = "MATCH" if (bus_r == sc["expected_mmio_reads"] and bus_w == sc["expected_mmio_writes"]) else "MISMATCH"
            if mmio_check != "MATCH":
                problems.append(f"{name} {latency}: MMIO count check = {mmio_check} "
                                f"(bus {bus_r}/{bus_w}, expected {sc['expected_mmio_reads']}/{sc['expected_mmio_writes']})")
            row = dict(case=sc["case"], scenario=name, mmio_latency=latency, cpu_model=args.cpu,
                       kernel_dispatches=acc["kernel_dispatches"], programs=acc["programs"],
                       expected_mmio_reads=sc["expected_mmio_reads"], expected_mmio_writes=sc["expected_mmio_writes"],
                       gem5_bus_uncached_reads=bus_r, gem5_bus_uncached_writes=bus_w, mmio_count_check=mmio_check,
                       sim_seconds=s.get("simSeconds"), cpu_cycles=s.get("numCycles"), instructions=s.get("simInsts"),
                       ddr_read_requests=s.get("ddr_readReqs"), ddr_write_requests=s.get("ddr_writeReqs"),
                       ddr_bytes_read=s.get("ddr_bytesRead"), ddr_bytes_written=s.get("ddr_bytesWritten"),
                       ddr_avg_access_ticks=s.get("ddr_avgMemAccLat"), ddr_avg_queue_ticks=s.get("ddr_avgQLat"),
                       l1d_misses=s.get("l1d_misses"), l1d_accesses=s.get("l1d_accesses"), l1i_misses=s.get("l1i_misses"),
                       l2_misses=s.get("l2_misses"),
                       driver_sleep_seconds_not_simulated=acc["driver_sleep_seconds"],
                       gem5_host_seconds=s.get("hostSeconds"), basis=BASIS)
            rows.append(row)
            print(f"  simulated {row['sim_seconds']} s, {row['cpu_cycles']:.0f} cycles, MMIO check {mmio_check}")
    if rows:
        out = HERE.parent / "results" / "gem5_case_comparison.csv"
        with open(out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)
        print("\nwrote", out)
    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print("  " + p)
        sys.exit(1)
    print("All runs finished and every MMIO count matched the expected bus sequence.")


if __name__ == "__main__":
    main()
