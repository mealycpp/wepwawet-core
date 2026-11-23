// ======================================================================
// \title  HwAccelMgr.hpp  -- WEPWAWET-CORE crypto backend for F'
// FPGA backend: direct /dev/mem driver (wcore_fpga.c), no Python, no subprocess.
//   Sign   -> PL Sign program (rejection loop in fabric), hedged with the PL TRNG
//   Verify -> PL Verify program when the loaded image is v6 (VERSION 0x00020001),
//             otherwise PQClean ML-DSA-44 (C) on the A53 -- reported in every log line
// CPU backend (env WCORE_BACKEND=cpu): PQClean ML-DSA-44 aarch64 NEON (-O3) for Sign and Verify.
// ======================================================================
#ifndef Wepwawet_HwAccelMgr_HPP
#define Wepwawet_HwAccelMgr_HPP
#include "HwAccelMgr/HwAccelMgrComponentAc.hpp"
#include "Fw/Buffer/Buffer.hpp"
#include <mutex>
extern "C" {
#include "HwAccelMgr/wcore_fpga.h"
}
namespace Wepwawet {
class HwAccelMgr final : public HwAccelMgrComponentBase {
  public:
    HwAccelMgr(const char* const compName);
    ~HwAccelMgr();
  private:
    void keygenReq_handler(FwIndexType portNum) override;
    void signReq_handler(FwIndexType portNum, Fw::Buffer& skBuffer, Fw::Buffer& msgBuffer,
                         Fw::Buffer& sigBuffer) override;
    void verifyReq_handler(FwIndexType portNum, Fw::Buffer& pkBuffer, Fw::Buffer& msgBuffer,
                           Fw::Buffer& sigBuffer, U8& ok) override;
    bool ensureFpga();
    void logLine(const char* op, const char* backend, int rc, int verdict, const wcore_stats_t* st, double us);
    std::mutex m_backendMutex;      // one owner of the single shared PL engine
    wcore_t m_wcore;
    bool m_fpgaOpen;
    bool m_hasVerify;
    bool m_cpuBackend;
    bool m_sealed;                  // seal_v8: key sealed in the PL, sk never handled by F'
    U32 m_nttCount;
    U32 m_inttCount;
    U32 m_pmulCount;
    U32 m_shake256Count;
    U32 m_shake128Count;
    U64 m_trngBytes;
    U32 m_signCount;
    U32 m_verifyCount;
};
}  // namespace Wepwawet
#endif
