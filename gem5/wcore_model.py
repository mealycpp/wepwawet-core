#!/usr/bin/env python3
"""
Register-level model of the WEPWAWET-CORE Stage 8 software-visible interface,
plus a transaction recorder.

Purpose: run the UNMODIFIED Stage 8 Python backend from the handoff package
(reference_from_handoff/wcore_stage8_backend.py) against a model instead of a
board, and record every MMIO access it makes. Nothing here is measured on AUP1.

What is modelled, and where each fact comes from
  host scratchpad interface (0xA0040000)
      register map and status bits: rtl_export_baseline/wcore_host_mem_axi.v
      (ADDRESS/WRITE_LO/WRITE_HI/COMMAND/STATUS/READ_LO/READ_HI/ID)
  sequencer start/ack/status GPIO (0xA0030000) and descriptor GPIO (0xA0050000)
      bit meanings INFERRED from the checks the backend performs; the block
      design wiring is not in the handoff archive
  descriptor format: reference_from_handoff/wcore_stage8_descriptor.py
  SHAKE128 at 0x80050000, SHAKE256 at 0x80070000 (corrected map from the handoff)

What is NOT modelled: cycle timing of the fabric. The number of status polls
that see "busy" is a parameter (host_busy_polls, job_busy_polls), not a result.
"""

import hashlib
import importlib
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
REFERENCE = HERE / "reference_from_handoff"

HOST_BASE = 0xA0040000
SEQ_GPIO_BASE = 0xA0030000
DESC_GPIO_BASE = 0xA0050000
TRNG_BASE = 0xA0000000
SHAKE128_BASE = 0x80050000
SHAKE256_BASE = 0x80070000
DEVICE_NAMES = {
    HOST_BASE: "host", SEQ_GPIO_BASE: "seq_gpio", DESC_GPIO_BASE: "desc_gpio",
    SHAKE128_BASE: "shake128_cfg", SHAKE256_BASE: "shake256_cfg", TRNG_BASE: "trng",
}
HOST_ID = 0x57434F52
BANKS, BANK_WORDS = 4, 2048
LANES = {0: "ntt", 1: "intt", 2: "polymulacc", 3: "shake256", 4: "shake128"}
POLY_LENGTHS = {"ntt": (128, 128), "intt": (128, 128), "polymulacc": (256, 128)}
MODEL_BITFILE = "/model/wepwawet_stage8_MODEL_NOT_A_BITSTREAM.bit"

# Transaction categories. Every recorded MMIO access gets exactly one.
CATEGORIES = [
    "scratch_load",      # host interface: writing kernel input words to bank 0
    "scratch_zero",      # host interface: zero-initialising output words in bank 1 before start
    "scratch_read",      # host interface: reading kernel output words from bank 1
    "scratch_scrub",     # host interface: zeroing input and output words after the job
    "host_check",        # host status/ID reads that are not part of a word command
    "descriptor",        # descriptor GPIO writes and readbacks
    "start_ack",         # sequencer GPIO writes: start pulse, ack pulse, pulse clears
    "seq_status",        # sequencer GPIO status reads (idle checks and completion polls)
    "kernel_cfg",        # SHAKE length registers
]


class ModelError(Exception):
    pass


def _placeholder_kernel(name, words, cfg):
    """Deterministic, NON-FUNCTIONAL output used when no functional kernel is supplied."""
    out_words = cfg["rx_words"]
    seed = hashlib.shake_256(name.encode() + b"|" + b"".join(w.to_bytes(8, "little") for w in words))
    raw = seed.digest(8 * out_words)
    return [int.from_bytes(raw[8 * i:8 * i + 8], "little") for i in range(out_words)]


