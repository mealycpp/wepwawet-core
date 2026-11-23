# WCORE ROM ISA encoder (dev-time tool only; not in the board runtime path)
def kern(lane,txb,rxb,txa,rxa,txw,rxw,cfg):
    return (0<<60)|(lane<<57)|(txb<<55)|(rxb<<53)|(txa<<42)|(rxa<<31)|(txw<<19)|(rxw<<7)|cfg
def aux(op,sb,db,sa,da,w):
    return (8<<60)|(op<<52)|(sb<<50)|(db<<48)|(sa<<37)|(da<<26)|(w<<14)
HALT=7<<60
def branch(cond,tgt): return (3<<60)|(cond<<57)|(tgt<<49)
def inc(reg,imm): return (4<<60)|(reg<<57)|(imm<<41)
if __name__=='__main__':
    assert kern(1,2,3,0,1400,128,128,1)==0x036002BC04004001
    assert aux(0x3A,1,2,1300,0,128)==0x83A6A28000200000
    assert aux(0x11,3,3,0,1400,128)==0x811F0015E0200000
    assert aux(0x13,3,3,1400,512,128)==0x813FAF0800200000
    assert branch(1,147)==0x3326000000000000 and inc(1,1)==0x4200020000000000
    print('ISA_SELFTEST_OK')
