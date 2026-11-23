"""Chaining model invariants and the ML-DSA-44 workload capture."""
import subprocess
import sys
from collections import Counter

import pytest

import chain_model as cm
import workload as wl

SEED = bytes(range(32))


@pytest.fixture(scope="module")
def captured():
    hw = wl.CallLevelHW()
    w = wl.Workload(hw, hw.jobs)
    (pk, sk), key_jobs, _ = w.keygen(SEED)
    signs = []
    for i in range(12):
        msg = b"RSCL test message %d" % i
        sig, jobs, iterations = w.sign(sk, msg)
        signs.append((msg, sig, jobs, iterations))
    ok, verify_jobs, _ = w.verify(pk, signs[0][0], signs[0][1])
    return dict(w=w, pk=pk, key_jobs=key_jobs, signs=signs, verify_ok=ok, verify_jobs=verify_jobs)


def test_handoff_bridge_default_offloads_nothing(captured):
    # Documented finding: the bridge compares 'ntt' against 'do_ntt', so its default patches nothing.
    assert captured["w"].bridge_default_patched_nothing


def test_signatures_verify_with_an_unpatched_library(captured):
    assert captured["verify_ok"]
    code = ("import sys;from dilithium_py.ml_dsa import ML_DSA_44 as D;"
            "sys.exit(0 if D.verify(bytes.fromhex(sys.argv[1]),bytes.fromhex(sys.argv[2]),bytes.fromhex(sys.argv[3])) else 2)")
    for msg, sig, _, _ in captured["signs"][:4]:
        assert subprocess.run([sys.executable, "-c", code, captured["pk"].hex(), msg.hex(), sig.hex()]).returncode == 0


def test_call_counts_follow_rejection_iterations(captured):
    for _, _, jobs, iterations in captured["signs"]:
        calls = Counter(j["name"] for j in jobs)
        assert iterations >= 1
        assert calls["ntt"] == 12 + 5 * iterations          # s1, s2, t0 once; y (4) and c (1) per attempt
        assert calls["shake128"] == 48                      # 16 matrix entries, each regenerated at 256/512/1024 bytes
        assert 16 * iterations <= calls["polymulacc"] <= 28 * iterations
    assert {i for *_, i in captured["signs"]} != {1}        # the sample contains rejected attempts


def test_lengths_recorded_for_every_job(captured):
    for _, _, jobs, _ in captured["signs"]:
        for j in jobs:
            if j["name"] in ("ntt", "intt"):
                assert (j["tx_words"], j["rx_words"]) == (128, 128)
            elif j["name"] == "polymulacc":
                assert (j["tx_words"], j["rx_words"]) == (256, 128)
            else:
                assert j["tx_words"] == (j["msg_bytes"] + 7) // 8 and j["rx_words"] == (j["out_bytes"] + 7) // 8


def test_chain_never_exceeds_stage8_and_keeps_dispatch_count(captured):
    for _, _, jobs, _ in captured["signs"]:
        b = cm.account_stage8(jobs)
        for policy in ("all", "unconsumed"):
            c = cm.account_chain(jobs, read_policy=policy)
            assert c["kernel_dispatches"] == b["kernel_dispatches"] == len(jobs)
            assert c["word_commands"] <= b["word_commands"] and c["mmio_total"] <= b["mmio_total"]
            assert c["programs"] <= b["programs"]
            assert c["word_cmd_zero"] == 0 and c["word_cmd_scrub"] == 0
        assert cm.account_chain(jobs, read_policy="unconsumed")["word_cmd_read"] <= \
               cm.account_chain(jobs, read_policy="all")["word_cmd_read"] == b["word_cmd_read"]


def test_every_operand_has_a_source(captured):
    # account_chain raises GhostTransfer if an instruction consumes data nobody loaded or produced.
    for _, _, jobs, _ in captured["signs"]:
        plan = []
        c = cm.account_chain(jobs, slots=4, plan=plan)
        assert len(plan) == len(jobs) and plan[0]["new_program"]
        assert sum(p["load_words"] for p in plan) == c["word_cmd_load"]
        assert sum(p["read_words"] for p in plan) == c["word_cmd_read"]
        assert sum(p["new_program"] for p in plan) == c["programs"]
        assert all(p["new_program"] for p in plan if p["load_words"])   # data from the CPU starts a program


def test_program_length_one_gives_one_program_per_job(captured):
    jobs = captured["signs"][0][2]
    assert cm.account_chain(jobs, max_program=1)["programs"] == len(jobs)


def test_small_scratchpad_costs_more_loads(captured):
    jobs = captured["signs"][0][2]
    small, large = cm.account_chain(jobs, slots=4), cm.account_chain(jobs, slots=64)
    assert small["word_cmd_load"] >= large["word_cmd_load"]
    assert small["evictions"] >= large["evictions"]
    with pytest.raises(ValueError):
        cm.account_chain(jobs, slots=2)                     # PolyMulAcc needs two operands and an output


def test_failed_job_flushes_scratchpad_and_is_redone(captured):
    jobs = captured["signs"][0][2]
    clean = cm.account_chain(jobs)
    faulty = cm.account_chain(jobs, failed_jobs=[len(jobs) // 2])
    assert faulty["recoveries"] == 1
    assert faulty["kernel_dispatches"] == clean["kernel_dispatches"]
    assert faulty["word_cmd_load"] > clean["word_cmd_load"]


def test_synthetic_chain_ntt_ntt_mul_intt():
    a, b = tuple(range(1, 129)), tuple(range(201, 329))
    na, nb, prod, res = tuple(range(1000, 1128)), tuple(range(2000, 2128)), tuple(range(3000, 3128)), tuple(range(4000, 4128))
    jobs = [dict(name="ntt", tx_words=128, rx_words=128, tx=a, rx=na),
            dict(name="ntt", tx_words=128, rx_words=128, tx=b, rx=nb),
            dict(name="polymulacc", tx_words=256, rx_words=128, tx=na + nb, rx=prod),
            dict(name="intt", tx_words=128, rx_words=128, tx=prod, rx=res)]
    stage8 = cm.account_stage8(jobs)
    assert stage8["word_commands"] == 640 + 640 + 896 + 640
    chain = cm.account_chain(jobs, read_policy="unconsumed")
    assert chain["word_cmd_load"] == 256                    # only a and b come from the CPU
    assert chain["word_cmd_read"] == 128                    # only the final result goes back
    assert chain["fabric_to_fabric_edges"] == 3             # NTT(a), NTT(b) -> PolyMulAcc -> INTT
    assert chain["programs"] == 2                           # b is loaded after the first NTT was issued
    assert cm.account_chain(jobs, read_policy="all")["word_cmd_read"] == 4 * 128


def test_shake_regeneration_accounting(captured):
    jobs = captured["signs"][0][2]
    r = cm.shake_regeneration(jobs)
    assert r["shake_bytes_produced"] == r["shake_bytes_if_incremental"] + r["shake_bytes_regenerated"]
    assert r["shake_bytes_regenerated"] >= 16 * (256 + 512)  # each matrix stream is produced three times
