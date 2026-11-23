#!/usr/bin/env python3
"""Offline deterministic codec for proposed WCORE Stage 8 dynamic ROM.
NO imports from pynq; NO FPGA access. This does not enable other lanes.
"""
from dataclasses import dataclass

LANES = {'ntt': 0, 'intt': 1, 'polymulacc': 2, 'shake256': 3, 'shake128': 4}
MASK64 = (1 << 64) - 1
HALT = 0x7000000000000000

@dataclass(frozen=True)
class Descriptor:
    name: str
    tx_words: int
    rx_words: int
    tx_bank: int = 0
    rx_bank: int = 1
    tx_addr: int = 0
    rx_addr: int = 0

    def encode(self):
        if self.name not in LANES:
            raise ValueError('Unknown kernel')
        lane = LANES[self.name]
        if (self.tx_bank, self.rx_bank, self.tx_addr, self.rx_addr) != (0, 1, 0, 0):
            raise ValueError('Stage8 candidate restricts input bank0/output bank1, offset 0')
        if not (1 <= self.tx_words <= 2048 and 1 <= self.rx_words <= 2048):
            raise ValueError('Invalid transfer length')
        expected = (256, 128) if lane == 2 else (128, 128)
        if lane in (0, 1, 2) and (self.tx_words, self.rx_words) != expected:
            raise ValueError('Bad polynomial kernel transfer length')
        value = (lane << 57) | (self.rx_bank << 53) | (self.tx_words << 19) | (self.rx_words << 7) | lane
        assert 0 <= value <= MASK64
        return value

    def gpio_words(self):
        raw = self.encode()
        return (raw & 0xFFFFFFFF, raw >> 32)


def decode(word):
    if not isinstance(word, int) or not 0 <= word <= MASK64:
        raise ValueError('Descriptor must be uint64')
    return dict(op=(word >> 60) & 0xF, lane=(word >> 57) & 0x7,
                tx_bank=(word >> 55) & 0x3, rx_bank=(word >> 53) & 0x3,
                tx_addr=(word >> 42) & 0x7FF, rx_addr=(word >> 31) & 0x7FF,
                tx_words=(word >> 19) & 0xFFF, rx_words=(word >> 7) & 0xFFF,
                cfg_index=word & 0x7F)


def preflight(name, tx_words, rx_words):
    desc = Descriptor(name, tx_words, rx_words)
    word = desc.encode()
    d = decode(word)
    assert d['op'] == 0 and d['lane'] == LANES[name]
    assert d['tx_bank'] == 0 and d['rx_bank'] == 1
    assert d['tx_words'] == tx_words and d['rx_words'] == rx_words
    assert d['cfg_index'] == LANES[name]
    return word


if __name__ == '__main__':
    for name, tx, rx in [('ntt',128,128), ('intt',128,128),
                         ('polymulacc',256,128), ('shake256',1,4), ('shake128',1,4)]:
        v = preflight(name,tx,rx)
        print(f'{name:12s} desc=0x{v:016X} low=0x{v & 0xffffffff:08X} high=0x{v >> 32:08X}')
    print('STAGE8_OFFLINE_DESCRIPTOR_CODEC_PASS')
