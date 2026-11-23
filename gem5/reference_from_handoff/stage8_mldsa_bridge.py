"""Experimental, per-process ML-DSA-44 hardware integration.

All cryptographic tests MUST use disposable experiment keys. Hardware SHAKE
uses full-prefix re-generation for XOF reads; it is not incremental hardware
sponge state nor overlapped pipeline. Never mix this patched module with CPU
baseline in one process.
"""
from dilithium_py.shake import shake_wrapper
from dilithium_py.ml_dsa import ML_DSA_44
Q=8380417
R=(1<<32)%Q
R_INV=pow(R,-1,Q)


class HardwareXOF:
    def __init__(self,hw,kind,prefetch=256):
        if kind not in ('shake128','shake256'):
            raise ValueError('invalid SHAKE engine')
        if not (1<=prefetch<=16384):
            raise ValueError('prefetch outside scratchpad capacity')
        self.hw=hw
        self.kind=kind
        self.prefetch=prefetch
        self.seed=None
        self.buf=b''
        self.idx=0

    def absorb(self,data):
        self.seed=bytes(data)
        self.idx=0
        self.buf=b''
        if not self.seed:
            # Hardware empty input framing is unverified. Do not silently
            # compute a software SHAKE for this case.
            raise RuntimeError('Hardware SHAKE zero-byte absorb unsupported')
        if len(self.seed)>16384:
            raise RuntimeError('Hardware SHAKE input exceeds scratchpad capacity')
        return self

    def read(self,n):
        if not isinstance(n,int) or n<0:
            raise ValueError('SHAKE XOF read requires nonnegative integer')
        if self.seed is None:
            raise RuntimeError('XOF read before absorb')
        required=self.idx+n
        if required>16384:
            raise RuntimeError('SHAKE XOF output beyond 16384 bytes; no chunking support')
        if required>len(self.buf):
            # Regenerate a longer *prefix* from the same seed on the FPGA.
            # Correct XOF bytes, but repeated work, NOT stream continuation.
            wanted=min(16384,max(required,self.prefetch,len(self.buf)*2))
            self.buf=getattr(self.hw,'do_'+self.kind)(self.seed,wanted)
            if len(self.buf)!=wanted:
                raise RuntimeError('Hardware XOF truncated output')
        r=self.buf[self.idx:required]
        self.idx=required
        return r

    def __call__(self,data):
        return self.absorb(data)


class SHAKEFactory:
    """Create a distinct sponge/XOF reader for every SHAKE call.

    The old integration reused one stateful instance globally, so nested
    SHAKE streams could overwrite one another. Each call here is independent.
    """
    def __init__(self,hw,kind,prefetch):
        self.hw=hw
        self.kind=kind
        self.prefetch=prefetch

    def __call__(self,seed):
        return HardwareXOF(self.hw,self.kind,self.prefetch).absorb(seed)

    def absorb(self,seed):
        return self(seed)


class WepwawetPqc:
    def __init__(self,hw, *, intt_scale, shake_prefetch=256, enabled=None):
        if hw is None:
            raise RuntimeError('FPGA hardware backend required')
        if not (1<=intt_scale<Q):
            raise RuntimeError('INTT scale from passing hardware KAT required')
        required=('do_ntt','do_intt','do_polymul','do_shake128','do_shake256')
        for name in required:
            if not callable(getattr(hw,name,None)):
                raise RuntimeError('Missing real hardware method '+name)
        self.hw=hw
        self.scale=intt_scale
        self.scale_inv=pow(intt_scale,-1,Q)
        self.shake_prefetch=shake_prefetch
        self.enabled=frozenset(enabled if enabled is not None else required)
        if not self.enabled or not self.enabled.issubset(required):
            raise ValueError('Offload kernels must be a nonempty subset of the five real kernels')
        self._patch_shake()
        self._patch_polynomials()
        self._dsa=ML_DSA_44

    def _patch_shake(self):
        sha128=SHAKEFactory(self.hw,'shake128',self.shake_prefetch)
        sha256=SHAKEFactory(self.hw,'shake256',self.shake_prefetch)
        from dilithium_py.polynomials import polynomials as _p
        from dilithium_py.ml_dsa import ml_dsa as _m
        for name,factory in [('shake128',sha128),('shake256',sha256)]:
            if name in self.enabled:
                setattr(shake_wrapper,name,factory)
                setattr(_p,name,factory)
                if hasattr(_m,name):
                    setattr(_m,name,factory)

    def _patch_polynomials(self):
        from dilithium_py.polynomials.polynomials import Polynomial,PolynomialNTT
        hw=self.hw
        inverse_factor=(R_INV*self.scale_inv)%Q

        def hw_to_ntt(p):
            inp=[(int(c)%Q)*R%Q for c in p.coeffs]
            out=[(int(c)%Q)*R_INV%Q for c in hw.do_ntt(inp)]
            return p.parent(out,is_ntt=True)

        def hw_from_ntt(p):
            inp=[(int(c)%Q)*R%Q for c in p.coeffs]
            out=[(int(c)%Q)*inverse_factor%Q for c in hw.do_intt(inp)]
            return p.parent(out,is_ntt=False)

        def hw_ntt_mul(p,other):
            if not isinstance(other,type(p)):
                raise ValueError('PolyMulAcc polynomial type mismatch')
            a=[(int(c)%Q)*R%Q for c in p.coeffs]
            b=[(int(c)%Q)*R%Q for c in other.coeffs]
            return [(int(c)%Q)*R_INV%Q for c in hw.do_polymul(a,b)]

        if 'ntt' in self.enabled:
            Polynomial.to_ntt=hw_to_ntt
        if 'intt' in self.enabled:
            PolynomialNTT.from_ntt=hw_from_ntt
        if 'polymulacc' in self.enabled:
            PolynomialNTT.ntt_multiplication=hw_ntt_mul

    def keygen(self):
        # Uses OS CSPRNG; raw experimental TRNG not certified for ML-DSA.
        return self._dsa.keygen()

    def sign(self,sk,msg):
        return self._dsa.sign(sk,msg)

    def verify(self,pk,msg,sig):
        return bool(self._dsa.verify(pk,msg,sig))
