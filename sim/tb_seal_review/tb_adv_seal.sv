`timescale 1ns/1ps
// ============================================================================
// REVIEWER adversarial testbench for WEPWAWET-CORE seal_v8 (independent of the BUILDER's tests).
// The host is modelled as a hostile root process with full AXI4-Lite access to the signer window.
// The TB only *observes* the DUT internals (scratchpad write port, retry manager) to log what the
// PL computed; every check of what the host can see goes through the AXI-Lite slave.
// Output files (capture/):
//   trace_sp_writes.txt  : every internal scratchpad write while an engine owns the SP
//                          "W <phase> <cycle> <pc> <kappa> <bank> <word> <data64>"
//   sweep_<tag>.txt      : full host sweep "R <addr17_hex> <rdata32_hex> <rresp>"
//   events.txt           : glitch / access-control observations "E <name> key=value ..."
// Defines: ADV_V8 (seal_v8 register map), ADV_MAXATT (retry bound, default 255),
//          ADV_MIDRESET_CYCLES (cycles into the 2nd sign before reset, default 120000).
// Pass/fail decisions are made offline by review/tools/adv_check.py.
// ============================================================================
`ifndef ADV_MAXATT
 `define ADV_MAXATT 255
`endif
`ifndef ADV_MIDRESET_CYCLES
 `define ADV_MIDRESET_CYCLES 120000
`endif
module tb_adv_seal;
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;
    reg aresetn = 0;
    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg  awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0; reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0] bresp, rresp; wire [31:0] rdata;

`ifdef ADV_P2
    // ---- Stage-8 TRNG stand-in (sim only): $urandom word every 520 cycles (Stage-8 rate); +TRNG_STUCK=1 -> constant word
    //      (must trip the PL RCT/APT health tests and fail the SIGN closed); +TRNG_HWFAIL=1 -> hw health flag high.
    wire trng_claim; reg [31:0] trng_word = 32'h1234_5679; reg trng_valid = 0; reg trng_hwf = 0;
    integer trng_stuck = 0, trng_hwfail = 0, tcnt = 0, trng_words_seen = 0;
    always @(posedge aclk) begin
        tcnt <= tcnt + 1; trng_valid <= 1'b0; trng_hwf <= (trng_hwfail != 0);
        if (tcnt % 520 == 0) begin   // ~ Stage-8 rate: 32 bits x SAMPLE_DIV 16
            trng_valid <= 1'b1;
            if (trng_stuck == 0) trng_word <= $urandom;
            if (trng_claim) trng_words_seen <= trng_words_seen + 1;
        end
    end
    always @(posedge aclk) if (trng_claim && trng_valid) $fdisplay(tfd, "T %0d %0d %08h", phase, cyc_ctr, trng_word);
`endif
    wepwawet_sign_axil #(.MAX_ATTEMPTS(`ADV_MAXATT)
