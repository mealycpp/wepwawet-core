"""
wp_hw.py - Wepwawet hardware orchestration

Wraps the 5-lane FPGA accelerator stack on AUP-ZU3:
    Lane 0: NTT
    Lane 1: INTT
    Lane 2: PolyMulAcc (pointwise multiply, Montgomery domain)
    Lane 3: SHAKE-256
    Lane 4: SHAKE-128

Plus AXI-Lite TRNG on a separate address space.

All AXIS data flows through one shared AXI DMA, gated by a runtime
distributor/collector pair (single-DMA Amdahl model).
"""

import os
import numpy as np
from pynq import Overlay, allocate

DEFAULT_BIT = os.path.expanduser("~/wepwawet/bitstream/wepwawet.bit")

# Lane assignment - must match BD wiring
LANE_NTT      = 0
LANE_INTT     = 1
LANE_PMUL     = 2
LANE_SHAKE256 = 3
LANE_SHAKE128 = 4

# AXI-Lite register offsets (HLS default for scalar args)
REG_AP_CTRL   = 0x00
REG_LANE_SEL  = 0x10
REG_NWORDS    = 0x18
REG_MSG_BYTES = 0x10  # SHAKE param
REG_OUT_BYTES = 0x18  # SHAKE param

# TRNG offsets (probed empirically)
TRNG_ENABLE   = 0x00
TRNG_DATA     = 0x10


