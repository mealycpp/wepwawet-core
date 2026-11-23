"""The unmodified handoff backend, replayed on the register model."""
import hashlib
from pathlib import Path

import pytest

import chain_model as cm
import wcore_model as wm
from wcore_model import WcoreModel, load_backend

ROOT = Path(__file__).resolve().parent.parent
POLY = [(5 * i + 1) % 8380417 for i in range(256)]


@pytest.fixture
def rig():
    made = []

    def make(**kw):
        model = WcoreModel(**kw)
        hw = load_backend(model)
        made.append(hw)
        return model, hw

    yield make
    for hw in made:
        hw.close()


def run(model, fn):
    before = model.snapshot()
    fn()
    return WcoreModel.delta(before, model.snapshot())


def test_reference_files_are_the_handoff_files():
    sums = {}
    for line in (ROOT / "reference_from_handoff" / "SHA256SUMS.txt").read_text().splitlines():
        digest, name = line.split(None, 1)
        sums[Path(name.strip()).name] = digest
    for name in ("wcore_stage8_backend.py", "wcore_stage8_descriptor.py", "stage8_mldsa_bridge.py", "wp_hw.py"):
        got = hashlib.sha256((ROOT / "reference_from_handoff" / name).read_bytes()).hexdigest()
        assert got == sums[name], f"{name} differs from the handoff package"


@pytest.mark.parametrize("call,commands,mmio", [("ntt", 640, 3856), ("intt", 640, 3856), ("polymulacc", 896, 5392)])
def test_word_commands_per_invocation(rig, call, commands, mmio):
    model, hw = rig()
    fn = {"ntt": lambda: hw.do_ntt(POLY), "intt": lambda: hw.do_intt(POLY),
          "polymulacc": lambda: hw.do_polymul(POLY, POLY)}[call]
    d = run(model, fn)
    assert d["word_commands_total"] == commands          # the handoff's expected 640 / 640 / 896
    assert d["mmio_total"] == mmio
    assert d["kernel_dispatches"] == 1
    assert d["driver_sleeps"] == 2 and d["driver_sleep_seconds"] == pytest.approx(0.004)


def test_write_word_and_read_word_bus_sequences(rig):
    model, hw = rig()
    start = len(model.trace)
    hw._write_word(0, 5, 0x1122334455667788)
    seq = [(k, o) for k, b, o, v, c in model.trace[start:]]
    assert seq == [("W", 0x00), ("W", 0x04), ("W", 0x08), ("R", 0x10), ("W", 0x0C), ("R", 0x10)]
    assert model.scratch[0][5] == 0x1122334455667788
    start = len(model.trace)
    assert hw._read_word(0, 5) == 0x1122334455667788
    seq = [(k, o) for k, b, o, v, c in model.trace[start:]]
    assert seq == [("W", 0x00), ("R", 0x10), ("W", 0x0C), ("R", 0x10), ("R", 0x14), ("R", 0x18)]


@pytest.mark.parametrize("host_polls,job_polls", [(0, 0), (2, 0), (0, 3), (1, 2)])
def test_closed_form_equals_replay(rig, host_polls, job_polls):
    model, hw = rig(host_busy_polls=host_polls, job_busy_polls=job_polls)
    calls = [lambda: hw.do_ntt(POLY), lambda: hw.do_intt(POLY), lambda: hw.do_polymul(POLY, POLY),
             lambda: hw.do_shake128(bytes(34), 1024), lambda: hw.do_shake256(bytes(66), 576),
             lambda: hw.do_shake256(b"x", 1)]
    for fn in calls:
        n = len(model.jobs)
        d = run(model, fn)
        f = cm.account_stage8(model.jobs[n:], host_busy_polls=host_polls, job_busy_polls=job_polls)
        assert f["word_commands"] == d["word_commands_total"]
        assert f["mmio_total"] == d["mmio_total"]
        assert f["driver_sleeps"] == d["driver_sleeps"]
        assert f["driver_sleep_seconds"] == pytest.approx(d["driver_sleep_seconds"])
        for key, cat in (("word_cmd_load", "scratch_load"), ("word_cmd_zero", "scratch_zero"),
                         ("word_cmd_read", "scratch_read"), ("word_cmd_scrub", "scratch_scrub")):
            assert f[key] == d["word_commands"][cat]


