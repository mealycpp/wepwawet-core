`timescale 1ns/1ps
// seal_v8 phase-1/2 security regression (phase 2: K sealed in b2[1040..1043], rho'' only in the PL) (PS view only, AXI4-Lite, no hierarchical pokes).
//  1 provision key (unlocked)  2 SEAL_LOCK  3 refused writes (s1 word, public rho, rho'' blocks)
//  4 SIGN #1 with LOCK (retry manager writes the rho''/rho blocks for attempt 1)
//  5 full host read sweep of the scratchpad window (4 banks x 2048 words) + register page:
//    every non-whitelisted read must be 0; no read may equal a secret word
//  6 VERIFY own signature while LOCKED (t1'_hat in b3[1536..], key region untouched)
//  7 SIGN #2: must equal SIGN #1 bit for bit (key survived verify and refused writes)
//  8 ZEROIZE -> LOCK cleared, unlocked sweep of all banks must be all zero
//  9 re-provision + LOCK, then aresetn pulse -> LOCK cleared, sweep all zero
module tb_seal;
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;
    reg aresetn = 0;
    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg  awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0; reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0] bresp, rresp; wire [31:0] rdata;
    wepwawet_sign_axil #(.MAX_ATTEMPTS(255), .DET_RND(1)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .irq(irq), .trng_claim(), .trng_word(32'd0), .trng_valid(1'b0), .trng_health_fail(1'b0));
    integer nwr = 0, nrd = 0;
    task automatic axi_wr(input [AW-1:0] a, input [31:0] d, input integer expect_err);
        integer t; begin
            @(negedge aclk); awaddr = a; wdata = d; awvalid = 1; wvalid = 1; bready = 1; t = 0;
            while ((awvalid || wvalid) && t < 2000) begin
                @(posedge aclk); #0.01; if (awvalid && awready) awvalid = 0; if (wvalid && wready) wvalid = 0; t = t + 1;
            end
            t = 0; while (!bvalid && t < 200000) begin @(posedge aclk); #0.01; t = t + 1; end
            if (!bvalid) $fatal(1, "AXI_WRITE_NO_B a=%h", a);
            if (expect_err ? (bresp != 2'b10) : (bresp != 2'b00)) $fatal(1, "AXI_WRITE_BRESP a=%h resp=%0d", a, bresp);
            @(posedge aclk); #0.01; bready = 0; nwr = nwr + 1;
        end endtask
    task automatic axi_rd(input [AW-1:0] a, output [31:0] d, input integer expect_err);
        integer t; begin
            @(negedge aclk); araddr = a; arvalid = 1; rready = 1; t = 0;
            while (arvalid && t < 2000) begin @(posedge aclk); #0.01; if (arready) arvalid = 0; t = t + 1; end
            t = 0; while (!rvalid && t < 200000) begin @(posedge aclk); #0.01; t = t + 1; end
            if (!rvalid) $fatal(1, "AXI_READ_NO_R a=%h", a);
            if (expect_err ? (rresp != 2'b10) : (rresp != 2'b00)) $fatal(1, "AXI_READ_RRESP a=%h resp=%0d", a, rresp);
            d = rdata; @(posedge aclk); #0.01; rready = 0; nrd = nrd + 1;
        end endtask
    function [AW-1:0] spa(input integer bank, input integer word, input integer hi);
        spa = (bank << 14) | (word << 3) | (hi << 2); endfunction
    task automatic sp_write64(input integer bank, input integer word, input [63:0] v);
        begin axi_wr(spa(bank, word, 0), v[31:0], 0); axi_wr(spa(bank, word, 1), v[63:32], 0); end endtask
    task automatic sp_read64(input integer bank, input integer word, output [63:0] v);
        reg [31:0] lo, hi; begin axi_rd(spa(bank, word, 0), lo, 0); axi_rd(spa(bank, word, 1), hi, 0); v = {hi, lo}; end endtask

    reg [63:0] rho [0:3]; reg [63:0] mu [0:7]; reg [63:0] seed_nonce [0:35]; reg [63:0] kk [0:3];
    reg [63:0] s1_hat [0:511]; reg [63:0] s2_hat [0:511]; reg [63:0] t0_hat [0:511];
    reg [63:0] yv [0:511]; reg [63:0] wv [0:511]; reg [63:0] r0v [0:511]; reg [63:0] ct0v [0:511];
    reg [63:0] vrho [0:3]; reg [63:0] vmu [0:7]; reg [63:0] vct [0:3]; reg [63:0] vctp [0:3];
    reg [63:0] vz [0:511]; reg [63:0] vh [0:511]; reg [63:0] vt1 [0:511];
    reg [63:0] sig1 [0:1027];             // c~ 4 + z 512 + h 512
    bit secret [logic [63:0]];
    integer coinc, i, b, t, fd, have_v, nviol_exp, leaks, nonzero, cfd, zfd, hfd, mfd;
    reg [31:0] st, kap, errs, cyc, magic, ver, sreg, x; reg [63:0] got;

    task automatic wait_ready; begin
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4] && !st[12]) && t < 20000);
        if (!(st[3] && !st[4] && !st[12])) $fatal(1, "SCRATCHPAD_READY_TIMEOUT st=%h", st);
    end endtask
    task automatic provision; begin
        for (i = 0; i < 512; i = i + 1) begin
            sp_write64(1, 512 + i, s1_hat[i]); sp_write64(1, 1536 + i, s2_hat[i]); sp_write64(2, 1536 + i, t0_hat[i]);
        end
        for (i = 0; i < 4; i = i + 1) begin axi_wr(17'h1_0080 + 8*i, rho[i][31:0], 0); axi_wr(17'h1_0084 + 8*i, rho[i][63:32], 0); end
        for (i = 0; i < 4; i = i + 1) sp_write64(2, 1040 + i, kk[i]);
    end endtask
    task automatic job_inputs_sign; begin       // per-signature host input while LOCKED (phase 2): mu only
        for (i = 0; i < 8; i = i + 1) sp_write64(2, 1048 + i, mu[i]);
    end endtask
    task automatic run_job(input [31:0] ctrl, input integer must_succeed); begin
        axi_wr(17'h1_0000, ctrl, 0);
        t = 0; do begin repeat (2000) @(posedge aclk); axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!st[1] && t < 200000);
        if (!st[1]) $fatal(1, "JOB_TIMEOUT st=%h", st);
        axi_rd(17'h1_0008, kap, 0); axi_rd(17'h1_000C, errs, 0); axi_rd(17'h1_0010, cyc, 0);
        $display("SEAL_JOB ctrl=%h status=%h kappa=%0d attempts=%0d errors=%h cycles=%0d", ctrl, st, kap[15:0], kap[31:16], errs, cyc);
        if (must_succeed && (!st[2] || errs[7:0] != 0)) $fatal(1, "JOB_FAILED st=%h errs=%h", st, errs);
        axi_wr(17'h1_0000, 32'h2, 0);
    end endtask
    // READ-ONLY hierarchical check of residues (reviewer HIGH-2): after a LOCKED SIGN every word that is not key,
    // A_hat, mu or (on success) a released output must be zero in the scratchpad arrays themselves.
    task automatic residue_check(input integer succ, input [255:0] tagname);
        integer a, r; reg k1, k2, k3; begin
        r = 0;
        for (a = 0; a < 2048; a = a + 1) begin
            k1 = (a >= 512 && a <= 1023) || a >= 1536 || (succ && (a <= 511 || (a >= 1150 && a <= 1153)));
            k2 = a >= 1536 || (a >= 1040 && a <= 1043);
            k3 = succ && a >= 1400 && a <= 1911;
            if (!k1 && dut.u_core.u_wcore.u_sp.BANK[1].mem[a] != 0) r = r + 1;
            if (!k2 && dut.u_core.u_wcore.u_sp.BANK[2].mem[a] != 0) r = r + 1;
            if (!k3 && dut.u_core.u_wcore.u_sp.BANK[3].mem[a] != 0) r = r + 1;
        end
        $display("SEAL_RESIDUE %0s nonzero_non_kept_words=%0d", tagname, r);
        if (r) $fatal(1, "SEAL_RESIDUE_FAILED %0s", tagname);
    end endtask
    function automatic integer sign_window(input integer bk, input integer w);
        sign_window = (bk == 1 && w <= 511) || (bk == 1 && w >= 1150 && w <= 1153) || (bk == 3 && w >= 1400 && w <= 1911);
    endfunction
    // full sweep: mode 0 = LOCKED after SIGN (whitelist = sign outputs), 1 = expect all zero
    task automatic sweep(input integer mode, input [255:0] tagname); begin
        leaks = 0; nonzero = 0; coinc = 0;
        for (b = 0; b < 4; b = b + 1) for (i = 0; i < 2048; i = i + 1) begin
            sp_read64(b, i, got);
            // a released z/h word may coincide with a y word when (c*s1) is 0 at both coefficients; that is
            // public by construction (z is the output) and is counted separately, not as a leak
            if (got != 64'd0 && secret.exists(got)) begin
                if (mode == 0 && sign_window(b, i)) coinc = coinc + 1;
                else begin leaks = leaks + 1; if (leaks < 5) $display("LEAK b%0d[%0d]=%h", b, i, got); end
            end
            if (got != 64'd0 && !(mode == 0 && sign_window(b, i))) begin
                nonzero = nonzero + 1; if (nonzero < 5) $display("NONZERO b%0d[%0d]=%h", b, i, got); end
        end
        for (i = 0; i < 64; i = i + 1) begin            // register page 0x1_0000..0x1_00FC
            axi_rd(17'h1_0000 + 4*i, x, 0);                 // page 0x1_00xx: unmapped words read 0 (v7)
            if (i >= 16 && i < 32 && x != 0) begin leaks = leaks + 1; $display("SEED_REG_READABLE %0d %h", i, x); end
        end
        $display("SEAL_SWEEP %0s words=8192 secret_hits=%0d unexpected_nonzero=%0d released_word_coincidences=%0d", tagname, leaks, nonzero, coinc);
        if (leaks || nonzero) $fatal(1, "SEAL_SWEEP_FAILED %0s", tagname);
    end endtask

    initial begin
        $readmemh("vectors/rho_4x64.mem", rho); $readmemh("vectors/mu_8x64.mem", mu);
        $readmemh("vectors/candidate_mask_seed_nonce_36x64.mem", seed_nonce);
        $readmemh("vectors/s1_hat_512x64.mem", s1_hat); $readmemh("vectors/s2_hat_512x64.mem", s2_hat);
        $readmemh("vectors/t0_hat_512x64.mem", t0_hat); $readmemh("vectors/k_4x64.mem", kk);
        $readmemh("vectors/y_512x64.mem", yv); $readmemh("vectors/w_512x64.mem", wv);
        $readmemh("vectors/r0_512x64.mem", r0v); $readmemh("vectors/ct0_512x64.mem", ct0v);
        for (i = 0; i < 512; i = i + 1) begin
            secret[s1_hat[i]] = 1; secret[s2_hat[i]] = 1; secret[t0_hat[i]] = 1;
            secret[yv[i]] = 1; secret[wv[i]] = 1; secret[r0v[i]] = 1; secret[ct0v[i]] = 1;
        end
        for (i = 0; i < 36; i = i + 1) if (i % 9 != 8) secret[seed_nonce[i]] = 1;
        for (i = 0; i < 4; i = i + 1) secret[kk[i]] = 1;
        secret.delete(64'd0);
        fd = $fopen("vvec/ctilde_4x64.mem", "r"); have_v = (fd != 0); if (fd) $fclose(fd);
        if (have_v) begin
            $readmemh("vvec/rho_4x64.mem", vrho); $readmemh("vvec/mu_8x64.mem", vmu);
            $readmemh("vvec/ctilde_4x64.mem", vct); $readmemh("vvec/ctilde_prime_4x64.mem", vctp);
            $readmemh("vvec/z_512x64.mem", vz); $readmemh("vvec/h_512x64.mem", vh); $readmemh("vvec/t1hat2d_512x64.mem", vt1);
        end
        repeat (10) @(negedge aclk); aresetn = 1;
        axi_rd(17'h1_0014, magic, 0); axi_rd(17'h1_0018, ver, 0);
        if (magic != 32'h5743_5331 || ver != 32'h0003_0002) $fatal(1, "MAGIC/VERSION %h %h", magic, ver);
        wait_ready;
        // 1 provision (unlocked, v7 semantics) + readback
        provision;
        sp_read64(1, 512, got); if (got !== s1_hat[0]) $fatal(1, "UNLOCKED_READBACK_S1 %h", got);
        // 2 LOCK
        axi_wr(17'h1_0000, 32'h8, 0); axi_rd(17'h1_0004, st, 0); if (!st[10] || st[11]) $fatal(1, "LOCK_NOT_SET st=%h", st);
        // 3 refused accesses
        nviol_exp = 0;
        sp_read64(1, 512, got); nviol_exp = nviol_exp + 2; if (got != 0) $fatal(1, "LOCKED_S1_READABLE %h", got);
        sp_read64(2, 2047, got); nviol_exp = nviol_exp + 2; if (got != 0) $fatal(1, "LOCKED_T0_READABLE %h", got);
        sp_read64(2, 1040, got); nviol_exp = nviol_exp + 2; if (got != 0) $fatal(1, "LOCKED_K_READABLE %h", got);
        sp_write64(2, 1041, 64'hBAD0_BAD0_BAD0_BAD0); nviol_exp = nviol_exp + 2;     // overwrite K[1]: must be dropped
        for (i = 0; i < 16; i = i + 1) begin axi_wr(17'h1_0040 + 4*i, 32'h5EED0000 + i, 0); nviol_exp = nviol_exp + 1; end  // host rho'' gone
        for (i = 0; i < 8; i = i + 1) begin sp_write64(2, 1056 + 9*(i%4) + (i/4), 64'h0123_4567_89AB_CDEF); nviol_exp = nviol_exp + 2; end // ExpandMask blocks
        axi_rd(17'h1_0004, st, 0); if (!st[11]) $fatal(1, "VIOLATION_NOT_STICKY st=%h", st);
        sp_write64(1, 512, 64'hDEAD_BEEF_0BAD_F00D); nviol_exp = nviol_exp + 2;      // overwrite s1_hat[0]: must be dropped
        sp_write64(2, 1536, 64'h1234_5678_9ABC_DEF0); nviol_exp = nviol_exp + 2;      // overwrite t0_hat[0]
        for (i = 0; i < 36; i = i + 1) begin sp_write64(2, i, 64'hFFFF_0000_FFFF_0000); nviol_exp = nviol_exp + 2; end  // rho'' blocks
        axi_wr(17'h1_0080, 32'hBADBAD00, 0); nviol_exp = nviol_exp + 1;              // public rho locked
        axi_rd(17'h1_0080, x, 0); if (x != rho[0][31:0]) $fatal(1, "LOCKED_RHO_CHANGED %h", x);
        axi_wr(17'h1_0000, 32'h8, 0);                                                    // LOCK again: no effect
        axi_rd(17'h1_001C, sreg, 0);
        $display("SEAL_REFUSED violations=%0d expected=%0d seal=%h", sreg[31:16], nviol_exp, sreg);
        if (sreg[31:16] != nviol_exp || sreg[2:0] != 3'b111) $fatal(1, "VIOLATION_COUNT");
        // 4 SIGN #1 while LOCKED
        job_inputs_sign; run_job(32'h1, 1);
        axi_rd(17'h1_0004, st, 0); if (!st[13] || st[14]) $fatal(1, "SIGN_OUT_FLAG st=%h", st);
        cfd = $fopen("capture/ctilde_4x64.hex", "w"); zfd = $fopen("capture/z_512x64.hex", "w"); hfd = $fopen("capture/hint_512x64.hex", "w");
        for (i = 0; i < 4; i = i + 1)   begin sp_read64(1, 1150 + i, got); sig1[i] = got; $fdisplay(cfd, "%016h", got); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1400 + i, got); sig1[4+i] = got; $fdisplay(zfd, "%016h", got); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(1, i, got); sig1[516+i] = got; $fdisplay(hfd, "%016h", got); end
        $fclose(cfd); $fclose(zfd); $fclose(hfd);
        mfd = $fopen("capture/status.txt", "w");
        $fdisplay(mfd, "kappa=%0d\nattempts=%0d\ncycles=%0d", kap[15:0], kap[31:16], cyc); $fclose(mfd);
        residue_check(1, "AFTER_LOCKED_SIGN1");
        // 5 sweep
        sweep(0, "LOCKED_AFTER_SIGN");
        nviol_exp = nviol_exp + 2*(8192 - 1028);           // every non-whitelisted half-word read is a violation
        axi_rd(17'h1_001C, sreg, 0); if (sreg[31:16] != nviol_exp) $fatal(1, "SWEEP_VIOLATION_COUNT %0d %0d", sreg[31:16], nviol_exp);
        // 6 VERIFY own signature while LOCKED
        if (have_v) begin
            for (i = 0; i < 4; i = i + 1)   sp_write64(2, 512 + i, vrho[i]);
            for (i = 0; i < 8; i = i + 1)   sp_write64(2, 1048 + i, vmu[i]);
            for (i = 0; i < 4; i = i + 1)   sp_write64(1, 1150 + i, vct[i]);
            for (i = 0; i < 512; i = i + 1) begin sp_write64(3, i, vz[i]); sp_write64(3, 512 + i, vh[i]); sp_write64(3, 1536 + i, vt1[i]); end
            axi_rd(17'h1_001C, sreg, 0); if (sreg[31:16] != nviol_exp) $fatal(1, "VERIFY_INPUT_WRITE_REFUSED %h", sreg);
            run_job(32'h5, 1);
            axi_rd(17'h1_0004, st, 0); if (st[13] || !st[14]) $fatal(1, "VERIFY_OUT_FLAG st=%h", st);
            for (i = 0; i < 4; i = i + 1) begin
                sp_read64(1, 1150 + i, got); if (got !== vctp[i] || got !== vct[i]) $fatal(1, "LOCKED_VERIFY_NOT_ACCEPT i=%0d %h", i, got);
            end
            sp_read64(3, 1024, got); nviol_exp = nviol_exp + 2; if (got != 0) $fatal(1, "VERIFY_INTERMEDIATE_READABLE");
            sp_read64(3, 1400, got); nviol_exp = nviol_exp + 2; if (got != 0) $fatal(1, "STALE_Z_READABLE_AFTER_VERIFY");
            $display("SEAL_LOCKED_VERIFY verdict=ACCEPT cycles=%0d", cyc);
        end
        // 7 SIGN #2: identical signature proves s1/s2/t0 survived refused writes + verify
        job_inputs_sign; run_job(32'h1, 1);
        for (i = 0; i < 4; i = i + 1)   begin sp_read64(1, 1150 + i, got); if (got !== sig1[i]) $fatal(1, "SIGN2_CTILDE_DIFF %0d", i); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1400 + i, got); if (got !== sig1[4+i]) $fatal(1, "SIGN2_Z_DIFF %0d", i); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(1, i, got); if (got !== sig1[516+i]) $fatal(1, "SIGN2_H_DIFF %0d", i); end
        $display("SEAL_SIGN2_IDENTICAL kappa=%0d cycles=%0d", kap[15:0], cyc);
        axi_rd(17'h1_001C, sreg, 0); if (sreg[31:16] != nviol_exp) $fatal(1, "VIOLATION_COUNT2 %0d %0d", sreg[31:16], nviol_exp);
        // 8 ZEROIZE
        axi_wr(17'h1_0000, 32'h10, 0); wait_ready;
        axi_rd(17'h1_0004, st, 0); axi_rd(17'h1_001C, sreg, 0);
        if (st[10] || st[11] || st[13] || sreg != 0) $fatal(1, "ZEROIZE_STATE st=%h seal=%h", st, sreg);
        axi_rd(17'h1_0080, x, 0); if (x != 0) $fatal(1, "ZEROIZE_RHO %h", x);
        sweep(1, "AFTER_ZEROIZE");
        // 9 reset path
        provision; axi_wr(17'h1_0000, 32'h8, 0);
        @(negedge aclk); aresetn = 0; repeat (10) @(negedge aclk); aresetn = 1;
        wait_ready; axi_rd(17'h1_0004, st, 0); if (st[10]) $fatal(1, "LOCK_SURVIVED_RESET");
        sweep(1, "AFTER_RESET");
        $display("SEAL_V8_PHASE1_PASS axi_writes=%0d axi_reads=%0d", nwr, nrd);
        $finish;
    end
endmodule
