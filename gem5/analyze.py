#!/usr/bin/env python3
"""
Produce every CSV in results/ from source replay and model accounting.

    python3 analyze.py                 # 200 signatures
    python3 analyze.py --signatures 50

Nothing written by this script is a measurement from AUP1. Each CSV carries a
`basis` column saying where its numbers come from.
"""

import argparse
import csv
import json
import statistics
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import chain_model as cm                      # noqa: E402
import workload as wl                         # noqa: E402
from wcore_model import CATEGORIES, DEVICE_NAMES, WcoreModel, load_backend   # noqa: E402

BASIS_REPLAY = "replay of unmodified handoff backend on register model (not AUP1)"
BASIS_FORMULA = "closed form validated against replay (not AUP1)"
BASIS_CHAIN = "MODEL-PREDICTED: proposed chaining, not implemented in RTL or on FPGA"
BASIS_DASC = "counted from wp_hw.py source; DMA-driver register traffic and timings not supplied"
KERNELS = ["ntt", "intt", "polymulacc", "shake256", "shake128"]


def write_csv(path, rows):
    with open(path, "w", newline="") as f:
        fields = list(dict.fromkeys(k for r in rows for k in r if k != "basis"))
        if any("basis" in r for r in rows):
            fields.append("basis")
        w = csv.DictWriter(f, fieldnames=fields, restval="")
        w.writeheader()
        w.writerows(rows)
    print(f"  wrote {path.relative_to(HERE)}  ({len(rows)} rows)")


def per_kernel_replay(out):
    """Replay the real backend once per kernel and compare with the closed form."""
    model = WcoreModel(kernels=wl.FUNCTIONAL_KERNELS)
    hw = load_backend(model)
    poly = [(7 * i + 3) % wl.Q for i in range(256)]
    cases = [("ntt", lambda: hw.do_ntt(poly)), ("intt", lambda: hw.do_intt(poly)),
             ("polymulacc", lambda: hw.do_polymul(poly, poly)),
             ("shake128 34B->256B", lambda: hw.do_shake128(bytes(34), 256)),
             ("shake128 34B->1024B", lambda: hw.do_shake128(bytes(34), 1024)),
             ("shake256 66B->576B", lambda: hw.do_shake256(bytes(66), 576)),
             ("shake256 832B->256B", lambda: hw.do_shake256(bytes(832), 256))]
    rows, traces = [], {}
    for label, call in cases:
        before, t0 = model.snapshot(), len(model.trace)
        call()
        d = WcoreModel.delta(before, model.snapshot())
        job = model.jobs[-1]
        formula = cm.account_stage8([job])
        row = dict(kernel_call=label, tx_words=job["tx_words"], rx_words=job["rx_words"],
                   software_calls=1, kernel_dispatches=d["kernel_dispatches"],
                   word_cmd_load=d["word_commands"]["scratch_load"], word_cmd_zero=d["word_commands"]["scratch_zero"],
                   word_cmd_read=d["word_commands"]["scratch_read"], word_cmd_scrub=d["word_commands"]["scratch_scrub"],
                   word_commands=d["word_commands_total"], mmio_reads=d["mmio_reads"], mmio_writes=d["mmio_writes"],
                   mmio_total=d["mmio_total"])
        for c in CATEGORIES:
            row[f"mmio_{c}"] = d["counts"][c]["R"] + d["counts"][c]["W"]
        row.update(driver_sleeps=d["driver_sleeps"], driver_sleep_seconds=d["driver_sleep_seconds"],
                   closed_form_word_commands=formula["word_commands"], closed_form_mmio_total=formula["mmio_total"],
                   closed_form_matches=(formula["word_commands"] == d["word_commands_total"]
                                        and formula["mmio_total"] == d["mmio_total"]),
                   basis=BASIS_REPLAY)
        rows.append(row)
        traces[label.split()[0]] = model.trace[t0:]
    hw.close()
    write_csv(out / "stage8_per_kernel_replay.csv", rows)
    for name in ("ntt", "polymulacc"):
        trace_rows = [dict(seq=i, kind=k, device=DEVICE_NAMES[b], address=f"0x{b + o:08X}", value=f"0x{v:08X}", category=c)
                      for i, (k, b, o, v, c) in enumerate(traces[name])]
        write_csv(out / f"stage8_trace_{name}.csv", trace_rows)
    (out / "stage8_traces.json").write_text(json.dumps(
        {name: [[k, b + o, v] for k, b, o, v, _ in tr] for name, tr in traces.items()}))
    return rows


