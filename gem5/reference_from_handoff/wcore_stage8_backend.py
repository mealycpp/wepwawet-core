#!/usr/bin/env python3
"""Stage8 AXI-Lite scratchpad plus AXI-Stream sequencer backend.

No implicit FPGA programming, no software fallback. Hardware correctness and
version must be established by the experiment suite before cryptographic runs.
SHAKE bases match Vivado HWH mapping: 128 at 0x80050000, 256 at 0x80070000.
"""
import os
import time
import fcntl
from pathlib import Path

from wcore_stage8_descriptor import Descriptor

HOST_BASE = 0xA0040000
SMOKE_GPIO_BASE = 0xA0030000
SELECT_GPIO_BASE = 0xA0050000  # proposed, MUST be verified in Stage8 HWH
TRNG_BASE = 0xA0000000
SHAKE256_BASE = 0x80070000
SHAKE128_BASE = 0x80050000
Q = 8380417


class WcoreStage8:
    """Fail-closed backend for the loaded Stage8 bitstream.

    Public methods match the original WepwawetHW call contract.
    Banks 0 and 1 are treated as EXCLUSIVELY RESERVED for this process.
    DO NOT use with live keys until scratchpad isolation/scrub is proven.
    """
    def __init__(self, bitstream_path, *, confirm_candidate=False,
                 shake_registers_verified=False):
        if confirm_candidate is not True:
            raise RuntimeError('STOP: explicit Stage8-candidate authorization required')
        bitstream_path = str(Path(bitstream_path).resolve())
        if 'stage7f_333mhz.bit' in bitstream_path.lower():
            raise RuntimeError('STOP: preserved Stage7F is NTT-only; never use Stage8 backend')
        from pynq import MMIO, PL
        if PL.bitfile_name != bitstream_path:
            raise RuntimeError('STOP: Stage8 is not already programmed; no auto-download')
        self._bitstream = bitstream_path
        ips = PL.ip_dict
        required = dict(wcore_host_mem_axi_0=HOST_BASE,
                        wcore_ntt_gpio_0=SMOKE_GPIO_BASE,
                        wcore_job_desc_gpio_0=SELECT_GPIO_BASE)
        for name, base in required.items():
            if ips.get(name, {}).get('phys_addr') != base:
                raise RuntimeError('STOP: Stage8 HWH mismatch at ' + name)
        self.host = MMIO(HOST_BASE,0x1000)
        self.smoke = MMIO(SMOKE_GPIO_BASE,0x1000)
        self.descriptor = MMIO(SELECT_GPIO_BASE,0x1000)
        self.sha128 = MMIO(SHAKE128_BASE,0x1000)
        self.sha256 = MMIO(SHAKE256_BASE,0x1000)
        self._shake_registers_verified = shake_registers_verified
        if self.host.read(0x1C) != 0x57434F52:
            raise RuntimeError('STOP: WCORE host ID mismatch')
        # Caller must hold this lock across the entire signing operation;
        # existing unrelated services may not honor it.
        lock_path = '/tmp/wepwawet_stage8_exclusive.lock'
        self._lock = open(lock_path, 'a+')
        try:
            fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            self._lock.close()
            raise RuntimeError('STOP: other Stage8 driver owns AUP1') from exc
        self.kernel_calls = {'ntt':0,'intt':0,'polymulacc':0,'shake256':0,'shake128':0}
        self._host_ready()
        self._idle()
        # Stage8 descriptor GPIO channels should be hardware outputs.
        self.descriptor.write(0,0)
        self.descriptor.write(8,0)
        if self.descriptor.read(0) != 0 or self.descriptor.read(8) != 0:
            raise RuntimeError('STOP: descriptor GPIO data readback did not clear')

    def _host_ready(self):
        hs = self.host.read(0x10)
        if (hs >> 16) != 0x7F10 or (hs & 0x1D) != 0x18 or ((hs >> 8) & 255):
            raise RuntimeError(f'STOP: WCORE host not eligible/idle 0x{hs:08X}')

    def _idle(self):
        s = self.smoke.read(8)
        if (s & 0x1F) != 0x10 or (s >> 24):
            raise RuntimeError(f'STOP: sequencer not idle 0x{s:08X}')
        return s

    def _transaction(self, cmd):
        self._host_ready()
        self.host.write(0x0C,cmd)
        deadline = time.monotonic()+1.0
        while time.monotonic() < deadline:
            s = self.host.read(0x10)
            if s & 2:
                if (s & 5) or ((s >> 8) & 255):
                    raise RuntimeError(f'WCORE host operation failed: 0x{s:08X}')
                return
        raise TimeoutError('STOP: host transaction deadline exceeded')

    def _read_word(self,bank,idx):
        if not (bank in (0,1) and 0<=idx<2048):
            raise ValueError('Scratchpad region out of bounds')
        self.host.write(0,bank*2048+idx)
        self._transaction(2)
        return self.host.read(0x14)|(self.host.read(0x18)<<32)

    def _write_word(self,bank,idx,word):
        if not (bank in (0,1) and 0<=idx<2048 and 0<=word<(1<<64)):
            raise ValueError('Scratchpad word out of bounds')
        self.host.write(0,bank*2048+idx)
        self.host.write(4,word&0xffffffff)
        self.host.write(8,word>>32)
        self._transaction(1)

    @staticmethod
    def _pack_poly(coeffs):
        if len(coeffs)!=256:
            raise ValueError('A polynomial has exactly 256 coefficients')
        return [((int(coeffs[2*i+1])&0xffffffff)<<32)|
                (int(coeffs[2*i])&0xffffffff) for i in range(128)]

    @staticmethod
    def _unpack_poly(words):
        out=[]
        for w in words:
            for c in (w&0xffffffff,(w>>32)&0xffffffff):
                out.append(c - (1<<32) if c & (1<<31) else c)
        return out

    def _pulse(self,value):
        try:
            self.smoke.write(0,value)
            time.sleep(.002)
        finally:
            self.smoke.write(0,0)

    def _configure_shake(self,name,msg_bytes,out_bytes):
        if not self._shake_registers_verified:
            raise RuntimeError('STOP: actual SHAKE AXI-Lite headers not verified')
        if not 0 < msg_bytes <= 16384 or not 0 < out_bytes <= 16384:
            raise ValueError('SHAKE sizes outside current Stage8 scratchpad contract')
        ip = self.sha256 if name=='shake256' else self.sha128
        # ONLY valid if the HLS header confirms offsets 0x10, 0x18.
        ip.write(0x10,msg_bytes)
        ip.write(0x18,out_bytes)

    def _run(self,name,input_words,output_words,*,msg_bytes=None,out_bytes=None):
        # Fail-closed before writing descriptor or scratchpad.
        desc = Descriptor(name,len(input_words),output_words)
        desc_lo,desc_hi = desc.gpio_words()
        if len(input_words)>2048 or output_words>2048:
            raise ValueError('Scratchpad capacity exceeded')
        self._host_ready()
        self._idle()
        if name.startswith('shake'):
            self._configure_shake(name,msg_bytes,out_bytes)
        # Stage8 exclusively reserves bank0/1. Never save potentially secret
        # contents to plaintext disk; wipe the touched region after use.
        try:
            for i,word in enumerate(input_words):
                self._write_word(0,i,word)
            for i in range(output_words):
                self._write_word(1,i,0)
            self._idle()
            self.descriptor.write(0,desc_lo)
            self.descriptor.write(8,desc_hi)
            if self.descriptor.read(0)!=desc_lo or self.descriptor.read(8)!=desc_hi:
                raise RuntimeError('STOP: Stage8 descriptor GPIO readback mismatch')
            self._pulse(1)
            until=time.monotonic()+5.0
            result=None
            while time.monotonic()<until:
                s=self.smoke.read(8)
                if s&0x0E:
                    result=s
                    break
                time.sleep(.005)
            if result is None:
                raise TimeoutError('STOP: WCORE job did not finish; no automatic retry')
            if result&0x0C or not (result&2):
                raise RuntimeError(f'STOP: WCORE job error/locked 0x{result:08X}')
            # Status counters are eight bits. Check exact counts only when
            # representable. For longer streams, TLAST and the independent
            # full-output KAT provide the correctness check; never assume
            # whether the RTL wraps or saturates a >255 beat count.
            observed_tx=(result>>8)&255
            observed_rx=(result>>16)&255
            if ((len(input_words)<=255 and observed_tx!=len(input_words)) or
                (output_words<=255 and observed_rx!=output_words)):
                raise RuntimeError(f'STOP: stream beat mismatch 0x{result:08X}')
            if (result & 0x60)!=0x60:
                raise RuntimeError(f'STOP: absent TLAST 0x{result:08X}')
            self._pulse(2)
            self._idle()
            output=[self._read_word(1,i) for i in range(output_words)]
            self.kernel_calls[name]+=1
            return output
        finally:
            # No SCRUB on faulted/locked jobs: never issue new host writes
            # until sequencer returns to idle. Operations are NOT transactional.
            try:
                if (self.smoke.read(8)&0x1F)==0x10:
                    for i in range(len(input_words)):
                        self._write_word(0,i,0)
                    for i in range(output_words):
                        self._write_word(1,i,0)
            finally:
                self.descriptor.write(0,0)
                self.descriptor.write(8,0)

    def do_ntt(self, poly):
        return self._unpack_poly(self._run('ntt',self._pack_poly(poly),128))

    def do_intt(self, poly):
        return self._unpack_poly(self._run('intt',self._pack_poly(poly),128))

    def do_polymul(self, a,b):
        return self._unpack_poly(self._run('polymulacc',self._pack_poly(a)+self._pack_poly(b),128))

    def _shake(self,msg,out_bytes,name):
        if isinstance(msg,str): msg=msg.encode()
        msg=bytes(msg)
        if len(msg)==0:
            raise RuntimeError('STOP: empty-message SHAKE framing not yet verified')
        if not (1<=out_bytes<=16384):
            raise ValueError('Invalid SHAKE output byte count')
        count_in=(len(msg)+7)//8
        count_out=(out_bytes+7)//8
        words=[int.from_bytes(msg[8*i:8*(i+1)].ljust(8,b'\0'),'little') for i in range(count_in)]
        out=self._run(name,words,count_out,msg_bytes=len(msg),out_bytes=out_bytes)
        return b''.join(w.to_bytes(8,'little') for w in out)[:out_bytes]

    def do_shake128(self,msg,out_bytes): return self._shake(msg,out_bytes,'shake128')
    def do_shake256(self,msg,out_bytes): return self._shake(msg,out_bytes,'shake256')

    def trng_bytes(self,n):
        # Real TRNG is functional but not SP800-90B qualified. Refuse use as
        # key-generation entropy until health tests and conditioning certified.
        raise RuntimeError('STOP: raw TRNG not approved for key generation')

    def close(self):
        if getattr(self,'_lock',None):
            fcntl.flock(self._lock,fcntl.LOCK_UN)
            self._lock.close()
            self._lock=None