`ifdef ADV_DET
        , .DET_RND(1)
`endif
`ifdef ADV_KATXI
        , .KAT_XI(1)
`endif
    ) dut (
`ifdef ADV_P2
        .trng_claim(trng_claim), .trng_word(trng_word), .trng_valid(trng_valid), .trng_health_fail(trng_hwf),
`endif
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .irq(irq));

    // ------------------------------------------------------------------ files
    integer tfd, efd, sfd, cyc_ctr = 0, phase = 0;
    always @(posedge aclk) cyc_ctr <= cyc_ctr + 1;

    // ---------------------------------------------- internal observation (read-only)
    // Log every scratchpad write that is NOT a host write (engine-owned SP: AUX, AXIS, retry manager).
    wire [3:0]   o_wv = dut.u_core.u_wcore.sp_wr_req_valid & dut.u_core.u_wcore.sp_wr_req_ready;
    wire [43:0]  o_wa = dut.u_core.u_wcore.sp_wr_req_addr;
    wire [255:0] o_wd = dut.u_core.u_wcore.sp_wr_req_data;
    wire         o_host = dut.u_core.u_wcore.allow_host;
    integer b;
    always @(posedge aclk) if (aresetn && dut.running) begin
        for (b = 0; b < 4; b = b + 1)
            if (o_wv[b])
                $fdisplay(tfd, "W %0d %0d %0d %0d %0d %0d %016h %0d", phase, cyc_ctr,
                          dut.u_core.pc_status, dut.u_retry.kappa, b, o_wa[b*11 +: 11], o_wd[b*64 +: 64], o_host);
    end

    // ------------------------------------------------------------------ AXI
    integer nwr = 0, nrd = 0;
    reg [1:0] last_resp; reg [31:0] last_rdata;
    task automatic axi_wr(input [AW-1:0] a, input [31:0] d);
        integer t; begin
            @(negedge aclk); awaddr = a; wdata = d; awvalid = 1; wvalid = 1; bready = 1; t = 0;
            while ((awvalid || wvalid) && t < 2000) begin
                @(posedge aclk); #0.01;
                if (awvalid && awready) awvalid = 0;
                if (wvalid && wready) wvalid = 0;
                t = t + 1;
            end
            t = 0; while (!bvalid && t < 200000) begin @(posedge aclk); #0.01; t = t + 1; end
            if (!bvalid) begin $fdisplay(efd, "E AXI_WRITE_HANG a=%05h", a); $fatal(1, "AXI_WRITE_HANG a=%h", a); end
            last_resp = bresp;
            @(posedge aclk); #0.01; bready = 0; nwr = nwr + 1;
        end endtask
    task automatic axi_rd(input [AW-1:0] a, output [31:0] d);
        integer t; begin
            @(negedge aclk); araddr = a; arvalid = 1; rready = 1; t = 0;
            while (arvalid && t < 2000) begin @(posedge aclk); #0.01; if (arready) arvalid = 0; t = t + 1; end
            t = 0; while (!rvalid && t < 200000) begin @(posedge aclk); #0.01; t = t + 1; end
            if (!rvalid) begin $fdisplay(efd, "E AXI_READ_HANG a=%05h", a); $fatal(1, "AXI_READ_HANG a=%h", a); end
            d = rdata; last_resp = rresp; last_rdata = rdata;
            @(posedge aclk); #0.01; rready = 0; nrd = nrd + 1;
        end endtask
    function [AW-1:0] spa(input integer bank, input integer word, input integer hi);
        spa = (bank << 14) | (word << 3) | (hi << 2); endfunction
    task automatic sp_write64(input integer bank, input integer word, input [63:0] v);
        begin axi_wr(spa(bank, word, 0), v[31:0]); axi_wr(spa(bank, word, 1), v[63:32]); end endtask
    task automatic sp_read64(input integer bank, input integer word, output [63:0] v);
        reg [31:0] lo, hi; begin axi_rd(spa(bank, word, 0), lo); axi_rd(spa(bank, word, 1), hi); v = {hi, lo}; end endtask

    // full host sweep of the 17-bit window: 4 banks x 2048 words x 2 halves + register page 0x1_0000..0x1_01FC
    integer sweep_mask = 32'hFFFF_FFFF, stop_after = 99;
    task automatic sweep(input [8*24-1:0] tag);
        integer bk, wd, hf, r; reg [31:0] d; reg [8*64-1:0] fn; begin
            if (sweep_mask[phase] == 1'b0) begin $display("ADV_SWEEP_SKIPPED phase=%0d", phase); end else begin
            $sformat(fn, "capture/sweep_%0s.txt", tag);
            sfd = $fopen(fn, "w");
            for (bk = 0; bk < 4; bk = bk + 1)
                for (wd = 0; wd < 2048; wd = wd + 1)
                    for (hf = 0; hf < 2; hf = hf + 1) begin
                        axi_rd(spa(bk, wd, hf), d);
                        $fdisplay(sfd, "R %05h %08h %0d", spa(bk, wd, hf), d, last_resp);
                    end
            for (r = 0; r < 128; r = r + 1) begin
                axi_rd(17'h1_0000 + 4*r, d);
                $fdisplay(sfd, "R %05h %08h %0d", 17'h1_0000 + 4*r, d, last_resp);
            end
            $fclose(sfd);
            $display("ADV_SWEEP_DONE tag=%0s reads=%0d", tag, nrd);
            end
        end endtask
    task automatic maybe_stop;
        begin
            if (phase >= stop_after) begin
                $fdisplay(efd, "E STOPPED_AFTER phase=%0d axi_writes=%0d axi_reads=%0d", phase, nwr, nrd);
                $fclose(tfd); $fclose(efd); $display("ADV_TB_STOPPED phase=%0d", phase); $finish;
            end
        end endtask

    // read-only backdoor dump of the scratchpad arrays (internal truth, not host-visible)
    task automatic backdoor(input [8*24-1:0] tag);
        integer wd, bfd; reg [8*64-1:0] fn; begin
            $sformat(fn, "capture/backdoor_%0s.txt", tag);
            bfd = $fopen(fn, "w");
            for (wd = 0; wd < 2048; wd = wd + 1) begin
                $fdisplay(bfd, "B 0 %0d %016h", wd, dut.u_core.u_wcore.u_sp.BANK[0].mem[wd]);
                $fdisplay(bfd, "B 1 %0d %016h", wd, dut.u_core.u_wcore.u_sp.BANK[1].mem[wd]);
                $fdisplay(bfd, "B 2 %0d %016h", wd, dut.u_core.u_wcore.u_sp.BANK[2].mem[wd]);
                $fdisplay(bfd, "B 3 %0d %016h", wd, dut.u_core.u_wcore.u_sp.BANK[3].mem[wd]);
            end
            $fclose(bfd);
        end endtask
    task automatic wait_init;
        integer t; reg [31:0] st; begin
            t = 0; do begin axi_rd(17'h1_0004, st); t = t + 1; end while (!(st[3] && !st[4]) && t < 20000);
            if (!(st[3] && !st[4])) $fatal(1, "SCRATCHPAD_INIT_TIMEOUT st=%h", st);
        end endtask
    task automatic wait_done(output [31:0] st);
        integer t; begin
            t = 0;
            do begin repeat (2000) @(posedge aclk); axi_rd(17'h1_0004, st); t = t + 1;
                if (t % 250 == 0) begin $display("ADV_WAIT phase=%0d polls=%0d st=%08h pc=%0d kappa=%0d", phase, t, st, dut.u_core.pc_status, dut.u_retry.kappa); $fflush(); end
            end while (!st[1] && t < 40000);
            if (!st[1]) begin $fdisplay(efd, "E JOB_TIMEOUT phase=%0d st=%08h pc=%0d", phase, st, dut.u_core.pc_status); $fflush(efd); $fatal(1, "JOB_TIMEOUT st=%h", st); end
        end endtask
    task automatic log_regs(input [8*24-1:0] tag);
        reg [31:0] st, kap, errs, cyc, seal; begin
            axi_rd(17'h1_0004, st); axi_rd(17'h1_0008, kap); axi_rd(17'h1_000C, errs); axi_rd(17'h1_0010, cyc);
            axi_rd(17'h1_001C, seal);
`ifdef ADV_P2
            begin reg [31:0] tr; axi_rd(17'h1_0020, tr); $fdisplay(efd, "E TRNGREG tag=%0s trng=%08h words_seen=%0d", tag, tr, trng_words_seen); end
`endif
            $fdisplay(efd, "E REGS tag=%0s status=%08h kappa_att=%08h errors=%08h cycles=%0d seal=%08h", tag, st, kap, errs, cyc, seal);
            $fflush(efd);
            $display("ADV_REGS tag=%0s status=%08h kappa_att=%08h errors=%08h cycles=%0d seal=%08h", tag, st, kap, errs, cyc, seal);
        end endtask

    // ------------------------------------------------------------------ vectors
    reg [63:0] rho [0:3]; reg [63:0] mu [0:7]; reg [63:0] seed_nonce [0:35];
    reg [63:0] s1_hat [0:511]; reg [63:0] s2_hat [0:511]; reg [63:0] t0_hat [0:511];
    reg [63:0] vrho [0:3]; reg [63:0] vmu [0:7]; reg [63:0] vct [0:3]; reg [63:0] vctp [0:3];
    reg [63:0] vz [0:511]; reg [63:0] vh [0:511]; reg [63:0] vt1 [0:511];
    integer i, t;
    reg [31:0] st, d; reg [63:0] got;

`ifdef ADV_P2
    localparam integer MU_W = 1048;
`else
    localparam integer MU_W = 1024;
`endif
    reg [63:0] kk [0:3];
    task automatic provision;
        begin
            for (i = 0; i < 4; i = i + 1)   sp_write64(2, 512 + i, rho[i]);
            for (i = 0; i < 8; i = i + 1)   sp_write64(2, MU_W + i, mu[i]);
`ifdef ADV_P2
            for (i = 0; i < 4; i = i + 1)   sp_write64(2, 1040 + i, kk[i]);
`endif
            for (i = 0; i < 512; i = i + 1) begin
                sp_write64(1, 512 + i,  s1_hat[i]);
                sp_write64(1, 1536 + i, s2_hat[i]);
                sp_write64(2, 1536 + i, t0_hat[i]);
            end
`ifndef ADV_P2
            for (i = 0; i < 36; i = i + 1)
                sp_write64(2, i, (i % 9 == 8) ? {48'd0, 16'(i / 9)} : seed_nonce[i % 9]);
            for (i = 0; i < 8; i = i + 1) begin
                axi_wr(17'h1_0040 + 8*i, seed_nonce[i][31:0]); axi_wr(17'h1_0044 + 8*i, seed_nonce[i][63:32]);
            end
`endif
            for (i = 0; i < 4; i = i + 1) begin
                axi_wr(17'h1_0080 + 8*i, rho[i][31:0]); axi_wr(17'h1_0084 + 8*i, rho[i][63:32]);
            end
        end endtask
    task automatic rearm_seed;     // per-job rho'' (phase-1 ABI: host still supplies rho''); phase 2: hostile attempt
        begin
`ifdef ADV_P2
            axi_wr(17'h1_0040, seed_nonce[0][31:0]); $fdisplay(efd, "E LOCKED_WR_SEEDREG_P2 resp=%0d", last_resp);
`else
            for (i = 0; i < 8; i = i + 1) begin
                axi_wr(17'h1_0040 + 8*i, seed_nonce[i][31:0]); axi_wr(17'h1_0044 + 8*i, seed_nonce[i][63:32]);
            end
`endif
        end endtask

    reg [63:0] xi [0:3];
    // phase 3: PL KeyGen (CTRL bit5). With ADV_KATXI the DUT takes xi from b2[1160..1163] (sim-only build param).
    task automatic keygen(input [8*16-1:0] tag, input integer probes);
        begin
`ifdef ADV_KATXI
            for (i = 0; i < 4; i = i + 1) sp_write64(2, 1160 + i, xi[i]);
`endif
            axi_wr(17'h1_0000, 32'h20); $fdisplay(efd, "E LAUNCH_KEYGEN tag=%0s resp=%0d", tag, last_resp);
            if (probes) begin
                repeat (50) @(posedge aclk);
                busy_probes(tag);
                axi_wr(17'h1_0000, 32'h20); $fdisplay(efd, "E BUSY_RELAUNCH_KEYGEN tag=%0s resp=%0d", tag, last_resp);
            end
        end endtask
    // glitch probes while an engine is busy
    task automatic busy_probes(input [8*16-1:0] tag);
        begin
            axi_rd(spa(1, 512, 0), d);  $fdisplay(efd, "E BUSY_RD_S1 tag=%0s resp=%0d data=%08h", tag, last_resp, d);
            axi_rd(spa(3, 0, 0), d);    $fdisplay(efd, "E BUSY_RD_Y tag=%0s resp=%0d data=%08h", tag, last_resp, d);
            axi_rd(spa(3, 1400, 0), d); $fdisplay(efd, "E BUSY_RD_Z tag=%0s resp=%0d data=%08h", tag, last_resp, d);
            axi_rd(spa(2, 0, 0), d);    $fdisplay(efd, "E BUSY_RD_B2 tag=%0s resp=%0d data=%08h", tag, last_resp, d);
            for (i = 0; i < 16; i = i + 1) begin
                axi_rd(17'h1_0040 + 4*i, d); $fdisplay(efd, "E BUSY_RD_SEEDREG tag=%0s i=%0d resp=%0d data=%08h", tag, i, last_resp, d);
            end
            axi_wr(spa(2, MU_W, 0), 32'hA5A5_0001); $fdisplay(efd, "E BUSY_WR_MU_LO tag=%0s resp=%0d", tag, last_resp);
            axi_wr(spa(2, MU_W, 1), 32'hA5A5_0002); $fdisplay(efd, "E BUSY_WR_MU_HI tag=%0s resp=%0d", tag, last_resp);
            axi_wr(17'h1_0040, 32'hDEAD_BEEF);      $fdisplay(efd, "E BUSY_WR_SEEDREG tag=%0s resp=%0d", tag, last_resp);
            axi_wr(17'h1_0080, 32'hDEAD_BEEF);      $fdisplay(efd, "E BUSY_WR_RHOREG tag=%0s resp=%0d", tag, last_resp);
            axi_wr(17'h1_0000, 32'h1);              $fdisplay(efd, "E BUSY_RELAUNCH_SIGN tag=%0s resp=%0d", tag, last_resp);
            axi_wr(17'h1_0000, 32'h5);              $fdisplay(efd, "E BUSY_RELAUNCH_VERIFY tag=%0s resp=%0d", tag, last_resp);
`ifdef ADV_V8
            axi_wr(17'h1_0000, 32'h10);             $fdisplay(efd, "E BUSY_ZEROIZE tag=%0s resp=%0d", tag, last_resp);
            axi_wr(17'h1_0000, 32'h8);              $fdisplay(efd, "E BUSY_LOCK tag=%0s resp=%0d", tag, last_resp);
`endif
            axi_rd(17'h1_0004, d);                  $fdisplay(efd, "E BUSY_STATUS tag=%0s status=%08h", tag, d);
        end endtask

    initial begin
        if (!$value$plusargs("SWEEPS=%h", sweep_mask)) sweep_mask = 32'hFFFF_FFFF;
        if (!$value$plusargs("STOP=%d", stop_after)) stop_after = 99;
        tfd = $fopen("capture/trace_sp_writes.txt", "w");
        efd = $fopen("capture/events.txt", "w");
        $readmemh("vectors/rho_4x64.mem", rho);
        $readmemh("vectors/mu_8x64.mem", mu);
        $readmemh("vectors/candidate_mask_seed_nonce_36x64.mem", seed_nonce);
        $readmemh("vectors/s1_hat_512x64.mem", s1_hat);
        $readmemh("vectors/s2_hat_512x64.mem", s2_hat);
        $readmemh("vectors/t0_hat_512x64.mem", t0_hat);
`ifdef ADV_P2
        $readmemh("vectors/K_4x64.mem", kk);
        if (!$value$plusargs("TRNG_STUCK=%d", trng_stuck)) trng_stuck = 0;
        if (!$value$plusargs("TRNG_HWFAIL=%d", trng_hwfail)) trng_hwfail = 0;
        if ($test$plusargs("TRNG_ZERO")) begin trng_stuck = 1; trng_word = 32'd0; end
`endif
`ifdef ADV_P3
        $readmemh("vectors/xi_4x64.mem", xi);
`endif
        $readmemh("vvectors/rho_4x64.mem", vrho); $readmemh("vvectors/mu_8x64.mem", vmu);
        $readmemh("vvectors/ctilde_4x64.mem", vct); $readmemh("vvectors/ctilde_prime_4x64.mem", vctp);
        $readmemh("vvectors/z_512x64.mem", vz); $readmemh("vvectors/h_512x64.mem", vh);
        $readmemh("vvectors/t1hat2d_512x64.mem", vt1);
        repeat (10) @(negedge aclk); aresetn = 1;

        // ---- P0: after power-on reset nothing but zeros may be visible
        phase = 0; wait_init; sweep("p0_reset");

        maybe_stop;
        // ---- P1: provision + LOCK, then hostile access before any job
        phase = 1;
`ifdef ADV_P3
        phase = 8; keygen("kg1", 1); wait_done(st); log_regs("keygen_done"); backdoor("after_keygen");
        sweep("p8_after_keygen");
        axi_wr(17'h1_0000, 32'h20); $fdisplay(efd, "E LOCKED_RELAUNCH_KEYGEN resp=%0d", last_resp);
        repeat (200) @(posedge aclk); log_regs("after_lockedkg");
        phase = 1;
`else
        provision;
`endif
`ifdef ADV_V8
        axi_wr(17'h1_0000, 32'h8);                   $fdisplay(efd, "E LOCK resp=%0d", last_resp);
        log_regs("after_lock");
        axi_rd(spa(1, 512, 0), d);  $fdisplay(efd, "E LOCKED_RD_S1 resp=%0d data=%08h", last_resp, d);
        axi_rd(spa(2, 2047, 1), d); $fdisplay(efd, "E LOCKED_RD_T0 resp=%0d data=%08h", last_resp, d);
        axi_rd(spa(2, 3, 0), d);    $fdisplay(efd, "E LOCKED_RD_RHOPP resp=%0d data=%08h", last_resp, d);
`ifdef ADV_P2
        axi_rd(spa(2, 1040, 0), d); $fdisplay(efd, "E LOCKED_RD_K resp=%0d data=%08h", last_resp, d);
        axi_rd(spa(2, 1043, 1), d); $fdisplay(efd, "E LOCKED_RD_K3 resp=%0d data=%08h", last_resp, d);
        sp_write64(2, 1040, 64'd0); $fdisplay(efd, "E LOCKED_WR_K resp=%0d", last_resp);
        sp_write64(2, 1056, 64'h5555_5555_5555_5555); $fdisplay(efd, "E LOCKED_WR_RHOPP_BLOCK resp=%0d", last_resp);
        sp_write64(2, 1100, 64'd0); $fdisplay(efd, "E LOCKED_WR_RAWTRNG resp=%0d", last_resp);
        axi_wr(17'h1_0040, 32'hCAFE_F00D); $fdisplay(efd, "E LOCKED_WR_SEEDREG resp=%0d", last_resp);
`endif
        log_regs("after_sealed_reads");
        // attempt to overwrite one s1_hat word with 0: must be dropped (the sign below must still match the oracle)
        sp_write64(1, 512, 64'd0);  $fdisplay(efd, "E LOCKED_WR_S1 resp=%0d", last_resp);
        sp_write64(2, 1536, 64'd0); $fdisplay(efd, "E LOCKED_WR_T0 resp=%0d", last_resp);
        // attempt to replace public rho (A-substitution) through the register and the SP word
        axi_wr(17'h1_0080, 32'h1234_5678); $fdisplay(efd, "E LOCKED_WR_RHOREG resp=%0d", last_resp);
        sp_write64(2, 512, 64'h0123_4567_89AB_CDEF); $fdisplay(efd, "E LOCKED_WR_RHO_SP resp=%0d", last_resp);
        axi_wr(17'h1_0000, 32'h0); // no-op
        log_regs("after_sealed_writes");
        sweep("p1_locked_prejob");
        // restore mu (whitelisted) in case the window allowed it; rho SP write must have no effect
        for (i = 0; i < 8; i = i + 1) sp_write64(2, MU_W + i, mu[i]);
`endif
        maybe_stop;
        // ---- P2: SIGN with hostile probes while busy
        phase = 2;
        axi_wr(17'h1_0000, 32'h1); $fdisplay(efd, "E LAUNCH_SIGN resp=%0d", last_resp);
        repeat (50) @(posedge aclk);
        busy_probes("sign1");
        wait_done(st); log_regs("sign1_done"); backdoor("after_sign1");
        sweep("p2_after_sign");

        maybe_stop;
        // ---- P3: VERIFY launched over the residue of the SIGN (host writes ONLY mu and c~ = zeros,
        //          no z/h/t1): does any secret-dependent output become readable?
        phase = 3;
        // Hostile VERIFY inputs: c~ = 0, h = 0 (b3[512..1023]), t1' = one-coefficient perturbation, z NOT written
        // (z slot b3[0..511] still holds the SIGN's y).
        for (i = 0; i < 4; i = i + 1) sp_write64(1, 1150 + i, 64'd0);
        for (i = 0; i < 512; i = i + 1) sp_write64(3, 512 + i, 64'd0);
`ifdef ADV_V8
        for (i = 0; i < 512; i = i + 1) sp_write64(3, 1536 + i, (i == 0) ? 64'd8192 : 64'd0);
`else
        for (i = 0; i < 512; i = i + 1) sp_write64(2, 1536 + i, (i == 0) ? 64'd8192 : 64'd0);
`endif
        axi_wr(17'h1_0000, 32'h5); $fdisplay(efd, "E LAUNCH_VERIFY_RESIDUE resp=%0d", last_resp);
        wait_done(st); log_regs("verify_residue_done"); backdoor("after_verify_residue");
        for (i = 0; i < 4; i = i + 1) begin
            sp_read64(1, 1150 + i, got); $fdisplay(efd, "E VERIFY_RESIDUE_CTP i=%0d data=%016h resp=%0d", i, got, last_resp);
        end
        axi_rd(17'h1_0004, st);
        if (!st[6]) sweep("p3_after_verify_residue");
        else $fdisplay(efd, "E P3_SWEEP_SKIPPED_HOST_PORT_BLOCKED_BY_JOB_ERROR status=%08h", st);
        if (st[6]) begin   // core error is sticky until reset in v7: recover so the remaining phases can run
            $fdisplay(efd, "E P3_JOB_ERROR_RESET status=%08h", st);
            @(negedge aclk); aresetn = 0; repeat (20) @(negedge aclk); aresetn = 1; wait_init;
`ifdef ADV_P3
            keygen("kg_recover", 0); wait_done(st);
`else
            provision;
`ifdef ADV_V8
            axi_wr(17'h1_0000, 32'h8);
`endif
`endif
        end

        maybe_stop;
        // ---- P4: a proper VERIFY (valid vector) through the inputs the seal allows
        phase = 4;
        for (i = 0; i < 4; i = i + 1)   sp_write64(2, 512 + i, vrho[i]);
        for (i = 0; i < 8; i = i + 1)   sp_write64(2, MU_W + i, vmu[i]);
        for (i = 0; i < 4; i = i + 1)   sp_write64(1, 1150 + i, vct[i]);
        for (i = 0; i < 512; i = i + 1) begin
            sp_write64(3, i, vz[i]); sp_write64(3, 512 + i, vh[i]);
`ifdef ADV_V8
            sp_write64(3, 1536 + i, vt1[i]);
`else
            sp_write64(2, 1536 + i, vt1[i]);
`endif
        end
`ifndef ADV_V8
        for (i = 0; i < 4; i = i + 1) begin
            axi_wr(17'h1_0080 + 8*i, vrho[i][31:0]); axi_wr(17'h1_0084 + 8*i, vrho[i][63:32]);
        end
`endif
        axi_wr(17'h1_0000, 32'h5); $fdisplay(efd, "E LAUNCH_VERIFY_VALID resp=%0d", last_resp);
        wait_done(st); log_regs("verify_valid_done");
        t = 1;
        for (i = 0; i < 4; i = i + 1) begin
            sp_read64(1, 1150 + i, got);
            if (got !== vctp[i]) t = 0;
            $fdisplay(efd, "E VERIFY_VALID_CTP i=%0d data=%016h exp=%016h resp=%0d", i, got, vctp[i], last_resp);
        end
        $fdisplay(efd, "E VERIFY_VALID_RESULT match_oracle_ctilde_prime=%0d", t);

        maybe_stop;
        // ---- P5: second SIGN, then the host-visible state after it (exercises retry path for vec with rejections)
        phase = 5;
`ifndef ADV_V8
        provision;
`else
        for (i = 0; i < 8; i = i + 1) sp_write64(2, MU_W + i, mu[i]);
        rearm_seed;
`endif
        axi_wr(17'h1_0000, 32'h1); $fdisplay(efd, "E LAUNCH_SIGN2 resp=%0d", last_resp);
`ifdef ADV_V8
        // catch the window between core DONE and wrapper DONE (post-SIGN residue scrub) and attack it
        t = 0;
        do begin repeat (40) @(posedge aclk); axi_rd(17'h1_0004, st); t = t + 1; end
        while (!( !st[0] && !st[1] ) && !st[1] && t < 400000);
        if (!st[0] && !st[1]) begin
            $fdisplay(efd, "E SCRUBWIN_CAUGHT status=%08h polls=%0d", st, t);
            axi_rd(spa(3, 1400, 0), d); $fdisplay(efd, "E SCRUBWIN_RD_Z resp=%0d data=%08h", last_resp, d);
            axi_rd(spa(3, 0, 0), d);    $fdisplay(efd, "E SCRUBWIN_RD_Y resp=%0d data=%08h", last_resp, d);
            axi_rd(spa(2, 1056, 0), d); $fdisplay(efd, "E SCRUBWIN_RD_RHOPP resp=%0d data=%08h", last_resp, d);
            axi_rd(spa(1, 0, 0), d);    $fdisplay(efd, "E SCRUBWIN_RD_H resp=%0d data=%08h", last_resp, d);
            axi_wr(spa(3, 0, 0), 32'h1); $fdisplay(efd, "E SCRUBWIN_WR_Z resp=%0d", last_resp);
            axi_wr(17'h1_0000, 32'h1);  $fdisplay(efd, "E SCRUBWIN_RELAUNCH resp=%0d", last_resp);
            axi_wr(17'h1_0000, 32'h5);  $fdisplay(efd, "E SCRUBWIN_LAUNCH_VERIFY resp=%0d", last_resp);
        end else $fdisplay(efd, "E SCRUBWIN_NOT_CAUGHT status=%08h", st);
`endif
        wait_done(st); log_regs("sign2_done"); backdoor("after_sign2");
        sweep("p5_after_sign2");

        maybe_stop;
`ifdef ADV_V8
        // ---- P6: ZEROIZE -> everything zero, LOCK released
        phase = 6;
        axi_wr(17'h1_0000, 32'h10); $fdisplay(efd, "E ZEROIZE resp=%0d", last_resp);
        repeat (3000) @(posedge aclk);
        log_regs("after_zeroize");
        sweep("p6_after_zeroize");
`endif
        maybe_stop;
        // ---- P7: reset in the middle of a SIGN -> nothing readable afterwards
        phase = 7;
`ifdef ADV_P3
        keygen("kg_midreset", 0);
`else
        provision;
`ifdef ADV_V8
        axi_wr(17'h1_0000, 32'h8);
`endif
        axi_wr(17'h1_0000, 32'h1); $fdisplay(efd, "E LAUNCH_SIGN3 resp=%0d", last_resp);
`endif
        repeat (`ADV_MIDRESET_CYCLES) @(posedge aclk);
        $fdisplay(efd, "E MIDRESET at_pc=%0d kappa=%0d running=%0d", dut.u_core.pc_status, dut.u_retry.kappa, dut.running);
        @(negedge aclk); aresetn = 0; repeat (20) @(negedge aclk); aresetn = 1;
        wait_init; log_regs("after_midreset");
        sweep("p7_after_midreset");

        $fdisplay(efd, "E END axi_writes=%0d axi_reads=%0d", nwr, nrd);
        $fclose(tfd); $fclose(efd);
        $display("ADV_TB_FINISHED axi_writes=%0d axi_reads=%0d", nwr, nrd);
        $finish;
    end
endmodule