def full_stack_validation(out, pk_sk_seed):
    """One signature with every MMIO access replayed: counts must equal the closed form."""
    model = WcoreModel(kernels=wl.FUNCTIONAL_KERNELS, keep_trace=False)
    hw = load_backend(model)
    w = wl.Workload(hw, model.jobs)
    (pk, sk), _, _ = w.keygen(pk_sk_seed)
    msg = b"RSCL validation message"
    before = model.snapshot()
    t0 = time.time()
    sig, jobs, iterations = w.sign(sk, msg)
    seconds = time.time() - t0
    d = WcoreModel.delta(before, model.snapshot())
    formula = cm.account_stage8(jobs)
    check = subprocess.run(
        [sys.executable, "-c",
         "import sys;from dilithium_py.ml_dsa import ML_DSA_44 as D;"
         "sys.exit(0 if D.verify(bytes.fromhex(sys.argv[1]),bytes.fromhex(sys.argv[2]),bytes.fromhex(sys.argv[3])) else 2)",
         pk.hex(), msg.hex(), sig.hex()])
    hw.close()
    result = dict(
        description="ML-DSA-44 sign: dilithium_py -> unmodified bridge -> unmodified Stage 8 backend -> register model",
        rejection_iterations=iterations, kernel_dispatches=d["kernel_dispatches"],
        replayed_word_commands=d["word_commands_total"], closed_form_word_commands=formula["word_commands"],
        replayed_mmio_total=d["mmio_total"], closed_form_mmio_total=formula["mmio_total"],
        replayed_driver_sleep_seconds=d["driver_sleep_seconds"], closed_form_driver_sleep_seconds=formula["driver_sleep_seconds"],
        counts_match=(d["word_commands_total"] == formula["word_commands"] and d["mmio_total"] == formula["mmio_total"]
                      and abs(d["driver_sleep_seconds"] - formula["driver_sleep_seconds"]) < 1e-9),
        signature_accepted_by_unpatched_library=check.returncode == 0,
        host_python_seconds_for_replay=round(seconds, 2), basis=BASIS_REPLAY)
    (out / "validation_full_stack.json").write_text(json.dumps(result, indent=1))
    print(f"  wrote results/validation_full_stack.json  (counts_match={result['counts_match']}, "
          f"signature_ok={result['signature_accepted_by_unpatched_library']})")
    return result


