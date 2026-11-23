// ======================================================================
// \title  HwAccelMgr.cpp  -- see HwAccelMgr.hpp
// ======================================================================
#include "HwAccelMgr/HwAccelMgr.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
extern "C" {
#include "HwAccelMgr/pqclean_neon/api.h"   /* PQClean ML-DSA-44 aarch64 NEON: the strongest A53 baseline */
}

namespace Wepwawet {

static double nowUs() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e6 + t.tv_nsec / 1e3; }
static const char* STATS = "/home/xilinx/wepwawet-core/logs/fprime_hw_stats.csv";
static const char* TR_PATH = "/home/xilinx/wepwawet-core/firmware/identity/node_tr.bin";   // public tr = H(pk)

HwAccelMgr::HwAccelMgr(const char* const compName)
    : HwAccelMgrComponentBase(compName), m_fpgaOpen(false), m_hasVerify(false), m_cpuBackend(false), m_sealed(false),
      m_nttCount(0), m_inttCount(0), m_pmulCount(0), m_shake256Count(0), m_shake128Count(0), m_trngBytes(0),
      m_signCount(0), m_verifyCount(0) {
    std::memset(&m_wcore, 0, sizeof m_wcore);
    const char* b = std::getenv("WCORE_BACKEND");
    m_cpuBackend = (b != nullptr && std::strcmp(b, "cpu") == 0);
    std::fprintf(stderr, "WCORE: HwAccelMgr backend=%s\n", m_cpuBackend ? "cpu(PQClean)" : "fpga");
}

HwAccelMgr::~HwAccelMgr() { if (m_fpgaOpen) wcore_close(&m_wcore); }

bool HwAccelMgr::ensureFpga() {
    if (m_fpgaOpen) return true;
    const int rc = wcore_open(&m_wcore, 100);                 // 100 us sleep-poll while the PL works
    if (rc != 0) {
        this->log_WARNING_HI_HwError(Fw::String("open"), Fw::String("wcore_open failed: image not loaded or not root"));
        return false;
    }
    m_fpgaOpen = true;
    m_hasVerify = wcore_has_verify(&m_wcore) != 0;
    // seal_v8 (VERSION >= 0x0003_0002): the node key lives only in the PL. Attach to the key sealed at boot
    // (phase 3: generated in the PL by wcore_keygen_tool; phase 2r: wcore_provision) using the PUBLIC tr = H(pk)
    // file node_tr.bin written by that tool. F' never opens node_sk.bin on a v8 image.
    m_sealed = wcore_is_v8(&m_wcore) != 0;
    if (m_sealed) {
        int ar = -1; U8 tr[64];
        FILE* tf = std::fopen(TR_PATH, "rb");
        if (tf) { if (std::fread(tr, 1, 64, tf) == 64) ar = wcore_attach_sealed_tr(&m_wcore, tr); std::fclose(tf); }
        // No fallback to node_sk.bin: on a seal_v8 image F' never opens a secret-key file. The key must already be
        // sealed in the PL (phase 3: wcore_keygen_tool, phase 2r: wcore_provision) and node_tr.bin written by that tool.
        if (ar != 0) std::fprintf(stderr, "WCORE: seal_v8: no sealed key (PL not LOCKED or %s missing) rc=%d -> signing disabled\n", TR_PATH, ar);
        if (ar != 0) {
            this->log_WARNING_HI_HwError(Fw::String("seal"), Fw::String("seal_v8: no sealed key (run wcore_provision)"));
            m_fpgaOpen = false; wcore_close(&m_wcore); return false;
        }
        std::fprintf(stderr, "WCORE: seal_v8 image: signing key SEALED in the PL; sk is never passed to the driver\n");
    }
    std::fprintf(stderr, "WCORE: FPGA open, verify program %s\n", m_hasVerify ? "PRESENT (v6)" : "absent (v5) -> PQClean verify");
    this->log_ACTIVITY_HI_HwReady();
    return true;
}

void HwAccelMgr::logLine(const char* op, const char* backend, int rc, int verdict, const wcore_stats_t* st, double us) {
    std::fprintf(stderr, "WCORE: %s backend=%s rc=%d verdict=%d attempts=%u pl_cycles=%u pl_us=%.1f host_total_us=%.1f\n",
                 op, backend, rc, verdict, st ? st->attempts : 0, st ? st->cycles : 0,
                 st ? st->cycles / 300.0 : 0.0, us);
    FILE* f = std::fopen(STATS, "a");
    if (f) {
        std::fprintf(f, "%.0f,%s,%s,%d,%d,%u,%u,%.1f,%.1f,%.1f,%.1f,%.1f\n", nowUs(), op, backend, rc, verdict,
                     st ? st->attempts : 0, st ? st->cycles : 0, st ? st->trng_us : 0.0, st ? st->preload_us : 0.0,
                     st ? st->wait_us : 0.0, st ? st->readback_us : 0.0, us);
        std::fclose(f);
    }
}

