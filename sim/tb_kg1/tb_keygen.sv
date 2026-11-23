`timescale 1ns/1ps
// KEYGEN: PS-view KeyGen KAT + sign-after-keygen + adversarial host read sweeps (reviewer approach:
// every one of the 4 x 2048 x 2 halves is read through the AXI window; secrets are taken from a read-only
// hierarchical snapshot of the scratchpad at the instant the KeyGen program halts, i.e. with every intermediate
// (xi, rho', K, s1/s2 coeffs, t, t0, ExpandS streams) still present).
// Build-time params: DET_RND=1 (deterministic sign, rnd=0^32), DET_XI=1 (xi injected by host into b2[1160..1163]).
// Only hierarchical accesses: read-only peeks (snapshot, key-home compare, residue count). No pokes.
module tb_keygen;
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;
    reg aresetn = 0;
    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg  awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0; reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0] bresp, rresp; wire [31:0] rdata;
    wepwawet_sign_axil #(.MAX_ATTEMPTS(255), .DET_RND(1), .DET_XI(1)) dut (
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
            while ((awvalid || wvalid) && t < 2000) begin @(posedge aclk); #0.01;
                if (awvalid && awready) awvalid = 0; if (wvalid && wready) wvalid = 0; t = t + 1; end
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

    // ---------------- read-only snapshot of the scratchpad when the KeyGen program halts ----------------
    reg [63:0] snap0 [0:2047]; reg [63:0] snap1 [0:2047]; reg [63:0] snap2 [0:2047]; reg [63:0] snap3 [0:2047];
    reg snapped = 0; integer sa;
    always @(posedge aclk) if (aresetn && !snapped && dut.pscrub && dut.kg_scr) begin
        for (sa = 0; sa < 2048; sa = sa + 1) begin
            snap0[sa] = dut.u_core.u_wcore.u_sp.BANK[0].mem[sa]; snap1[sa] = dut.u_core.u_wcore.u_sp.BANK[1].mem[sa];
            snap2[sa] = dut.u_core.u_wcore.u_sp.BANK[2].mem[sa]; snap3[sa] = dut.u_core.u_wcore.u_sp.BANK[3].mem[sa];
        end
        snapped = 1;
    end
    function [63:0] snapw(input integer b, input integer a);
        snapw = b == 0 ? snap0[a] : b == 1 ? snap1[a] : b == 2 ? snap2[a] : snap3[a]; endfunction
    function [63:0] memw(input integer b, input integer a);
        memw = b == 0 ? dut.u_core.u_wcore.u_sp.BANK[0].mem[a] : b == 1 ? dut.u_core.u_wcore.u_sp.BANK[1].mem[a] :
               b == 2 ? dut.u_core.u_wcore.u_sp.BANK[2].mem[a] : dut.u_core.u_wcore.u_sp.BANK[3].mem[a]; endfunction
    // secret set: every nonzero 32-bit half of the snapshot that is not part of pk||tr (b1[0..171]) nor A_hat (bank 0,
    // public, derived from rho) nor unpacked t1 (b3[1536..2047], public)
    bit secret [bit [31:0]];
    function automatic bit is_public(input integer b, input integer a);
        is_public = (b == 1 && a <= 171) || (b == 0) || (b == 3 && a >= 1536); endfunction
    task automatic build_secret_set(output integer n);
        integer b, a; reg [63:0] w; begin
            n = 0; secret.delete();
            for (b = 0; b < 4; b = b + 1) for (a = 0; a < 2048; a = a + 1) if (!is_public(b, a)) begin
                w = snapw(b, a);
                if (w[31:0] != 0 && !secret.exists(w[31:0])) begin secret[w[31:0]] = 1; n = n + 1; end
                if (w[63:32] != 0 && !secret.exists(w[63:32])) begin secret[w[63:32]] = 1; n = n + 1; end
            end
        end endtask
    // window: 0 = nothing readable, 1 = keygen pk||tr, 2 = sign outputs
    task automatic sweep(input [8*24-1:0] tag, input integer win);
        integer b, a, h, hits, unexp, coinc, inwin; reg [31:0] d; begin
            hits = 0; unexp = 0; coinc = 0;
            for (b = 0; b < 4; b = b + 1) for (a = 0; a < 2048; a = a + 1) for (h = 0; h < 2; h = h + 1) begin
                axi_rd(spa(b, a, h), d, 0);
                inwin = (win == 1 && b == 1 && a <= 171) ||
                        (win == 2 && ((b == 1 && a <= 511) || (b == 1 && a >= 1150 && a <= 1153) || (b == 3 && a >= 1400 && a <= 1911)));
                if (d != 0 && secret.exists(d)) begin if (inwin) coinc = coinc + 1; else hits = hits + 1; end
                if (d != 0 && !inwin) unexp = unexp + 1;
            end
            $display("KG_SWEEP %0s words=8192 halves=16384 secret_hits=%0d unexpected_nonzero=%0d released_word_coincidences=%0d",
                     tag, hits, unexp, coinc);
            if (hits != 0 || unexp != 0) $fatal(1, "KG_SWEEP_LEAK %0s", tag);
        end endtask

    reg [63:0] xi [0:3]; reg [63:0] mu [0:7]; reg [63:0] kk [0:3];
    reg [63:0] s1_hat [0:511]; reg [63:0] s2_hat [0:511]; reg [63:0] t0_hat [0:511];
    reg [63:0] pk1 [0:171];
    integer i, t, fd, nsec, mm1, mm2, mm3, mmk, resid;
    reg [31:0] st, kap, errs, cyc, ver, seal0, seal1, r; reg [63:0] got;

    task automatic wait_done(input [8*16-1:0] tag);
        begin t = 0;
            do begin repeat (2000) @(posedge aclk); axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!st[1] && t < 100000);
            if (!st[1]) $fatal(1, "TIMEOUT %0s st=%h", tag, st);
            axi_rd(17'h1_0008, kap, 0); axi_rd(17'h1_000C, errs, 0); axi_rd(17'h1_0010, cyc, 0);
            $display("KG_JOB %0s status=%h kappa=%0d attempts=%0d errors=%h cycles=%0d irq=%b", tag, st, kap[15:0], kap[31:16], errs, cyc, irq);
        end endtask

    initial begin
        $readmemh("vectors/xi_4x64.mem", xi); $readmemh("vectors/mu_8x64.mem", mu); $readmemh("vectors/K_4x64.mem", kk);
        $readmemh("vectors/s1_hat_512x64.mem", s1_hat); $readmemh("vectors/s2_hat_512x64.mem", s2_hat);
        $readmemh("vectors/t0_hat_512x64.mem", t0_hat);
        repeat (10) @(negedge aclk); aresetn = 1;
        axi_rd(17'h1_0018, ver, 0); if (ver != 32'h0003_0103) $fatal(1, "VERSION %h", ver);
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4]) && t < 5000);
        // ---------------- K1: KeyGen KAT (xi injected, DET_XI build) ----------------
        for (i = 0; i < 4; i = i + 1) sp_write64(2, 1160 + i, xi[i]);
        axi_wr(17'h1_0000, 32'h21, 1);                       // LAUNCH|KEYGEN together -> SLVERR, nothing starts
        axi_rd(17'h1_0004, st, 0); if (st[0] || st[10]) $fatal(1, "BOTH_BITS_STARTED st=%h", st);
        axi_wr(17'h1_0000, 32'h20, 0);                       // START_KEYGEN
        axi_rd(spa(1, 0, 0), r, 1);                          // window closed while busy
        wait_done("KEYGEN");
        $display("KG_CYCLES keygen=%0d us_at_300MHz=%0d", cyc, cyc / 300);
        if (!st[2] || !st[10] || !st[15] || st[6] || st[13] || errs[7:0] != 0 || errs[24:16] != 9'd382)
            $fatal(1, "KEYGEN_NOT_OK st=%h errs=%h", st, errs);
        if (!snapped) $fatal(1, "NO_SNAPSHOT");
        // ---------------- K2: pk || tr through the read-only window ----------------
        fd = $fopen("capture/pk_tr_172x64.hex", "w");
        for (i = 0; i < 172; i = i + 1) begin sp_read64(1, i, got); pk1[i] = got; $fdisplay(fd, "%016h", got); end
        $fclose(fd);
        for (i = 0; i < 8; i = i + 1) begin axi_rd(17'h1_0080 + 4*i, r, 0); if (r != pk1[i/2][32*(i%2) +: 32]) $fatal(1, "PUBLIC_RHO_REG %0d", i); end
        // ---------------- K3: sealed key homes (read-only peek) vs PQClean-derived values; residue ----------------
        mm1 = 0; mm2 = 0; mm3 = 0; mmk = 0; resid = 0;
        for (i = 0; i < 512; i = i + 1) begin
            if (memw(1, 512 + i) !== s1_hat[i]) mm1 = mm1 + 1;
            if (memw(1, 1536 + i) !== s2_hat[i]) mm2 = mm2 + 1;
            if (memw(2, 1536 + i) !== t0_hat[i]) mm3 = mm3 + 1;
        end
        for (i = 0; i < 4; i = i + 1) if (memw(2, 1040 + i) !== kk[i]) mmk = mmk + 1;
        for (i = 0; i < 2048; i = i + 1) begin
            if (memw(0, i) != 0) resid = resid + 1;
            if (!((i >= 512 && i <= 1023) || i >= 1536 || i <= 171) && memw(1, i) != 0) resid = resid + 1;
            if (!(i >= 1536 || (i >= 1040 && i <= 1043)) && memw(2, i) != 0) resid = resid + 1;
            if (memw(3, i) != 0) resid = resid + 1;
        end
        $display("KG_SEALED_KEY mismatches s1_hat=%0d s2_hat=%0d t0_hat=%0d K=%0d residue_nonzero_non_kept_words=%0d", mm1, mm2, mm3, mmk, resid);
        if (mm1 || mm2 || mm3 || mmk || resid) $fatal(1, "KG_SEALED_KEY_FAIL");
        // ---------------- K4: adversarial sweep after KeyGen ----------------
        build_secret_set(nsec); $display("KG_SECRET_SET distinct_nonzero_halves=%0d", nsec);
        axi_rd(17'h1_001C, seal0, 0);
        sweep("AFTER_KEYGEN", 1);
        axi_rd(17'h1_001C, seal1, 0);
        $display("KG_READ_VIOLATIONS before=%0d after=%0d (sticky rv=%0d)", seal0[31:16], seal1[31:16], seal1[1]);
        if (!seal1[1]) $fatal(1, "READ_VIOLATION_NOT_FLAGGED");
        for (i = 'h40; i <= 'h7C; i = i + 4) begin axi_rd(17'h1_0000 + i, r, 0); if (r != 0) $fatal(1, "REG_LEAK %h", i); end
        // ---------------- K5: refusals while LOCKED ----------------
        axi_wr(17'h1_0000, 32'h20, 0);                       // KEYGEN while LOCKED: refused (OKAY + violation)
        axi_rd(17'h1_0004, st, 0); if (st[0]) $fatal(1, "KEYGEN_WHILE_LOCKED_STARTED");
        sp_write64(1, 512, 64'h1111_2222_3333_4444); sp_write64(1, 1536, 64'h5); sp_write64(2, 1536, 64'h6);
        sp_write64(2, 1040, 64'h7); sp_write64(2, 1160, 64'h8); sp_write64(1, 0, 64'h9); sp_write64(1, 170, 64'ha);
        if (memw(1, 512) !== s1_hat[0] || memw(1, 1536) !== s2_hat[0] || memw(2, 1536) !== t0_hat[0] || memw(2, 1040) !== kk[0] ||
            memw(1, 0) !== pk1[0] || memw(1, 170) !== pk1[170]) $fatal(1, "LOCKED_WRITE_LANDED");
        if (memw(2, 1160) != 0) $fatal(1, "XI_SLOT_WRITE_LANDED");
        axi_wr(17'h1_0080, 32'hDEAD_BEEF, 0); axi_rd(17'h1_0080, r, 0); if (r != pk1[0][31:0]) $fatal(1, "PUBLIC_RHO_OVERWRITTEN");
        axi_rd(17'h1_001C, seal1, 0);
        $display("KG_REFUSED keygen_while_locked + 7 key/xi/pk writes + rho reg write; violations=%0d seal=%h", seal1[31:16], seal1);
        // ---------------- K6: sign-after-keygen (no host key provisioning) ----------------
        for (i = 0; i < 8; i = i + 1) sp_write64(2, 1048 + i, mu[i]);
        axi_wr(17'h1_0000, 32'h1, 0);
        wait_done("SIGN_AFTER_KEYGEN");
        if (!st[2] || !st[13] || st[15] || errs[7:0] != 0) $fatal(1, "SIGN_NOT_OK st=%h errs=%h", st, errs);
        fd = $fopen("capture/ctilde_4x64.hex", "w"); for (i = 0; i < 4; i = i + 1) begin sp_read64(1, 1150 + i, got); $fdisplay(fd, "%016h", got); end $fclose(fd);
        fd = $fopen("capture/z_512x64.hex", "w"); for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1400 + i, got); $fdisplay(fd, "%016h", got); end $fclose(fd);
        fd = $fopen("capture/hint_512x64.hex", "w"); for (i = 0; i < 512; i = i + 1) begin sp_read64(1, i, got); $fdisplay(fd, "%016h", got); end $fclose(fd);
        fd = $fopen("capture/status.txt", "w"); $fdisplay(fd, "kappa=%0d\nattempts=%0d\ncycles=%0d", kap[15:0], kap[31:16], cyc); $fclose(fd);
        $display("KG_SIGN_AFTER_KEYGEN kappa=%0d attempts=%0d cycles=%0d", kap[15:0], kap[31:16], cyc);
        sweep("AFTER_SIGN", 2);
        // ---------------- K7: ZEROIZE, then re-KeyGen with the same xi must reproduce pk exactly ----------------
        axi_wr(17'h1_0000, 32'h10, 0);
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while ((st[12] || st[10]) && t < 20000);
        if (st[10]) $fatal(1, "ZEROIZE_STUCK");
        axi_rd(17'h1_0080, r, 0); if (r != 0) $fatal(1, "RHO_NOT_CLEARED");
        sweep("AFTER_ZEROIZE", 0);
        for (i = 0; i < 4; i = i + 1) sp_write64(2, 1160 + i, xi[i]);
        snapped = 0;
        axi_wr(17'h1_0000, 32'h20, 0);
        wait_done("KEYGEN2");
        if (!st[2] || !st[15]) $fatal(1, "KEYGEN2_NOT_OK st=%h", st);
        for (i = 0; i < 172; i = i + 1) begin sp_read64(1, i, got); if (got !== pk1[i]) $fatal(1, "KEYGEN2_PK_DIFFERS %0d", i); end
        $display("KG_REKEYGEN_IDENTICAL cycles=%0d", cyc);
        // ---------------- K8: reset ----------------
        aresetn = 0; repeat (10) @(negedge aclk); aresetn = 1;
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4]) && t < 5000);
        sweep("AFTER_RESET", 0);
        $display("KG_AGENT_PASS axi_writes=%0d axi_reads=%0d", nwr, nrd);
        $finish;
    end
endmodule