def test_shake_uses_corrected_address_map(rig):
    model, hw = rig()
    hw.do_shake128(b"abc", 32)
    hw.do_shake256(b"abc", 64)
    assert model.shake_cfg[0x80050000] == {0x10: 3, 0x18: 32}      # SHAKE128
    assert model.shake_cfg[0x80070000] == {0x10: 3, 0x18: 64}      # SHAKE256
    assert hw.do_shake256(b"abc", 32) == hashlib.shake_256(b"abc").digest(32)
    assert hw.do_shake128(b"abc", 32) == hashlib.shake_128(b"abc").digest(32)


def test_scratchpad_is_scrubbed_after_a_job(rig):
    model, hw = rig()
    hw.do_polymul(POLY, POLY)
    assert not any(model.scratch[0][:256]) and not any(model.scratch[1][:128])


# ---- gates -----------------------------------------------------------------
def start_with_descriptor(model, word):
    model.write(wm.DESC_GPIO_BASE, 0, word & 0xFFFFFFFF)
    model.write(wm.DESC_GPIO_BASE, 8, word >> 32)
    model.write(wm.SEQ_GPIO_BASE, 0, 1)
    model.write(wm.SEQ_GPIO_BASE, 0, 0)
    return model.read(wm.SEQ_GPIO_BASE, 8)


def desc(lane, tx, rx, cfg=None, rx_bank=1, tx_bank=0, op=0):
    cfg = lane if cfg is None else cfg
    return (op << 60) | (lane << 57) | (tx_bank << 55) | (rx_bank << 53) | (tx << 19) | (rx << 7) | cfg


@pytest.mark.parametrize("word,reason", [
    (desc(5, 128, 128), "invalid lane"),
    (desc(7, 128, 128), "invalid lane"),
    (desc(0, 128, 128, cfg=1), "config index"),
    (desc(0, 128, 128, rx_bank=2), "bank"),
    (desc(0, 128, 128, tx_bank=1), "bank"),
    (desc(0, 0, 128), "length"),
    (desc(0, 127, 128), "polynomial"),
    (desc(1, 128, 64), "polynomial"),
    (desc(2, 128, 128), "polynomial"),
    (desc(0, 128, 128, op=7), "opcode"),
])
def test_invalid_descriptors_are_rejected(word, reason):
    model = WcoreModel()
    status = start_with_descriptor(model, word)
    assert status & 0x04 and not status & 0x02
    assert reason in model.rejected_starts[-1]
    assert model.jobs == []


def test_polynomial_lengths_accepted():
    for lane, tx, rx in ((0, 128, 128), (1, 128, 128), (2, 256, 128)):
        model = WcoreModel()
        status = start_with_descriptor(model, desc(lane, tx, rx))
        assert status & 0x02 and (status & 0x60) == 0x60
        assert (status >> 8) & 255 == tx & 255 and (status >> 16) & 255 == rx


def test_one_job_in_flight_and_host_locked_until_ack():
    model = WcoreModel(job_busy_polls=5)
    start_with_descriptor(model, desc(0, 128, 128))
    model.write(wm.SEQ_GPIO_BASE, 0, 1)                      # second start while busy
    assert "in flight" in model.rejected_starts[-1] and len(model.jobs) == 1
    model.write(wm.HOST_BASE, 0x00, 0)
    model.write(wm.HOST_BASE, 0x0C, 1)                       # host command while the job is unacknowledged
    status = model.read(wm.HOST_BASE, 0x10)
    assert status & 0x04 and (status >> 8) & 255 == 0x02     # RTL error code 2: not eligible


def test_backend_fails_closed_then_recovers(rig):
    model, hw = rig()
    good = hw.do_ntt(POLY)
    model.kernels["ntt"] = lambda n, w, c: [0] * 7           # kernel model returns the wrong length
    with pytest.raises(wm.ModelError):
        hw.do_ntt(POLY)
    del model.kernels["ntt"]
    assert hw.do_ntt(POLY) == good                           # the next job runs normally


def test_backend_times_out_without_retry(rig):
    model, hw = rig(job_busy_polls=10 ** 9)
    with pytest.raises(TimeoutError):
        hw.do_ntt(POLY)
    assert len(model.jobs) == 1                              # dispatched once, never retried