def _shake_kernel(name, words, cfg):
    """Functionally correct SHAKE128/256 over the first msg_bytes of the input words."""
    msg = b"".join(w.to_bytes(8, "little") for w in words)[:cfg["msg_bytes"]]
    h = hashlib.shake_128(msg) if name == "shake128" else hashlib.shake_256(msg)
    raw = h.digest(cfg["out_bytes"]).ljust(8 * cfg["rx_words"], b"\0")
    return [int.from_bytes(raw[8 * i:8 * i + 8], "little") for i in range(cfg["rx_words"])]


class WcoreModel:
    """The devices behind the Stage 8 address map, with a transaction trace."""

    def __init__(self, kernels=None, host_busy_polls=0, job_busy_polls=0, keep_trace=True):
        self.kernels = {"shake128": _shake_kernel, "shake256": _shake_kernel}
        self.kernels.update(kernels or {})
        self.host_busy_polls = host_busy_polls
        self.job_busy_polls = job_busy_polls
        self.keep_trace = keep_trace
        self.scratch = [[0] * BANK_WORDS for _ in range(BANKS)]
        self.trace = []                    # (kind, base, offset, value, category)
        self.counts = {c: {"R": 0, "W": 0} for c in CATEGORIES}
        self.word_commands = {"scratch_load": 0, "scratch_zero": 0, "scratch_read": 0, "scratch_scrub": 0}
        self.jobs = []                     # one record per completed kernel dispatch
        self.rejected_starts = []
        self.sleeps = []                   # seconds requested by the driver via time.sleep
        # host interface
        self.h_addr = self.h_wlo = self.h_whi = 0
        self.h_read = 0
        self.h_done = self.h_error = False
        self.h_code = 0
        self.h_busy_left = 0
        self.h_pending = None              # command waiting behind busy polls
        self._last_cmd = 0
        self._group = None                 # indices of trace entries of the open word command
        self._group_cat = None
        # sequencer
        self.seq_state = "idle"            # idle | busy | done | error
        self.seq_status_word = 0
        self.seq_busy_left = 0
        self.seq_gpio_out = 0
        self.job_acked = True              # False between job completion and ack: scratch reads are post-job
        self.post_job = False
        self.desc = [0, 0]
        self.shake_cfg = {SHAKE128_BASE: {}, SHAKE256_BASE: {}}

    # ---- recording -----------------------------------------------------------
    def _record(self, kind, base, off, value, cat):
        self.counts[cat][kind] += 1
        if self.keep_trace:
            self.trace.append((kind, base, off, value, cat))
            return (len(self.trace) - 1, kind, cat)
        return (None, kind, cat)

    def _retag(self, entries, cat):
        for i, kind, old in entries:
            self.counts[old][kind] -= 1
            self.counts[cat][kind] += 1
            if i is not None:
                k, base, off, value, _ = self.trace[i]
                self.trace[i] = (k, base, off, value, cat)

    # ---- host scratchpad interface -------------------------------------------
    def host_eligible(self):
        return self.seq_state == "idle"

    def _host_status(self):
        busy = self.h_pending is not None
        return (0x7F10 << 16) | (self.h_code << 8) | (int(self.host_eligible()) << 4) | (1 << 3) | \
               (int(self.h_error) << 2) | (int(self.h_done) << 1) | int(busy)

    def _host_finish(self):
        cmd, bank, idx = self.h_pending
        self.h_pending = None
        if cmd == 1:
            self.scratch[bank][idx] = (self.h_whi << 32) | self.h_wlo
        else:
            self.h_read = self.scratch[bank][idx]
        self.h_done = True

    def _host_write(self, off, value):
        value &= 0xFFFFFFFF
        if off == 0x00:
            self._group = [self._record("W", HOST_BASE, off, value, "host_check")]
            self._group_cat = None
            self.h_addr = value & 0x1FFF
            return
        cat = self._group_cat or "host_check"
        idx = self._record("W", HOST_BASE, off, value, cat)
        if self._group is not None and self._group_cat is None:
            self._group.append(idx)
        if off == 0x04:
            self.h_wlo = value
        elif off == 0x08:
            self.h_whi = value
        elif off == 0x0C:
            self.h_done = self.h_error = False
            self.h_code = 0
            bank, word = (self.h_addr >> 11) & 3, self.h_addr & 0x7FF
            if not self.host_eligible():
                self.h_done = self.h_error = True
                self.h_code = 0x02
            elif value not in (1, 2):
                self.h_done = self.h_error = True
                self.h_code = 0x03
            else:
                if value == 2:
                    cat = "scratch_read"
                elif self.post_job:
                    cat = "scratch_scrub"
                else:
                    cat = "scratch_load" if bank == 0 else "scratch_zero"
                self.word_commands[cat] += 1
                if self._group is not None:
                    self._retag(self._group, cat)
                    self._group_cat = cat
                self._last_cmd = value
                self.h_pending = (value, bank, word)
                self.h_busy_left = self.host_busy_polls
        else:
            raise ModelError(f"host write to unmapped offset 0x{off:02X} (RTL answers SLVERR)")

    def _host_read(self, off):
        cat = self._group_cat or "host_check"
        if off == 0x10:
            if self.h_pending is not None:
                if self.h_busy_left > 0:
                    self.h_busy_left -= 1
                else:
                    self._host_finish()
            value = self._host_status()
        elif off == 0x14:
            value = self.h_read & 0xFFFFFFFF
        elif off == 0x18:
            value = self.h_read >> 32
        elif off == 0x1C:
            value = HOST_ID
        elif off == 0x00:
            value = self.h_addr
        elif off == 0x04:
            value = self.h_wlo
        elif off == 0x08:
            value = self.h_whi
        elif off == 0x0C:
            value = 0
        else:
            raise ModelError(f"host read of unmapped offset 0x{off:02X} (RTL answers SLVERR)")
        idx = self._record("R", HOST_BASE, off, value, cat)
        if self._group is not None and self._group_cat is None:
            self._group.append(idx)
        # A word command ends at its done poll (write) or at the READ_HI read (read).
        if self._group_cat is not None and self.h_pending is None:
            if (off == 0x10 and self._last_cmd == 1 and self.h_done) or off == 0x18:
                self._group = self._group_cat = None
        return value

    # ---- sequencer and descriptor ---------------------------------------------
    def _decode_descriptor(self):
        word = (self.desc[1] << 32) | self.desc[0]
        d = dict(op=(word >> 60) & 0xF, lane=(word >> 57) & 0x7, tx_bank=(word >> 55) & 0x3,
                 rx_bank=(word >> 53) & 0x3, tx_addr=(word >> 42) & 0x7FF, rx_addr=(word >> 31) & 0x7FF,
                 tx_words=(word >> 19) & 0xFFF, rx_words=(word >> 7) & 0xFFF, cfg_index=word & 0x7F)
        return word, d

    def validate_descriptor(self, d):
        """Gates from the handoff: lane, bank, length and polynomial-size checks."""
        if d["op"] != 0:
            return "opcode is not a kernel dispatch"
        if d["lane"] not in LANES:
            return "invalid lane"
        if d["cfg_index"] != d["lane"]:
            return "config index does not match lane"
        if (d["tx_bank"], d["rx_bank"]) != (0, 1):
            return "Stage 8 allows input bank 0 and output bank 1 only"
        if (d["tx_addr"], d["rx_addr"]) != (0, 0):
            return "Stage 8 allows offset 0 only"
        if not (1 <= d["tx_words"] <= BANK_WORDS and 1 <= d["rx_words"] <= BANK_WORDS):
            return "illegal transfer length"
        name = LANES[d["lane"]]
        if name in POLY_LENGTHS and (d["tx_words"], d["rx_words"]) != POLY_LENGTHS[name]:
            return "polynomial kernel length mismatch"
        return None

    def _start_job(self):
        if self.seq_state != "idle":
            self.rejected_starts.append("start while a job is in flight")
            return
        word, d = self._decode_descriptor()
        problem = self.validate_descriptor(d)
        if problem:
            self.rejected_starts.append(problem)
            self.seq_state, self.seq_status_word = "error", 0x04
            return
        name = LANES[d["lane"]]
        tx = self.scratch[0][:d["tx_words"]]
        cfg = dict(rx_words=d["rx_words"], tx_words=d["tx_words"])
        if name.startswith("shake"):
            regs = self.shake_cfg[SHAKE128_BASE if name == "shake128" else SHAKE256_BASE]
            cfg["msg_bytes"], cfg["out_bytes"] = regs.get(0x10, 0), regs.get(0x18, 0)
            if not (0 < cfg["msg_bytes"] <= 8 * d["tx_words"] and 0 < cfg["out_bytes"] <= 8 * d["rx_words"]):
                self.rejected_starts.append("SHAKE byte lengths inconsistent with descriptor word counts")
                self.seq_state, self.seq_status_word = "error", 0x04
                return
        out = self.kernels.get(name, _placeholder_kernel)(name, list(tx), cfg)
        if len(out) != d["rx_words"]:
            raise ModelError(f"kernel model for {name} returned {len(out)} words, expected {d['rx_words']}")
        for i, w in enumerate(out):
            self.scratch[1][i] = w & 0xFFFFFFFFFFFFFFFF
        self.jobs.append(dict(name=name, tx_words=d["tx_words"], rx_words=d["rx_words"], descriptor=word,
                              tx=tuple(tx), rx=tuple(self.scratch[1][:d["rx_words"]]),
                              msg_bytes=cfg.get("msg_bytes"), out_bytes=cfg.get("out_bytes"),
                              functional=name in self.kernels))
        self.seq_state = "busy"
        self.seq_busy_left = self.job_busy_polls
        self._done_word = 0x02 | 0x60 | ((d["tx_words"] & 255) << 8) | ((d["rx_words"] & 255) << 16)

    def _seq_write(self, off, value):
        self._group = None
        self._record("W", SEQ_GPIO_BASE, off, value, "start_ack")
        if off != 0:
            return
        rising = value & ~self.seq_gpio_out
        self.seq_gpio_out = value
        if rising & 1:
            self.post_job = False
            self._start_job()
        if rising & 2:                       # ack: done or error returns to idle
            if self.seq_state in ("done", "error"):
                self.post_job = self.seq_state == "done"
                self.seq_state = "idle"

    def _seq_read(self, off):
        self._group = None
        if off != 8:
            value = self.seq_gpio_out
        else:
            if self.seq_state == "busy":
                if self.seq_busy_left > 0:
                    self.seq_busy_left -= 1
                else:
                    self.seq_state, self.seq_status_word = "done", self._done_word
            value = {"idle": 0x10, "busy": 0x01}.get(self.seq_state, self.seq_status_word)
        self._record("R", SEQ_GPIO_BASE, off, value, "seq_status")
        return value

    # ---- bus entry points ------------------------------------------------------
    def write(self, base, off, value):
        if base == HOST_BASE:
            return self._host_write(off, value)
        if base == SEQ_GPIO_BASE:
            return self._seq_write(off, value)
        self._group = None
        if base == DESC_GPIO_BASE:
            self._record("W", base, off, value, "descriptor")
            self.post_job = False            # the driver clears the descriptor after its scrub
            if off in (0, 8):
                self.desc[off // 8] = value & 0xFFFFFFFF
            return
        if base in self.shake_cfg:
            self._record("W", base, off, value, "kernel_cfg")
            self.shake_cfg[base][off] = value
            return
        raise ModelError(f"write to unmodelled device 0x{base:08X}")

    def read(self, base, off):
        if base == HOST_BASE:
            return self._host_read(off)
        if base == SEQ_GPIO_BASE:
            return self._seq_read(off)
        self._group = None
        if base == DESC_GPIO_BASE:
            value = self.desc[off // 8] if off in (0, 8) else 0
            self._record("R", base, off, value, "descriptor")
            return value
        if base in self.shake_cfg:
            value = self.shake_cfg[base].get(off, 0)
            self._record("R", base, off, value, "kernel_cfg")
            return value
        raise ModelError(f"read of unmodelled device 0x{base:08X}")

    # ---- summaries ---------------------------------------------------------------
    def totals(self):
        reads = sum(c["R"] for c in self.counts.values())
        writes = sum(c["W"] for c in self.counts.values())
        return dict(mmio_reads=reads, mmio_writes=writes, mmio_total=reads + writes,
                    word_commands=sum(self.word_commands.values()), kernel_dispatches=len(self.jobs),
                    driver_sleeps=len(self.sleeps), driver_sleep_seconds=round(sum(self.sleeps), 6))

    def snapshot(self):
        return dict(counts={c: dict(v) for c, v in self.counts.items()}, word_commands=dict(self.word_commands),
                    jobs=len(self.jobs), sleeps=len(self.sleeps), sleep_s=sum(self.sleeps), trace=len(self.trace))

    @staticmethod
    def delta(before, after):
        d = dict(counts={c: {k: after["counts"][c][k] - before["counts"][c][k] for k in "RW"} for c in CATEGORIES},
                 word_commands={k: after["word_commands"][k] - before["word_commands"][k] for k in after["word_commands"]},
                 kernel_dispatches=after["jobs"] - before["jobs"], driver_sleeps=after["sleeps"] - before["sleeps"],
                 driver_sleep_seconds=round(after["sleep_s"] - before["sleep_s"], 6))
        d["mmio_reads"] = sum(v["R"] for v in d["counts"].values())
        d["mmio_writes"] = sum(v["W"] for v in d["counts"].values())
        d["mmio_total"] = d["mmio_reads"] + d["mmio_writes"]
        d["word_commands_total"] = sum(d["word_commands"].values())
        return d


# ---- running the unmodified handoff backend against the model -------------------
class _Clock:
    """Stand-in for the time module inside the backend: sleeps are recorded, not slept."""

    def __init__(self, model, tick):
        self.model, self.now, self.tick = model, 0.0, tick

    def sleep(self, seconds):
        self.model.sleeps.append(seconds)
        self.now += seconds

    def monotonic(self):
        self.now += self.tick          # lets the driver's watchdog deadlines expire in tests
        return self.now


def load_backend(model, watchdog_tick_s=1e-6, shake_registers_verified=True):
    """Import reference_from_handoff/wcore_stage8_backend.py unchanged and bind it to `model`.

    Returns a WcoreStage8 instance whose MMIO accesses all go to the model.
    """
    class MMIO:
        def __init__(self, base, length=0x1000):
            if base not in DEVICE_NAMES:
                raise ModelError(f"driver mapped an unmodelled base 0x{base:08X}")
            self.base = base

        def read(self, off=0):
            return model.read(self.base, off)

        def write(self, off, value):
            model.write(self.base, off, value)

    pynq = types.ModuleType("pynq")
    pynq.MMIO = MMIO
    pynq.PL = types.SimpleNamespace(
        bitfile_name=MODEL_BITFILE,
        ip_dict={"wcore_host_mem_axi_0": {"phys_addr": HOST_BASE},
                 "wcore_ntt_gpio_0": {"phys_addr": SEQ_GPIO_BASE},
                 "wcore_job_desc_gpio_0": {"phys_addr": DESC_GPIO_BASE}})
    sys.modules["pynq"] = pynq
    if str(REFERENCE) not in sys.path:
        sys.path.insert(0, str(REFERENCE))
    backend = importlib.import_module("wcore_stage8_backend")
    backend.time = _Clock(model, watchdog_tick_s)
    return backend.WcoreStage8(MODEL_BITFILE, confirm_candidate=True,
                               shake_registers_verified=shake_registers_verified)
