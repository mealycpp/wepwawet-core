"""The C replay used in gem5 must issue the recorded bus sequence."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


@pytest.mark.skipif(shutil.which("gcc") is None, reason="needs a host C compiler")
def test_c_replay_matches_recorded_bus_sequence():
    run = subprocess.run([sys.executable, str(ROOT / "gem5" / "gen_scenarios.py")], capture_output=True, text=True)
    assert run.returncode == 0, run.stdout + run.stderr
    meta = json.loads((ROOT / "gem5" / "build" / "scenarios.json").read_text())
    b = meta["scenarios"]["sign_stage8"]
    assert b["host_check_passed"]
    assert b["expected_mmio_reads"] + b["expected_mmio_writes"] == b["accounting"]["mmio_total"]
    for name in ("sign_chain_cons", "sign_chain_opt"):
        c = meta["scenarios"][name]
        assert c["host_check_passed"]
        assert c["expected_mmio_reads"] + c["expected_mmio_writes"] == c["accounting"]["mmio_total"] < b["accounting"]["mmio_total"]