void HwAccelMgr::keygenReq_handler(FwIndexType portNum) {
    (void)portNum;   // identities are provisioned offline; KeyGen in fabric is not implemented
    this->log_WARNING_HI_HwError(Fw::String("keygen"), Fw::String("not implemented in fabric; keys are provisioned"));
}

void HwAccelMgr::signReq_handler(FwIndexType portNum, Fw::Buffer& skBuffer, Fw::Buffer& msgBuffer, Fw::Buffer& sigBuffer) {
    (void)portNum;
    std::lock_guard<std::mutex> lock(m_backendMutex);
    if (!m_cpuBackend && !ensureFpga()) { logLine("sign", "fpga-unavailable", -1, -1, nullptr, 0.0); sigBuffer.setSize(0); return; }
    const bool sealed = !m_cpuBackend && m_sealed;      // v8: skBuffer is ignored (may be empty), never read
    if ((!sealed && skBuffer.getSize() != WCORE_SK_BYTES) || sigBuffer.getSize() < WCORE_SIG_BYTES || msgBuffer.getSize() == 0 ||
        msgBuffer.getSize() > 65536) {
        sigBuffer.setSize(0);
        return;
    }
    const double t0 = nowUs();
    int rc;
    wcore_stats_t st;
    std::memset(&st, 0, sizeof st);
    if (m_cpuBackend) {
        size_t sl = 0;
        rc = PQCLEAN_MLDSA44_AARCH64_crypto_sign_signature(sigBuffer.getData(), &sl, msgBuffer.getData(),
                                                         msgBuffer.getSize(), skBuffer.getData());
        if (sl != WCORE_SIG_BYTES) rc = -1;
        logLine("sign", "cpu-neon", rc, -1, nullptr, nowUs() - t0);
    } else {
        if (!ensureFpga()) { logLine("sign", "fpga-unavailable", -1, -1, nullptr, nowUs() - t0); sigBuffer.setSize(0); return; }
        if (sealed) rc = wcore_sign_sealed(&m_wcore, sigBuffer.getData(), msgBuffer.getData(), msgBuffer.getSize(), &st);
        else        rc = wcore_sign(&m_wcore, sigBuffer.getData(), skBuffer.getData(), msgBuffer.getData(), msgBuffer.getSize(), 1, &st);
        logLine("sign", "fpga", rc, -1, &st, nowUs() - t0);   // CSV label unchanged (tools/final_analysis.py); sealed mode logged at init
        if (rc == 0) { m_trngBytes += 128; this->tlmWrite_TrngBytes(m_trngBytes); }
    }
    if (rc != 0) {
        this->log_WARNING_HI_HwError(Fw::String("sign"), Fw::String("backend sign failed (fail closed)"));
        sigBuffer.setSize(0);
        return;
    }
    sigBuffer.setSize(WCORE_SIG_BYTES);
    m_signCount++;
}

void HwAccelMgr::verifyReq_handler(FwIndexType portNum, Fw::Buffer& pkBuffer, Fw::Buffer& msgBuffer,
                                   Fw::Buffer& sigBuffer, U8& ok) {
    (void)portNum;
    std::lock_guard<std::mutex> lock(m_backendMutex);
    ok = 0;
    if (pkBuffer.getSize() != WCORE_PK_BYTES || sigBuffer.getSize() != WCORE_SIG_BYTES || msgBuffer.getSize() > 65536) return;
    const double t0 = nowUs();
    if (!m_cpuBackend && !(ensureFpga() && m_hasVerify)) {
        // FAIL CLOSED: the FPGA backend was requested but the v6 Verify program is not available.
        logLine("verify", "fpga-unavailable", -1, 0, nullptr, nowUs() - t0);
        this->log_WARNING_HI_HwError(Fw::String("verify"), Fw::String("FPGA verify unavailable: rejected (fail closed)"));
        return;
    }
    if (!m_cpuBackend) {
        int valid = 0;
        wcore_stats_t st;
        std::memset(&st, 0, sizeof st);
        const int rc = wcore_verify(&m_wcore, &valid, pkBuffer.getData(), msgBuffer.getData(), msgBuffer.getSize(),
                                    sigBuffer.getData(), &st);
        logLine("verify", "fpga", rc, valid, &st, nowUs() - t0);
        if (rc != 0) {
            this->log_WARNING_HI_HwError(Fw::String("verify"), Fw::String("FPGA verify fault (fail closed)"));
            return;
        }
        ok = valid ? 1 : 0;
    } else {
        const int r = PQCLEAN_MLDSA44_AARCH64_crypto_sign_verify(sigBuffer.getData(), sigBuffer.getSize(), msgBuffer.getData(),
                                                               msgBuffer.getSize(), pkBuffer.getData());
        ok = (r == 0) ? 1 : 0;
        logLine("verify", "cpu-neon", r, ok, nullptr, nowUs() - t0);
    }
    m_verifyCount++;
}

}  // namespace Wepwawet
