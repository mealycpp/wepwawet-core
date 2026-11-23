`timescale 1ns/1ps
// ============================================================================
// WEPWAWET SIGN image -- PS-facing wrapper (AXI4-Lite slave, 32-bit).
//
// One AXI4-Lite slave in front of the V7 signing core and the registered
// retry manager. Once LAUNCH is written, every ML-DSA-44 signing attempt and
// every rejection/retry decision runs in PL; the PS only preloads inputs
// before launch and reads c~, z, h after DONE.
//
// Byte address map (C_ADDR_W = 17):
//   0x0_0000 .. 0x0_FFFF  scratchpad window (only while the engine is idle)
//                         bank = addr[15:14], word = addr[13:3], half = addr[2]
//                         write low half first; writing the high half commits
//                         the 64-bit word. Reads fetch the word, return a half.
//   0x1_0000  CTRL    W   bit0 LAUNCH (self-clearing), bit1 IRQ_CLEAR,
//                         bit2 MODE at LAUNCH: 0 = SIGN, 1 = VERIFY (verify_v1)
//   0x1_0004  STATUS  R   bit0 busy, bit1 done, bit2 success, bit3 sp_init_done,
//                         bit4 sp_busy, bit5 sp_locked, bit6 job_error,
//                         bit7 adapter_recovery_required, bit8 irq, bit9 mode(1=verify)
//   0x1_0008  KAPPA   R   [15:0] kappa, [31:16] attempts (16-bit; retry bound 814 per FIPS 204 App. C)
//   0x1_000C  ERRORS  R   [7:0] retry error, [15:8] core error, [23:16] pc
//   0x1_0010  CYCLES  R   clock cycles from LAUNCH to DONE (last job)
//   0x1_0014  MAGIC   R   0x5743_5331 ("WCS1")
//   0x1_0018  VERSION R   0x0003_0002 = seal_v8 phase 2 (sealed key region + PL TRNG rnd + PL rho'')
//   0x1_0020  TRNG    R   [10:0] APT worst count, [16:11] RCT max run, [20:17] redraws, [24:21] fail code
//                         (0 ok, 1 timeout, 2 hw flag after 3 redraws, 3 RCT, 4 APT), [25] DET_RND build
// phase 2 scratchpad ABI (bank 2): K b2[1040..1043] (provision before LOCK; sealed), rnd b2[1044..1047],
//   mu b2[1048..1055] (host input, SIGN and VERIFY), ExpandMask blocks (rho''||kappa+r) b2[1056+9r..1064+9r],
//   raw TRNG b2[1100..1115]. The rho'' registers 0x40..0x7C are gone (write-ignored, read 0; a write while
//   LOCKED counts as a violation).
//   0x1_001C  SEAL    R   bit0 locked, bit1 read violation, bit2 write violation,
//                         bit3 zeroizing, [31:16] violation count (saturating)
//   0x1_0040 .. 0x1_007C  rho'' seed, 16 x 32-bit words (W; reads return 0; cleared at DONE)
//   0x1_0080 .. 0x1_009C  public rho, 8 x 32-bit words (R/W; write-refused once LOCKED)
// Scratchpad access while busy, unmapped addresses -> SLVERR.
//
// seal_v8 (phase 1). CTRL bit3 SEAL_LOCK (set-only), bit4 ZEROIZE. STATUS bit10 locked,
// bit11 seal_violation (sticky), bit12 zeroizing, bit13 sign_out_valid, bit14 verify_out_valid.
// While LOCKED the host scratchpad window is whitelisted:
//   reads : only after a successful SIGN: b1[0..511] (h), b1[1150..1153] (c~), b3[1400..1911] (z);
//           only after a completed VERIFY: b1[1150..1153] (c~').  Every other read returns 0 (OKAY)
//           and sets the sticky read-violation bit.
//   writes: only the job-input windows b2[1024..1031] (mu), b2[512..515] (verify rho),
//           b1[1150..1153] (verify c~), b3[0..1023] (verify z, h), b3[1536..2047] (verify t1'_hat).
//           Every other write is dropped (OKAY) and sets the sticky write-violation bit; in
//           particular s1_hat b1[512..1023], s2_hat b1[1536..2047], t0_hat b2[1536..2047] and the
//           rho''/nonce blocks b2[0..35] (written by the retry manager before attempt 1 when LOCKED).
// LOCK is cleared only by aresetn (scratchpad INIT zeroizes all banks before any host access) or by
// ZEROIZE (scratchpad scrub of all 4 x 2048 words, then LOCK, violations, seeds, rho cleared).
// Refused accesses answer OKAY, not SLVERR: a PL SLVERR on a posted ARM store is an asynchronous
// SError on Zynq UltraScale+, so the violation is reported through STATUS/SEAL instead.
// Any SIGN LAUNCH sets LOCK automatically (reviewer MEDIUM-3). After every SIGN job while LOCKED the wrapper
// scrubs every scratchpad word that is neither key (s1_hat/s2_hat/t0_hat), public input (A_hat, mu) nor -- only
// on success -- released output (h, c~, z), BEFORE DONE is reported (reviewer HIGH-2: no SIGN residue such as y,
// r0-cs2, c*t0, w0-cs2+ct0 survives into a later VERIFY or read). Scrub watchdog expiry fails closed.
// seal_v8 phase 4 (PIN, wpin_gate.v): VERIFY accepts only a pk whose verifier image hashes to the PL trust anchor.
//   0x1_00A0 .. 0x1_00BC  PIN, 8 x 32-bit (R always -- public; W until committed, then refused + flagged)
//   0x1_00C0  PIN_CTRL W bit0 COMMIT (write-once lock; cleared only by aresetn, NOT by ZEROIZE)
//             PIN_STAT R bit0 pin_valid, bit1 hard-wired, bit2 pin write violation (sticky), bit3 ALLOW_UNSET build,
//                        [5:4] PIN_MODE, [11:8] last verdict, [31:16] pin violation count
//   0x1_00C4  VERDICT  R [3:0] code, bit4 valid, bit5 pin checked, bit6 fp==pin, bit7 PL c~'==c~
//             codes: 1 ACCEPT, 2 REJECT_SIG (c~'!=c~), 3 REJECT_ZNORM, 4 REJECT_PIN_MISMATCH, 5 REJECT_PIN_UNSET,
//                    6 REJECT_ERROR (gate watchdog / core error), 7 ACCEPT_UNPINNED (only in PIN_ALLOW_UNSET builds)
//   0x1_00C8  PIN_CYC  R cycles of the last pk-image hash (+ PL mu hash when MU_PL);  0x1_00D0 .. 0x1_00EC FP of the last VERIFY
//   0x1_00F0  MSG_LEN  R/W (idle) byte length of M' in b2[1304..1535] for MU_PL builds (2..1856); out of range -> code 8
//             PIN_STAT bit6 MU_PL build, bit7 PIN_MODE 2 with PIN_CONST == 0 (misconfigured: no anchor)
//             code 8 REJECT_MSG_LEN (ERRORS 0xD7)
// A pin reject does not start the core (fail-closed): DONE, success 0, ERRORS[7:0] 0xD4 mismatch / 0xD5 unset / 0xD6 gate.
// ============================================================================
`ifndef WPIN_MODE_DEFAULT
`define WPIN_MODE_DEFAULT 2
`endif
`ifndef WPIN_MU_PL_DEFAULT
`define WPIN_MU_PL_DEFAULT 1
`endif
`ifndef WPIN_TR_DEFAULT
`define WPIN_TR_DEFAULT 512'd0
`endif
`ifndef WPIN_ALLOW_UNSET_DEFAULT
`define WPIN_ALLOW_UNSET_DEFAULT 0
`endif
`ifndef WPIN_CONST_DEFAULT
`define WPIN_CONST_DEFAULT 256'd0
`endif
module wepwawet_sign_axil #(
    parameter integer C_ADDR_W     = 17,
    parameter integer MAX_ATTEMPTS = 814,
    // BUILD-TIME ONLY. 1 = deterministic rnd = 0^32 for KAT simulation. MUST be 0 in the board build
    // (build_sign_image_v8.tcl sets and checks CONFIG.DET_RND 0). Not reachable from any register.
    parameter integer DET_RND = 0,
    // phase 4 PIN. PIN_MODE 2 = hard-wired PIN_CONST (BOARD BUILDS: the authenticated bitstream is the only
    // software-invisible channel into the PL; PIN_CONST = 0 means no anchor -> every VERIFY rejects).
    // PIN_MODE 1 = write-once register: SIM/TEST ONLY (root writes its own pin first after reset). 0 = off.
    // PIN_ALLOW_UNSET 1 = VERIFY with no pin runs (verdict 7); MUST be 0 in board builds (fail-closed).
    // MU_PL 1 = PL computes mu = SHAKE256(TR_CONST || M') from M' in b2[1304..1535] (MSG_LEN reg); host mu ignored.
    parameter integer PIN_MODE        = `WPIN_MODE_DEFAULT,
    parameter integer PIN_ALLOW_UNSET = `WPIN_ALLOW_UNSET_DEFAULT,
    parameter [255:0] PIN_CONST       = `WPIN_CONST_DEFAULT,
    parameter integer MU_PL           = `WPIN_MU_PL_DEFAULT,
    parameter [511:0] TR_CONST        = `WPIN_TR_DEFAULT
)(
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET aresetn" *)
    input  wire                 aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                 aresetn,
    input  wire [C_ADDR_W-1:0]  s_axi_awaddr,
    input  wire [2:0]           s_axi_awprot,
    input  wire                 s_axi_awvalid,
    output reg                  s_axi_awready,
    input  wire [31:0]          s_axi_wdata,
    input  wire [3:0]           s_axi_wstrb,
    input  wire                 s_axi_wvalid,
    output reg                  s_axi_wready,
    output reg  [1:0]           s_axi_bresp,
    output reg                  s_axi_bvalid,
    input  wire                 s_axi_bready,
    input  wire [C_ADDR_W-1:0]  s_axi_araddr,
    input  wire [2:0]           s_axi_arprot,
    input  wire                 s_axi_arvalid,
    output reg                  s_axi_arready,
    output reg  [31:0]          s_axi_rdata,
    output reg  [1:0]           s_axi_rresp,
    output reg                  s_axi_rvalid,
    input  wire                 s_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire                 irq,
    // seal_v8 phase 2: Stage 8 TRNG PL port (trng_axi pl_*), same clock
    output wire                 trng_claim,
    input  wire [31:0]          trng_word,
    input  wire                 trng_valid,
    input  wire                 trng_health_fail
);
    localparam integer AW = 11, BANKS = 4;

    // ------------------------------------------------------------ core + retry
    wire start_job, job_ack, mgr_host_mode;
    wire [3:0] mgr_wr_valid; wire [43:0] mgr_wr_addr; wire [255:0] mgr_wr_data;
    wire mgr_done, mgr_success; wire [15:0] mgr_kappa, mgr_attempts; wire [7:0] mgr_error;
    wire job_busy, job_done, job_error, job_irq, reject_status, adapter_recovery_required;
    wire route_enable; wire [2:0] route_lane;
    wire [7:0] error_code, pc_status;
    wire [15:0] kappa_status, attempt_status, router_writes, ntt_starts, intt_starts;
    wire sp_init_done, sp_busy, sp_locked, sp_scrub_done;
    reg  ext_scrub, zeroizing, seal_lock, seal_rv, seal_wv, sign_out_ok, verify_out_ok;
    reg  [15:0] viol_cnt;
    reg  pscrub, pscrub_ok, ps_ph; reg [10:0] ps_a; reg [3:0] ps_pend; reg [15:0] ps_wdog;

    reg  [3:0]   h_rd_req_valid, h_rd_rsp_ready;
    reg  [43:0]  h_rd_req_addr;
    wire [3:0]   h_rd_req_ready, h_rd_rsp_valid, h_wr_req_ready;
    wire [255:0] h_rd_rsp_data;
    reg  [3:0]   ps_wr_valid;
    reg  [43:0]  ps_wr_addr;
    reg  [255:0] ps_wr_data;

    reg  running;                    // retry manager owns the core
    reg  mode_r;                     // verify_v1: 1 = VERIFY job
    reg  launch_p;
    wire [511:0] seed_rhoprime = 512'd0;            // phase 2: host rho'' path removed
    reg  [255:0] public_rho;
    // phase 4 PIN gate signals (declared early: used by the scratchpad port muxes)
    reg  pin_job, pin_post, pg_start_pre, pg_start_post, pg_wr, pg_commit;
    reg  [2:0] pg_wr_idx; reg [31:0] pg_wr_data;
    reg  [3:0] pin_verdict; reg pin_vvalid, pin_vchk, pin_vfp, pin_vct;
    wire pg_busy, pg_done, pg_fail, pg_pin_valid, pg_wv, pg_fp_match, pg_ct_match;
    wire [255:0] pg_pin_value, pg_fp; wire [15:0] pg_viol; wire [31:0] pg_pre_cycles;
    wire [3:0] pg_rd_valid, pg_rsp_ready; wire [43:0] pg_rd_addr;
    wire [3:0] pg_wr_valid; wire [43:0] pg_wr_addr; wire [255:0] pg_wr_data2; wire pg_len_fail;
    reg  [11:0] msg_len_r;

    wire tf_req, tf_done, tf_fail; wire [3:0] tf_wr_valid; wire [43:0] tf_wr_addr; wire [255:0] tf_wr_data;
    wire [3:0] tf_code, tf_redraws; wire [5:0] tf_maxrun; wire [10:0] tf_apt;
    wire [3:0]   h_wr_req_valid = running ? (tf_req ? tf_wr_valid : mgr_wr_valid) : (pg_busy ? pg_wr_valid : ps_wr_valid);
    wire [43:0]  h_wr_req_addr  = running ? (tf_req ? tf_wr_addr  : mgr_wr_addr)  : (pg_busy ? pg_wr_addr  : ps_wr_addr);
    wire [255:0] h_wr_req_data  = running ? (tf_req ? tf_wr_data  : mgr_wr_data)  : (pg_busy ? pg_wr_data2 : ps_wr_data);
    wire mgr_pro_mode;
    seal_trng_fill #(.DET_RND(DET_RND)) u_trng_fill (
        .clk(aclk), .rst_n(aresetn), .req(tf_req), .done(tf_done), .fail(tf_fail), .claim(trng_claim),
        .trng_word(trng_word), .trng_valid(trng_valid), .trng_hw_fail(trng_health_fail),
        .wr_valid(tf_wr_valid), .wr_ready(h_wr_req_ready), .wr_addr(tf_wr_addr), .wr_data(tf_wr_data),
        .fail_code(tf_code), .redraws(tf_redraws), .max_run(tf_maxrun), .apt_worst(tf_apt));
    wire         host_mode      = running ? mgr_host_mode : 1'b1;

    // ------------------------------------------------------------ phase 4: pk pin gate
    localparam [1:0] PIN_MODE2 = (PIN_MODE == 2) ? 2'd2 : ((PIN_MODE == 1) ? 2'd1 : 2'd0);
    generate if (PIN_MODE != 0) begin : g_pin
        wpin_gate #(.PIN_MODE(PIN_MODE), .PIN_CONST(PIN_CONST), .MU_PL(MU_PL), .TR_CONST(TR_CONST)) u_pin (
            .clk(aclk), .rst_n(aresetn),
            .pin_wr(pg_wr), .pin_wr_idx(pg_wr_idx), .pin_wr_data(pg_wr_data), .pin_commit(pg_commit),
            .pin_valid(pg_pin_valid), .pin_value(pg_pin_value), .pin_wv(pg_wv), .pin_viol_cnt(pg_viol),
            .start_pre(pg_start_pre), .start_post(pg_start_post), .busy(pg_busy), .done(pg_done), .fail(pg_fail),
            .fp(pg_fp), .fp_match(pg_fp_match), .ct_match(pg_ct_match), .pre_cycles(pg_pre_cycles),
            .rd_req_valid(pg_rd_valid), .rd_req_ready(h_rd_req_ready), .rd_req_addr(pg_rd_addr),
            .rd_rsp_valid(h_rd_rsp_valid), .rd_rsp_ready(pg_rsp_ready), .rd_rsp_data(h_rd_rsp_data),
            .msg_len(msg_len_r), .len_fail(pg_len_fail), .wr_valid(pg_wr_valid), .wr_ready(h_wr_req_ready),
            .wr_addr(pg_wr_addr), .wr_data(pg_wr_data2));
    end else begin : g_nopin
        assign pg_pin_valid = 1'b0; assign pg_pin_value = 256'd0; assign pg_wv = 1'b0; assign pg_viol = 16'd0;
        assign pg_busy = 1'b0; assign pg_done = 1'b0; assign pg_fail = 1'b0; assign pg_fp = 256'd0;
        assign pg_fp_match = 1'b0; assign pg_ct_match = 1'b0; assign pg_pre_cycles = 32'd0;
        assign pg_rd_valid = 4'd0; assign pg_rd_addr = 44'd0; assign pg_rsp_ready = 4'd0;
        assign pg_wr_valid = 4'd0; assign pg_wr_addr = 44'd0; assign pg_wr_data2 = 256'd0; assign pg_len_fail = 1'b0;
    end endgenerate

    wcore_stage19_real_ntt_dot4_intt u_core (
        .clk(aclk), .por_n(aresetn), .rst_n(aresetn),
        .start_job(start_job), .job_ack(job_ack), .soft_reset_req(1'b0), .verify_mode(mode_r),
        .job_busy(job_busy), .job_done(job_done), .job_error(job_error),
        .job_irq(job_irq), .error_code(error_code), .pc_status(pc_status),
        .kappa_status(kappa_status), .attempt_status(attempt_status),
        .reject_status(reject_status), .adapter_recovery_required(adapter_recovery_required),
        .route_enable(route_enable), .route_lane(route_lane),
        .router_writes(router_writes), .ntt_starts(ntt_starts), .intt_starts(intt_starts),
        .host_mode(host_mode),
        .h_rd_req_valid(pg_busy ? pg_rd_valid : h_rd_req_valid), .h_rd_req_ready(h_rd_req_ready),
        .h_rd_req_addr(pg_busy ? pg_rd_addr : h_rd_req_addr), .h_rd_rsp_valid(h_rd_rsp_valid),
        .h_rd_rsp_ready(pg_busy ? pg_rsp_ready : h_rd_rsp_ready), .h_rd_rsp_data(h_rd_rsp_data),
        .h_wr_req_valid(h_wr_req_valid), .h_wr_req_ready(h_wr_req_ready),
        .h_wr_req_addr(h_wr_req_addr), .h_wr_req_data(h_wr_req_data),
        .sp_init_done(sp_init_done), .sp_busy(sp_busy), .sp_locked(sp_locked),
        .ext_scrub_req(ext_scrub), .sp_scrub_done(sp_scrub_done),
        .pro_mode(mgr_pro_mode), .pro_det(DET_RND != 0)
    );

    v7_registered_retry_manager #(.MAX_ATTEMPTS(MAX_ATTEMPTS)) u_retry (
        .clk(aclk), .rst_n(aresetn), .launch(launch_p), .verify_mode(mode_r),
        .seed_rhoprime(seed_rhoprime), .public_rho(public_rho), .prep_first(seal_lock), .pl_rho(1'b1),
        .trng_req(tf_req), .trng_done(tf_done), .trng_fail(tf_fail), .pro_mode(mgr_pro_mode),
        .job_done(job_done), .job_error(job_error), .job_busy(job_busy),
        .reject_status(reject_status), .pc_status(pc_status),
        .sp_busy(sp_busy), .sp_locked(sp_locked), .wr_ready(h_wr_req_ready),
        .start_job(start_job), .job_ack(job_ack), .host_mode(mgr_host_mode),
        .wr_valid(mgr_wr_valid), .wr_addr(mgr_wr_addr), .wr_data(mgr_wr_data),
        .done(mgr_done), .success(mgr_success), .kappa(mgr_kappa),
        .attempts(mgr_attempts), .error_code(mgr_error)
    );

    // ------------------------------------------------------------ status regs
    reg done_r, success_r, irq_r;
    reg [15:0] kappa_r, attempts_r; reg [7:0] rerr_r, cerr_r, pc_r;
    reg [31:0] cycles, cycles_r;
    reg mgr_done_q;
    assign irq = irq_r;

    // ------------------------------------------------------------ AXI-Lite FSM
    localparam [3:0] A_IDLE=0, A_WAITW=1, A_WR_SP=2, A_WR_RESP=3, A_RD_REQ=4,
                     A_RD_RSP=5, A_RD_RESP=6;
    reg [3:0] ast;
    reg [C_ADDR_W-1:0] waddr, raddr;
    reg aw_got, w_got;
    reg [31:0] wdata_q; reg [3:0] wstrb_q;
    reg [31:0] wlo [0:3];             // pending low halves per bank
    reg [1:0]  bsel;
    reg        hsel;
    reg [15:0] wdog;

    wire w_is_sp  = (waddr[16] == 1'b0);
    wire r_is_sp  = (raddr[16] == 1'b0);
    wire [7:0] w_reg = waddr[7:0];
    wire [7:0] r_reg = raddr[7:0];
    wire w_reg_ok = waddr[15:8] == 8'd0;
    wire r_reg_ok = raddr[15:8] == 8'd0;
    wire eng_busy = running || zeroizing || pscrub || pin_job;
    // seal_v8 whitelists (bank = addr[15:14], word = addr[13:3])
    wire [1:0]  wbk = waddr[15:14]; wire [10:0] wwd = waddr[13:3];
    wire [1:0]  rbk = raddr[15:14]; wire [10:0] rwd = raddr[13:3];
    wire w_win_ok = (wbk == 2'd2 && wwd >= 11'd1048 && wwd <= 11'd1055) ||
                    (wbk == 2'd2 && wwd >= 11'd512  && wwd <= 11'd515)  ||
                    (wbk == 2'd1 && wwd >= 11'd1150 && wwd <= 11'd1153) ||
                    (wbk == 2'd3 && (wwd <= 11'd1023 || wwd >= 11'd1536)) ||
                    (MU_PL != 0 && PIN_MODE != 0 && wbk == 2'd2 && wwd >= 11'd1304 && wwd <= 11'd1535);   // phase 4 M'
    wire r_win_ok = (sign_out_ok && ((rbk == 2'd1 && rwd <= 11'd511) ||
                                     (rbk == 2'd1 && rwd >= 11'd1150 && rwd <= 11'd1153) ||
                                     (rbk == 2'd3 && rwd >= 11'd1400 && rwd <= 11'd1911))) ||
                    (verify_out_ok && rbk == 2'd1 && rwd >= 11'd1150 && rwd <= 11'd1153);
    wire w_sealed = seal_lock && !w_win_ok;
    // post-SIGN scrub keep map for word ps_a (bank-parallel)
    wire ps_k1 = (ps_a >= 11'd512 && ps_a <= 11'd1023) || (ps_a >= 11'd1536) ||
                 (pscrub_ok && (ps_a <= 11'd511 || (ps_a >= 11'd1150 && ps_a <= 11'd1153)));
    wire ps_k2 = (ps_a >= 11'd1536) || (ps_a >= 11'd1040 && ps_a <= 11'd1043);   // t0_hat, K
    wire ps_k3 = pscrub_ok && ps_a >= 11'd1400 && ps_a <= 11'd1911;
    wire [3:0] ps_zero = {!ps_k3, !ps_k2, !ps_k1, 1'b0};
    wire r_sealed = seal_lock && !r_win_ok;

    function [31:0] reg_read(input [7:0] a);
        begin
            reg_read = 32'd0;
            case (a)
                8'h04: reg_read = {17'd0, verify_out_ok, sign_out_ok, zeroizing, (seal_rv | seal_wv), seal_lock,
                                   mode_r, irq_r, adapter_recovery_required, job_error, sp_locked,
                                   sp_busy, sp_init_done, success_r, done_r, (running | pin_job)};
                8'h08: reg_read = {attempts_r, kappa_r};
                8'h0C: reg_read = {8'd0, pc_r, cerr_r, rerr_r};
                8'h10: reg_read = cycles_r;
                8'h14: reg_read = 32'h5743_5331;
                8'h18: reg_read = 32'h0003_0002;
                8'h20: reg_read = {6'd0, (DET_RND != 0), tf_code, tf_redraws, tf_maxrun, tf_apt};
                8'h1C: reg_read = {viol_cnt, 12'd0, zeroizing, seal_wv, seal_rv, seal_lock};
                default: begin
                    if (a >= 8'h40 && a <= 8'h7C) reg_read = 32'd0;           // seal_v8: secret, never readable
                    else if (a >= 8'h80 && a <= 8'h9C) reg_read = public_rho[(a-8'h80)*8 +: 32];
                    else if (PIN_MODE != 0 && a >= 8'hA0 && a <= 8'hBC) reg_read = pg_pin_value[(a-8'hA0)*8 +: 32];
                    else if (PIN_MODE != 0 && a == 8'hC0)
                        reg_read = {pg_viol, 4'd0, pin_verdict, (PIN_MODE == 2 && PIN_CONST == 256'd0), (MU_PL != 0), PIN_MODE2, (PIN_ALLOW_UNSET != 0), pg_wv,
                                    (PIN_MODE == 2), pg_pin_valid};
                    else if (PIN_MODE != 0 && a == 8'hC4) reg_read = {24'd0, pin_vct, pin_vfp, pin_vchk, pin_vvalid, pin_verdict};
                    else if (PIN_MODE != 0 && a == 8'hC8) reg_read = pg_pre_cycles;
                    else if (PIN_MODE != 0 && a >= 8'hD0 && a <= 8'hEC) reg_read = pg_fp[(a-8'hD0)*8 +: 32];
                    else if (PIN_MODE != 0 && a == 8'hF0) reg_read = {20'd0, msg_len_r};
                end
            endcase
        end
    endfunction

    integer k;
    always @(posedge aclk) begin
        if (!aresetn) begin
            ast <= A_IDLE; aw_got <= 0; w_got <= 0;
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0; s_axi_bresp <= 0;
            s_axi_arready <= 0; s_axi_rvalid <= 0; s_axi_rresp <= 0; s_axi_rdata <= 0;
            h_rd_req_valid <= 0; h_rd_rsp_ready <= 0; h_rd_req_addr <= 0;
            ps_wr_valid <= 0; ps_wr_addr <= 0; ps_wr_data <= 0;
            running <= 0; launch_p <= 0; public_rho <= 0; mode_r <= 0;
            done_r <= 0; success_r <= 0; irq_r <= 0; kappa_r <= 0; attempts_r <= 0;
            rerr_r <= 0; cerr_r <= 0; pc_r <= 0; cycles <= 0; cycles_r <= 0; mgr_done_q <= 0;
            ext_scrub <= 0; zeroizing <= 0; seal_lock <= 0; seal_rv <= 0; seal_wv <= 0;
            sign_out_ok <= 0; verify_out_ok <= 0; viol_cnt <= 0;
            pscrub <= 0; pscrub_ok <= 0; ps_ph <= 0; ps_a <= 0; ps_pend <= 0; ps_wdog <= 0;
            for (k = 0; k < 4; k = k + 1) wlo[k] <= 32'd0;
            pin_job <= 0; pin_post <= 0; pg_start_pre <= 0; pg_start_post <= 0; pg_wr <= 0; pg_commit <= 0;
            pg_wr_idx <= 0; pg_wr_data <= 0; msg_len_r <= 12'd0; pin_verdict <= 0; pin_vvalid <= 0; pin_vchk <= 0; pin_vfp <= 0; pin_vct <= 0;
            waddr <= 0; raddr <= 0; wdata_q <= 0; wstrb_q <= 0; bsel <= 0; hsel <= 0; wdog <= 0;
        end else begin
            launch_p   <= 1'b0;
            ext_scrub  <= 1'b0;
            mgr_done_q <= mgr_done;
            pg_start_pre <= 1'b0; pg_start_post <= 1'b0; pg_wr <= 1'b0; pg_commit <= 1'b0;
            if (pscrub) begin                                   // post-SIGN residue scrub (bank-parallel)
                ps_wdog <= ps_wdog + 1'b1;
                if (!ps_ph) begin                                // ISSUE word ps_a
                    ps_wr_valid <= ps_zero; ps_pend <= ps_zero;
                    ps_wr_addr  <= {4{ps_a}}; ps_wr_data <= 256'd0;
                    ps_ph <= 1'b1;
                end else begin                                   // WAIT for every addressed bank
                    ps_pend     <= ps_pend & ~h_wr_req_ready;
                    ps_wr_valid <= ps_wr_valid & ~h_wr_req_ready;
                    if ((ps_pend & ~h_wr_req_ready) == 4'd0) begin
                        ps_ph <= 1'b0;
                        if (ps_a == 11'd2047) begin pscrub <= 1'b0; done_r <= 1'b1; irq_r <= 1'b1; end
                        else ps_a <= ps_a + 1'b1;
                    end
                end
                if (&ps_wdog) begin                              // fail closed: nothing is released
                    pscrub <= 1'b0; done_r <= 1'b1; irq_r <= 1'b1; ps_wr_valid <= 4'd0; ps_pend <= 4'd0;
                    success_r <= 1'b0; sign_out_ok <= 1'b0; rerr_r <= 8'hE0;
                end
            end
            if (zeroizing && sp_scrub_done) begin                // ZEROIZE complete: all banks scrubbed
                zeroizing <= 1'b0; seal_lock <= 1'b0; seal_rv <= 1'b0; seal_wv <= 1'b0; viol_cnt <= 16'd0;
            end
            if (running || pin_job) cycles <= cycles + 1'b1;
            if (running && mgr_done && !mgr_done_q) begin       // job finished
                running    <= 1'b0;
                done_r     <= !(seal_lock && !mode_r);           // LOCKED SIGN: DONE after the residue scrub
                irq_r      <= !(seal_lock && !mode_r);
                if (seal_lock && !mode_r) begin
                    pscrub <= 1'b1; pscrub_ok <= mgr_success; ps_ph <= 1'b0; ps_a <= 11'd0; ps_pend <= 4'd0; ps_wdog <= 16'd0;
                end
                success_r  <= mgr_success;
                kappa_r    <= mgr_kappa;
                attempts_r <= mgr_attempts;
                rerr_r     <= mgr_error;
                cerr_r     <= error_code;
                pc_r       <= pc_status;
                cycles_r   <= cycles;
                sign_out_ok   <= !mode_r && mgr_success;
                verify_out_ok <=  mode_r && mgr_success;
                if (pin_job) begin                              // phase 4: verdict decided in PL after c~' compare
                    done_r <= 1'b0; irq_r <= 1'b0;
                    if (mgr_success) begin pg_start_post <= 1'b1; pin_post <= 1'b1; end
                    else begin
                        pin_job <= 1'b0; done_r <= 1'b1; irq_r <= 1'b1; pin_vvalid <= 1'b1;
                        pin_verdict <= (mgr_error == 8'h06) ? 4'd3 : 4'd6;
                    end
                end
            end
            if (pin_job && pg_done && !pin_post) begin          // phase 4: pk image hashed, c~ latched
                pin_vchk <= pg_pin_valid; pin_vfp <= pg_fp_match;
                if (!pg_fail && !pg_len_fail && (pg_fp_match || (!pg_pin_valid && PIN_ALLOW_UNSET != 0))) begin
                    running <= 1'b1; launch_p <= 1'b1;
                end else begin                                  // fail closed: core never runs
                    pin_job <= 1'b0; done_r <= 1'b1; irq_r <= 1'b1; success_r <= 1'b0;
                    sign_out_ok <= 1'b0; verify_out_ok <= 1'b0; kappa_r <= 16'd0; attempts_r <= 16'd0;
                    cerr_r <= 8'd0; pc_r <= 8'd0; cycles_r <= cycles; pin_vvalid <= 1'b1;
                    rerr_r      <= pg_fail ? 8'hD6 : (pg_len_fail ? 8'hD7 : (pg_pin_valid ? 8'hD4 : 8'hD5));
                    pin_verdict <= pg_fail ? 4'd6  : (pg_len_fail ? 4'd8  : (pg_pin_valid ? 4'd4  : 4'd5));
                end
            end
            if (pin_job && pg_done && pin_post) begin           // phase 4: PL c~' == c~ compare done
                pin_job <= 1'b0; pin_post <= 1'b0; done_r <= 1'b1; irq_r <= 1'b1; cycles_r <= cycles;
                pin_vvalid <= 1'b1; pin_vct <= pg_ct_match && !pg_fail;
                pin_verdict <= pg_fail ? 4'd6 : (!pg_ct_match ? 4'd2 : (pin_vchk ? 4'd1 : 4'd7));
            end

            case (ast)
                A_IDLE: begin
                    s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_arready <= 1'b0;
                    if (s_axi_awvalid || s_axi_wvalid) begin
                        if (s_axi_awvalid && !aw_got) begin
                            waddr <= s_axi_awaddr; aw_got <= 1'b1; s_axi_awready <= 1'b1;
                        end
                        if (s_axi_wvalid && !w_got) begin
                            wdata_q <= s_axi_wdata; wstrb_q <= s_axi_wstrb; w_got <= 1'b1;
                            s_axi_wready <= 1'b1;
                        end
                        ast <= A_WAITW;
                    end else if (s_axi_arvalid) begin
                        raddr <= s_axi_araddr; s_axi_arready <= 1'b1;
                        ast <= A_RD_REQ;
                    end
                end

                A_WAITW: begin
                    s_axi_awready <= 1'b0; s_axi_wready <= 1'b0;
                    if (s_axi_awvalid && !aw_got && !s_axi_awready) begin
                        waddr <= s_axi_awaddr; aw_got <= 1'b1; s_axi_awready <= 1'b1;
                    end
                    if (s_axi_wvalid && !w_got && !s_axi_wready) begin
                        wdata_q <= s_axi_wdata; wstrb_q <= s_axi_wstrb; w_got <= 1'b1;
                        s_axi_wready <= 1'b1;
                    end
                    if (aw_got && w_got) begin
                        aw_got <= 1'b0; w_got <= 1'b0;
                        s_axi_bresp <= 2'b00;
                        if (w_is_sp) begin
                            if (eng_busy || wstrb_q != 4'hF) begin
                                s_axi_bresp <= 2'b10; ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                            end else if (w_sealed) begin            // seal_v8: dropped, flagged
                                seal_wv <= 1'b1; if (~&viol_cnt) viol_cnt <= viol_cnt + 1'b1;
                                ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                            end else if (!waddr[2]) begin
                                wlo[waddr[15:14]] <= wdata_q;
                                ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                            end else begin
                                bsel <= waddr[15:14];
                                ps_wr_valid <= 4'b0001 << waddr[15:14];
                                ps_wr_addr  <= {4{waddr[13:3]}};
                                ps_wr_data  <= {4{wdata_q, wlo[waddr[15:14]]}};
                                wdog <= 16'hFFFF;
                                ast <= A_WR_SP;
                            end
                        end else begin
                            if (!w_reg_ok) s_axi_bresp <= 2'b10;
                            else case (w_reg)
                                8'h00: begin
                                    if (wdata_q[0] && !eng_busy && sp_init_done && !sp_locked) begin
                                        if (PIN_MODE != 0 && wdata_q[2]) begin   // phase 4: hash pk image first
                                            pin_job <= 1'b1; pin_post <= 1'b0; pg_start_pre <= 1'b1;
                                        end else begin running <= 1'b1; launch_p <= 1'b1; end
                                        pin_vvalid <= 1'b0; pin_vchk <= 1'b0; pin_vfp <= 1'b0; pin_vct <= 1'b0; pin_verdict <= 4'd0;
                                        done_r <= 1'b0; mode_r <= wdata_q[2];
                                        if (!wdata_q[2]) seal_lock <= 1'b1;    // any SIGN seals the key region
                                        success_r <= 1'b0; irq_r <= 1'b0; cycles <= 32'd0;
                                        sign_out_ok <= 1'b0; verify_out_ok <= 1'b0;
                                    end else if (wdata_q[0]) s_axi_bresp <= 2'b10;
                                    if (wdata_q[1]) irq_r <= 1'b0;
                                    if (wdata_q[3] && !eng_busy && sp_init_done) seal_lock <= 1'b1;
                                    if (wdata_q[4] && !running && !zeroizing && !pin_job) begin
                                        zeroizing <= 1'b1; ext_scrub <= 1'b1;
                                        sign_out_ok <= 1'b0; verify_out_ok <= 1'b0;
                                        public_rho <= 256'd0;
                                        for (k = 0; k < 4; k = k + 1) wlo[k] <= 32'd0;
                                    end
                                end
                                default: begin
                                    if (w_reg >= 8'h40 && w_reg <= 8'h7C) begin   // phase 2: no host rho''
                                        if (running) s_axi_bresp <= 2'b10;
                                        else if (seal_lock) begin seal_wv <= 1'b1; if (~&viol_cnt) viol_cnt <= viol_cnt + 1'b1; end
                                    end else if (w_reg >= 8'h80 && w_reg <= 8'h9C && !running && seal_lock) begin
                                        seal_wv <= 1'b1; if (~&viol_cnt) viol_cnt <= viol_cnt + 1'b1;
                                    end else if (w_reg >= 8'h80 && w_reg <= 8'h9C && !running)
                                        public_rho[(w_reg-8'h80)*8 +: 32] <= wdata_q;
                                    else if (PIN_MODE != 0 && ((w_reg >= 8'hA0 && w_reg <= 8'hBC) || w_reg == 8'hC0 || w_reg == 8'hF0)) begin
                                        if (eng_busy) s_axi_bresp <= 2'b10;            // phase 4 pin register
                                        else if (w_reg == 8'hF0) msg_len_r <= wdata_q[11:0];
                                        else if (w_reg == 8'hC0) pg_commit <= wdata_q[0];
                                        else begin pg_wr <= 1'b1; pg_wr_idx <= w_reg[4:2]; pg_wr_data <= wdata_q; end
                                    end
                                    else s_axi_bresp <= 2'b10;
                                end
                            endcase
                            ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                        end
                    end
                end

                A_WR_SP: begin
                    if (|(ps_wr_valid & h_wr_req_ready)) begin
                        ps_wr_valid <= 4'b0000;
                        ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                    end else if (wdog == 0) begin
                        ps_wr_valid <= 4'b0000; s_axi_bresp <= 2'b10;
                        ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                    end else wdog <= wdog - 1'b1;
                end

                A_WR_RESP: begin
                    if (s_axi_bvalid && s_axi_bready) begin s_axi_bvalid <= 1'b0; ast <= A_IDLE; end
                end

                A_RD_REQ: begin
                    s_axi_arready <= 1'b0;
                    s_axi_rresp <= 2'b00;
                    if (r_is_sp) begin
                        if (eng_busy) begin
                            s_axi_rresp <= 2'b10; s_axi_rdata <= 32'd0;
                            s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                        end else if (r_sealed) begin                // seal_v8: 0, flagged
                            seal_rv <= 1'b1; if (~&viol_cnt) viol_cnt <= viol_cnt + 1'b1;
                            s_axi_rdata <= 32'd0; s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                        end else begin
                            bsel <= raddr[15:14]; hsel <= raddr[2];
                            h_rd_req_valid <= 4'b0001 << raddr[15:14];
                            h_rd_req_addr  <= {4{raddr[13:3]}};
                            wdog <= 16'hFFFF;
                            ast <= A_RD_RSP;
                        end
                    end else begin
                        if (!r_reg_ok) s_axi_rresp <= 2'b10;
                        s_axi_rdata  <= r_reg_ok ? reg_read(r_reg) : 32'd0;
                        s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                    end
                end

                A_RD_RSP: begin
                    if (|(h_rd_req_valid & h_rd_req_ready)) begin
                        h_rd_req_valid <= 4'b0000;
                        h_rd_rsp_ready <= 4'b0001 << bsel;
                    end
                    if (|(h_rd_rsp_ready & h_rd_rsp_valid)) begin
                        h_rd_rsp_ready <= 4'b0000;
                        s_axi_rdata  <= hsel ? h_rd_rsp_data[bsel*64+32 +: 32] : h_rd_rsp_data[bsel*64 +: 32];
                        s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                    end else if (wdog == 0) begin
                        h_rd_req_valid <= 4'b0000; h_rd_rsp_ready <= 4'b0000;
                        s_axi_rresp <= 2'b10; s_axi_rdata <= 32'd0;
                        s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                    end else wdog <= wdog - 1'b1;
                end

                A_RD_RESP: begin
                    if (s_axi_rvalid && s_axi_rready) begin s_axi_rvalid <= 1'b0; ast <= A_IDLE; end
                end

                default: ast <= A_IDLE;
            endcase
        end
    end
endmodule
