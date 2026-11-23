#!/usr/bin/env python3
"""REVIEWER: independent decoder of the WCORE ROM (instr_for) in wcore_stage19_axis_dot4_integrated.sv.
Usage: rom_decode.py <wcore_stage19_axis_dot4_integrated.sv>
Field layout taken from wcore_sequencer_stage9.v (OP_KERNEL / OP_AUX decode)."""
import re, sys
src = open(sys.argv[1]).read()
LANE = {0:'NTT',1:'INTT',2:'lane2',3:'SHAKE256',4:'SHAKE128',5:'lane5'}
AUX = {0x01:'FREEZE',0x02:'CENTER',0x03:'HIGHBITS',0x04:'LOWBITS',0x05:'P2R_HIGH',0x06:'P2R_LOW',
       0x10:'ADD',0x11:'SUB',0x12:'MAKE_HINT',0x13:'USE_HINT',0x20:'NORM_Z',0x21:'NORM_W0',0x22:'NORM_CT0',
       0x30:'REJNTT',0x31:'SAMPLEINBALL',0x32:'GAMMA1_UNPACK',0x33:'DOT4(A_hat row . b1[0..511])',
       0x34:'ETA2',0x35:'EXPANDA_INPUT',0x36:'W1ENCODE',0x37:'CHALLENGE_MSG',
       0x38:'c_hat*s1_hat(b1[512..])',0x39:'c_hat*s2_hat(b1[1536..])',0x3A:'c_hat*t0_hat(b2[1536..])'}
def val(tok):
    m = re.fullmatch(r"(\d+)'([hdb])([0-9A-Fa-f_]+)", tok.strip())
    w, b, v = int(m.group(1)), m.group(2), m.group(3).replace('_','')
    return w, int(v, {'h':16,'d':10,'b':2}[b])
def parse(expr):
    expr = expr.strip()
    if expr.startswith('{'):
        x = 0; tot = 0
        for tok in expr[1:-1].split(','):
            w, v = val(tok); x = (x << w) | (v & ((1<<w)-1)); tot += w
        assert tot == 64, (expr, tot)
        return x
    return val(expr)[1]
prog = {}
for m in re.finditer(r"8'd(\d+):\s*instr_for\s*=\s*(\{[^;]*\}|64'h[0-9A-Fa-f]+)\s*;", src, re.S):
    prog[int(m.group(1))] = parse(re.sub(r'\s+', '', m.group(2)))
def bits(x, hi, lo): return (x >> lo) & ((1 << (hi-lo+1)) - 1)
for pc in sorted(prog):
    i = prog[pc]; op = bits(i,63,60)
    if op == 0:
        print(f"PC{pc:3d} KERNEL {LANE.get(bits(i,59,57))}: tx b{bits(i,56,55)}[{bits(i,52,42)}..+{bits(i,30,19)}) "
              f"-> rx b{bits(i,54,53)}[{bits(i,41,31)}..+{bits(i,18,7)}) cfg={bits(i,6,0)}")
    elif op == 8:
        a = bits(i,59,52)
        print(f"PC{pc:3d} AUX {AUX.get(a,hex(a))}: src b{bits(i,51,50)}[{bits(i,47,37)}] dst b{bits(i,49,48)}[{bits(i,36,26)}] words={bits(i,25,14)}")
    elif op == 3: print(f"PC{pc:3d} BRANCH cond={bits(i,59,57)} -> PC{bits(i,56,49)}")
    elif op == 4: print(f"PC{pc:3d} INC reg={bits(i,59,57)} imm={bits(i,56,41)}")
    elif op == 7: print(f"PC{pc:3d} HALT")
    else: print(f"PC{pc:3d} op{op} {i:016x}")