def case_rows(operation, stat, jobs_list, pick):
    """One row per case for a set of job logs, reduced with `pick` (mean, median, ...)."""
    def reduce(dicts, basis, case):
        keys = [k for k in dicts[0] if isinstance(dicts[0][k], (int, float))]
        row = dict(operation=operation, statistic=stat, case=case)
        row.update({k: round(pick([d[k] for d in dicts]), 3) for k in keys})
        row["basis"] = basis
        return row
    b = [cm.account_stage8(j) for j in jobs_list]
    c_cons = [cm.account_chain(j, read_policy="all") for j in jobs_list]
    c_opt = [cm.account_chain(j, read_policy="unconsumed") for j in jobs_list]
    return [reduce(b, BASIS_FORMULA, "B stage8 actual"),
            reduce(c_cons, BASIS_CHAIN, "C chain conservative (CPU reads all outputs)"),
            reduce(c_opt, BASIS_CHAIN, "C chain optimistic (CPU reads unconsumed outputs only)")]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--signatures", type=int, default=200)
    ap.add_argument("--out", default=str(HERE / "results"))
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    seed = bytes(range(32))

    print("1. Stage 8 per-kernel replay of the unmodified backend")
    per_kernel_replay(out)

    print("2. Full-stack validation (one signature, every MMIO access)")
    full_stack_validation(out, seed)

    print(f"3. ML-DSA-44 workload: key generation, {args.signatures} signatures, verification")
    hw = wl.CallLevelHW()
    w = wl.Workload(hw, hw.jobs)
    (pk, sk), key_jobs, _ = w.keygen(seed)
    sign_logs, per_sig, verify_logs = [], [], []
    for i in range(args.signatures):
        msg = b"RSCL workload message %d" % i
        sig, jobs, iterations = w.sign(sk, msg)
        ok, vjobs, _ = w.verify(pk, msg, sig)
        if not ok:
            raise SystemExit(f"signature {i} failed verification: stopping")
        sign_logs.append(jobs)
        verify_logs.append(vjobs)
        calls = Counter(j["name"] for j in jobs)
        b = cm.account_stage8(jobs)
        cc = cm.account_chain(jobs, read_policy="all")
        co = cm.account_chain(jobs, read_policy="unconsumed")
        a = cm.account_dasc(jobs)
        row = dict(signature=i, rejection_iterations=iterations, kernel_dispatches=len(jobs))
        row.update({f"calls_{k}": calls.get(k, 0) for k in KERNELS})
        row.update(cm.shake_regeneration(jobs))
        row.update(B_word_commands=b["word_commands"], B_mmio_total=b["mmio_total"],
                   B_driver_sleep_seconds=b["driver_sleep_seconds"],
                   C_cons_programs=cc["programs"], C_cons_word_commands=cc["word_commands"], C_cons_mmio_total=cc["mmio_total"],
                   C_opt_programs=co["programs"], C_opt_word_commands=co["word_commands"], C_opt_mmio_total=co["mmio_total"],
                   A_kernel_ip_mmio_writes=a["kernel_ip_mmio_writes"], A_dma_transfer_calls=a["dma_transfer_calls"],
                   A_bytes_by_dma=a["bytes_ddr_to_fabric_by_dma"] + a["bytes_fabric_to_ddr_by_dma"])
        per_sig.append(row)
    write_csv(out / "mldsa_per_signature.csv", per_sig)

    dist = Counter(r["rejection_iterations"] for r in per_sig)
    write_csv(out / "mldsa_rejection_distribution.csv",
              [dict(rejection_iterations=k, signatures=v, share=round(v / len(per_sig), 4),
                    basis="dilithium_py ML-DSA-44 deterministic signing, one fixed key") for k, v in sorted(dist.items())])

    def p95(v):
        s = sorted(v)
        return s[min(len(s) - 1, int(round(0.95 * (len(s) - 1))))]

    rows = case_rows("keygen", "single run", [key_jobs], lambda v: v[0])
    for stat, pick in (("mean", statistics.mean), ("median", statistics.median), ("p95", p95)):
        rows += case_rows("sign", stat, sign_logs, pick)
    rows += case_rows("verify", "mean", verify_logs, statistics.mean)
    write_csv(out / "case_comparison.csv", rows)

    a_rows = []
    for op, logs in (("keygen", [key_jobs]), ("sign", sign_logs), ("verify", verify_logs)):
        acc = [cm.account_dasc(j) for j in logs]
        row = dict(operation=op, statistic="mean", case="A DASC shared-DMA (structure only)")
        row.update({k: round(statistics.mean(d[k] for d in acc), 3) for k in acc[0]})
        row["basis"] = BASIS_DASC
        a_rows.append(row)
    write_csv(out / "case_A_dasc_structure.csv", a_rows)

    sens = []
    for slots in (4, 8, 16, 32, 64):
        for max_program in (1, 4, 16, 64):
            for policy in ("all", "unconsumed"):
                acc = [cm.account_chain(j, slots=slots, max_program=max_program, read_policy=policy) for j in sign_logs]
                row = dict(scratchpad_slots=slots, max_program_instructions=max_program, read_policy=policy)
                for k in ("programs", "word_commands", "mmio_total", "operands_reused", "fabric_to_fabric_edges",
                          "evictions", "driver_sleep_seconds"):
                    row[f"mean_{k}"] = round(statistics.mean(d[k] for d in acc), 3)
                row["basis"] = BASIS_CHAIN
                sens.append(row)
    write_csv(out / "chain_sensitivity.csv", sens)

    b_mean = statistics.mean(cm.account_stage8(j)["mmio_total"] for j in sign_logs)
    print(f"\nDone. Mean MMIO transactions per signature, Stage 8 as driven today: {b_mean:,.0f}")
    print("All files are in", out)


if __name__ == "__main__":
    main()