class WepwawetHW:
    def __init__(self, bitstream_path=DEFAULT_BIT, download=True):
        self.ol   = Overlay(bitstream_path, download=download)
        self.dma  = self.ol.axi_dma_0
        self.ntt  = self.ol.ntt_top_0
        self.intt = self.ol.intt_top_0
        self.pmul = self.ol.polymulacc_top_0
        self.s256 = self.ol.shake256_axis_0
        self.s128 = self.ol.shake128_axis_0
        self.dist = self.ol.axis_distributor_5la_0
        self.coll = self.ol.axis_collector_5lane_0
        self.trng = self.ol.trng_axi_0

        # Enable TRNG entropy source
        self.trng.write(TRNG_ENABLE, 0x01)

    # ---------------------------------------------------------------
    # Internal helpers
    # ---------------------------------------------------------------
    def _start_pulse(self, ip):
        ip.write(REG_AP_CTRL, 0x01)

    def _config_route(self, lane, in_words, out_words):
        self.dist.write(REG_LANE_SEL, lane)
        self.dist.write(REG_NWORDS,   in_words)
        self.coll.write(REG_LANE_SEL, lane)
        self.coll.write(REG_NWORDS,   out_words)
        self._start_pulse(self.dist)
        self._start_pulse(self.coll)

    def _pack_poly_to_buf(self, poly_int32, n_coeffs=256):
        n_words = n_coeffs // 2
        buf = allocate(shape=(n_words,), dtype=np.uint64)
        for i in range(n_words):
            lo = int(poly_int32[2*i])   & 0xFFFFFFFF
            hi = int(poly_int32[2*i+1]) & 0xFFFFFFFF
            buf[i] = np.uint64((hi << 32) | lo)
        return buf

    def _unpack_buf_to_poly(self, buf, n_coeffs=256):
        out = [0] * n_coeffs
        n_words = n_coeffs // 2
        for i in range(n_words):
            v = int(buf[i])
            lo = v & 0xFFFFFFFF
            hi = (v >> 32) & 0xFFFFFFFF
            out[2*i]   = lo - (1 << 32) if lo & 0x80000000 else lo
            out[2*i+1] = hi - (1 << 32) if hi & 0x80000000 else hi
        return out

    # ---------------------------------------------------------------
    # NTT
    # ---------------------------------------------------------------
    def do_ntt(self, poly):
        N_WORDS = 128
        self._config_route(LANE_NTT, N_WORDS, N_WORDS)
        self._start_pulse(self.ntt)

        in_buf  = self._pack_poly_to_buf(poly)
        out_buf = allocate(shape=(N_WORDS,), dtype=np.uint64)

        self.dma.recvchannel.transfer(out_buf)
        self.dma.sendchannel.transfer(in_buf)
        self.dma.sendchannel.wait()
        self.dma.recvchannel.wait()

        return self._unpack_buf_to_poly(out_buf)

    # ---------------------------------------------------------------
    # INTT
    # ---------------------------------------------------------------
    def do_intt(self, poly):
        N_WORDS = 128
        self._config_route(LANE_INTT, N_WORDS, N_WORDS)
        self._start_pulse(self.intt)

        in_buf  = self._pack_poly_to_buf(poly)
        out_buf = allocate(shape=(N_WORDS,), dtype=np.uint64)

        self.dma.recvchannel.transfer(out_buf)
        self.dma.sendchannel.transfer(in_buf)
        self.dma.sendchannel.wait()
        self.dma.recvchannel.wait()

        return self._unpack_buf_to_poly(out_buf)

    # ---------------------------------------------------------------
    # PolyMulAcc - pointwise multiply in Montgomery domain
    # Input: poly A (256 coeffs) followed by poly B (256 coeffs)
    # Output: poly C = A * B (pointwise, 256 coeffs)
    # ---------------------------------------------------------------
    def do_polymul(self, a, b):
        IN_WORDS  = 256
        OUT_WORDS = 128
        self._config_route(LANE_PMUL, IN_WORDS, OUT_WORDS)
        self._start_pulse(self.pmul)

        in_buf  = allocate(shape=(IN_WORDS,), dtype=np.uint64)
        out_buf = allocate(shape=(OUT_WORDS,), dtype=np.uint64)

        for i in range(128):
            lo = int(a[2*i])   & 0xFFFFFFFF
            hi = int(a[2*i+1]) & 0xFFFFFFFF
            in_buf[i] = np.uint64((hi << 32) | lo)
        for i in range(128):
            lo = int(b[2*i])   & 0xFFFFFFFF
            hi = int(b[2*i+1]) & 0xFFFFFFFF
            in_buf[128 + i] = np.uint64((hi << 32) | lo)

        self.dma.recvchannel.transfer(out_buf)
        self.dma.sendchannel.transfer(in_buf)
        self.dma.sendchannel.wait()
        self.dma.recvchannel.wait()

        return self._unpack_buf_to_poly(out_buf)

    # ---------------------------------------------------------------
    # SHAKE-256
    # ---------------------------------------------------------------
    def do_shake256(self, msg, out_bytes):
        return self._shake(msg, out_bytes, self.s256, LANE_SHAKE256)

    # ---------------------------------------------------------------
    # SHAKE-128
    # ---------------------------------------------------------------
    def do_shake128(self, msg, out_bytes):
        return self._shake(msg, out_bytes, self.s128, LANE_SHAKE128)

    def _shake(self, msg, out_bytes, ip, lane):
        if isinstance(msg, str):
            msg = msg.encode()
        msg_bytes = len(msg)
        msg_words = (msg_bytes + 7) // 8
        out_words = (out_bytes + 7) // 8

        ip.write(REG_MSG_BYTES, msg_bytes)
        ip.write(REG_OUT_BYTES, out_bytes)

        self._config_route(lane, msg_words, out_words)
        self._start_pulse(ip)

        in_buf  = allocate(shape=(msg_words,), dtype=np.uint64)
        out_buf = allocate(shape=(out_words,), dtype=np.uint64)

        padded = msg + b'\x00' * (msg_words * 8 - msg_bytes)
        for i in range(msg_words):
            word = 0
            for b in range(8):
                word |= padded[i*8 + b] << (8*b)
            in_buf[i] = np.uint64(word)

        self.dma.recvchannel.transfer(out_buf)
        self.dma.sendchannel.transfer(in_buf)
        self.dma.sendchannel.wait()
        self.dma.recvchannel.wait()

        result = bytearray()
        for i in range(out_words):
            word = int(out_buf[i])
            for b in range(8):
                result.append((word >> (8*b)) & 0xFF)
        return bytes(result[:out_bytes])

    # ---------------------------------------------------------------
    # TRNG - hardware entropy source (AXI-Lite, no DMA)
    # ---------------------------------------------------------------
    def trng_word(self):
        """Return one 32-bit random word from the TRNG."""
        return self.trng.read(TRNG_DATA) & 0xFFFFFFFF

    def trng_bytes(self, n):
        """Return n random bytes from the TRNG."""
        out = bytearray()
        while len(out) < n:
            w = self.trng_word()
            out.extend(w.to_bytes(4, 'little'))
        return bytes(out[:n])


# ---------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------
if __name__ == "__main__":
    import hashlib

    hw = WepwawetHW()
    print("Wepwawet hardware initialized.\n")

    # SHAKE-256
    out = hw.do_shake256(b"abc", 32)
    ref = hashlib.shake_256(b"abc").digest(32)
    ok  = "PASS" if out == ref else "FAIL"
    print(f"SHAKE-256('abc', 32B): {ok}")
    print(f"  HW : {out.hex()}")
    print(f"  REF: {ref.hex()}")

    # SHAKE-128
    out = hw.do_shake128(b"abc", 32)
    ref = hashlib.shake_128(b"abc").digest(32)
    ok  = "PASS" if out == ref else "FAIL"
    print(f"SHAKE-128('abc', 32B): {ok}")
    print(f"  HW : {out.hex()}")
    print(f"  REF: {ref.hex()}")

    # TRNG
    rnd = hw.trng_bytes(32)
    print(f"TRNG 32B: {rnd.hex()}")

    # NTT round-trip: NTT then INTT should recover (modulo Q)
    poly = list(range(256))
    n  = hw.do_ntt(poly)
    r  = hw.do_intt(n)
    print(f"NTT->INTT round-trip first 4 coeffs: {r[:4]}")
