#!/usr/bin/env python3
"""
ML-DSA-44 workload capture for the WEPWAWET-CORE transaction study.

The application stack is the real one:
    dilithium_py (ML-DSA-44)  ->  reference_from_handoff/stage8_mldsa_bridge.py (unmodified)
        ->  a hardware object with do_ntt / do_intt / do_polymul / do_shake128 / do_shake256

Two hardware objects are provided:
  CallLevelHW          records every kernel call (fast; used for many signatures)
  the Stage 8 backend  the unmodified handoff driver on the register model (slow; every MMIO access)

Both use the same functional kernel stand-ins, so signatures produced through
either path verify. The stand-ins satisfy the contract the bridge expects
(Montgomery-domain values in and out); they are software, not the HLS kernels.
"""

import hashlib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "reference_from_handoff"))

from dilithium_py.ml_dsa import ML_DSA_44                                   # noqa: E402
from dilithium_py.ml_dsa import ml_dsa as _ml_dsa_module                     # noqa: E402
from dilithium_py.polynomials.polynomials import Polynomial, PolynomialNTT   # noqa: E402

Q = 8380417
R_MONT = (1 << 32) % Q
R_INV = pow(R_MONT, -1, Q)
INTT_SCALE = 1          # stand-in value. The real scale comes from a passing hardware KAT.

ALL_KERNELS = ("ntt", "intt", "polymulacc", "shake128", "shake256")

# The library's own transforms, captured before the bridge replaces them.
_LIB_TO_NTT = Polynomial.to_ntt
_LIB_FROM_NTT = PolynomialNTT.from_ntt
_RING = ML_DSA_44.R


def pack_poly(coeffs):
    return [((int(coeffs[2 * i + 1]) & 0xFFFFFFFF) << 32) | (int(coeffs[2 * i]) & 0xFFFFFFFF) for i in range(128)]


def unpack_poly(words):
    out = []
    for w in words:
        for c in (w & 0xFFFFFFFF, (w >> 32) & 0xFFFFFFFF):
            out.append(c - (1 << 32) if c & (1 << 31) else c)
    return out


def _coeffs(words):
    return [c % Q for c in unpack_poly(words)]


def kernel_ntt(name, words, cfg):
    return pack_poly([c % Q for c in _LIB_TO_NTT(_RING(_coeffs(words))).coeffs])


def kernel_intt(name, words, cfg):
    poly = _RING(_coeffs(words), is_ntt=True)
    return pack_poly([(c * INTT_SCALE) % Q for c in _LIB_FROM_NTT(poly).coeffs])


def kernel_polymulacc(name, words, cfg):
    a, b = _coeffs(words[:128]), _coeffs(words[128:])
    return pack_poly([(x * y * R_INV) % Q for x, y in zip(a, b)])


def kernel_shake(name, words, cfg):
    msg = b"".join(w.to_bytes(8, "little") for w in words)[:cfg["msg_bytes"]]
    h = hashlib.shake_128(msg) if name == "shake128" else hashlib.shake_256(msg)
    raw = h.digest(cfg["out_bytes"]).ljust(8 * cfg["rx_words"], b"\0")
    return [int.from_bytes(raw[8 * i:8 * i + 8], "little") for i in range(cfg["rx_words"])]


FUNCTIONAL_KERNELS = {"ntt": kernel_ntt, "intt": kernel_intt, "polymulacc": kernel_polymulacc,
                      "shake128": kernel_shake, "shake256": kernel_shake}


class CallLevelHW:
    """Hardware stand-in at the call level: same results as the model, one log record per kernel call."""

    def __init__(self):
        self.jobs = []

    def _run(self, name, words, rx_words, msg_bytes=None, out_bytes=None):
        cfg = dict(tx_words=len(words), rx_words=rx_words, msg_bytes=msg_bytes, out_bytes=out_bytes)
        out = FUNCTIONAL_KERNELS[name](name, words, cfg)
        self.jobs.append(dict(name=name, tx_words=len(words), rx_words=rx_words, tx=tuple(words), rx=tuple(out),
                              msg_bytes=msg_bytes, out_bytes=out_bytes, functional=True))
        return out

    def do_ntt(self, poly):
        return unpack_poly(self._run("ntt", pack_poly(poly), 128))

    def do_intt(self, poly):
        return unpack_poly(self._run("intt", pack_poly(poly), 128))

    def do_polymul(self, a, b):
        return unpack_poly(self._run("polymulacc", pack_poly(a) + pack_poly(b), 128))

    def _shake(self, name, msg, out_bytes):
        msg = bytes(msg)
        words = [int.from_bytes(msg[8 * i:8 * i + 8].ljust(8, b"\0"), "little") for i in range((len(msg) + 7) // 8)]
        out = self._run(name, words, (out_bytes + 7) // 8, msg_bytes=len(msg), out_bytes=out_bytes)
        return b"".join(w.to_bytes(8, "little") for w in out)[:out_bytes]

    def do_shake128(self, msg, out_bytes):
        return self._shake("shake128", msg, out_bytes)

    def do_shake256(self, msg, out_bytes):
        return self._shake("shake256", msg, out_bytes)


_ITERATIONS = [0]
_original_expand_mask = _ml_dsa_module.ML_DSA._expand_mask_vector


def _counted_expand_mask(dsa, *args, **kwargs):
    """The library calls this once per signing attempt, so it counts rejection iterations."""
    _ITERATIONS[0] += 1
    return _original_expand_mask(dsa, *args, **kwargs)


_ml_dsa_module.ML_DSA._expand_mask_vector = _counted_expand_mask


class Workload:
    """Drives ML-DSA-44 through the unmodified bridge and splits the job log per operation."""

    def __init__(self, hw, job_log, shake_prefetch=256):
        from stage8_mldsa_bridge import WepwawetPqc
        self.hw, self.job_log = hw, job_log
        self.pqc = WepwawetPqc(hw, intt_scale=INTT_SCALE, shake_prefetch=shake_prefetch)
        # FINDING in the handoff bridge (reported, not edited): its constructor compares the
        # offload names ('ntt', ...) against the method names ('do_ntt', ...). With the default
        # it therefore patches nothing (pure software ML-DSA), and any explicit selection such as
        # ['ntt', 'intt', ...] raises ValueError. To exercise the intended behaviour we set the
        # kernel names and call the bridge's own, unmodified patch methods.
        self.bridge_default_patched_nothing = not any(k in self.pqc.enabled for k in ALL_KERNELS)
        self.pqc.enabled = frozenset(ALL_KERNELS)
        self.pqc._patch_shake()
        self.pqc._patch_polynomials()

    def _span(self, fn):
        start, _ITERATIONS[0] = len(self.job_log), 0
        result = fn()
        return result, self.job_log[start:], _ITERATIONS[0]

    def keygen(self, seed):
        return self._span(lambda: ML_DSA_44.key_derive(seed))

    def sign(self, sk, msg):
        return self._span(lambda: ML_DSA_44.sign(sk, msg, deterministic=True))

    def verify(self, pk, msg, sig):
        return self._span(lambda: bool(ML_DSA_44.verify(pk, msg, sig)))
