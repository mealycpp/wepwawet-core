module Wepwawet {

    @ Wepwawet hardware accelerator manager - wraps NTT/INTT/PolyMul/SHAKE/TRNG
    passive component HwAccelMgr {

        # ----------------------------------------------------------------------
        # Service ports - called synchronously by Sign/Verify components
        # ----------------------------------------------------------------------

        @ Request a Dilithium2 keypair generation (uses TRNG + all kernels)
        sync input port keygenReq: Wepwawet.KeygenReq

        @ Request a Dilithium2 signature
        sync input port signReq: Wepwawet.SignReq

        @ Request a Dilithium2 verification
        sync input port verifyReq: Wepwawet.VerifyReq

        # ----------------------------------------------------------------------
        # Telemetry: counters for hardware usage
        # ----------------------------------------------------------------------

        @ Number of NTT operations dispatched
        telemetry NttCount: U32

        @ Number of INTT operations dispatched
        telemetry InttCount: U32

        @ Number of PolyMulAcc operations dispatched
        telemetry PolyMulCount: U32

        @ Number of SHAKE-256 invocations
        telemetry Shake256Count: U32

        @ Number of SHAKE-128 invocations
        telemetry Shake128Count: U32

        @ Number of TRNG bytes consumed
        telemetry TrngBytes: U64

        # ----------------------------------------------------------------------
        # Events
        # ----------------------------------------------------------------------

        @ Hardware initialized successfully
        event HwReady() severity activity high id 0 format "Wepwawet hardware accelerator ready"

        @ Hardware operation failed
        event HwError(op: string size 32, msg: string size 80) severity warning high id 1 format "HW op {} failed: {}"

        # ----------------------------------------------------------------------
        # Required AC ports
        # ----------------------------------------------------------------------

        @ Time get port
        time get port timeCaller

        @ Telemetry channel out
        telemetry port tlmOut

        @ Event log out
        event port eventOut

        @ Text event log out
        text event port textEventOut
    }
}
