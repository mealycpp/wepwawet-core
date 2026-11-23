`timescale 1ns/1ps
// seal_v8 phase 2: HEDGED signing with the PL TRNG path (DET_RND=0, i.e. the board configuration).
// TRNG model: one 32-bit word every 64 cycles while trng_claim (real source: ~512 cycles/word).
//  H1 two SIGNs of the same message -> different signatures (fresh rnd), both must verify (checker)
//  H2 stuck-at-0 source -> RCT failure -> fail closed (no output readable, TRNG reg code 3, residue 0)
//  H3 Stage-8 hardware flag stuck -> 3 redraws -> fail closed (code 2)
//  H4 every raw word drawn for rnd is consumed only by the PL (claim window, 64 words/draw)
module tb_hedged;
    wire claim; reg [31:0] tw = 0; reg tv = 0, thf = 0; integer tmode = 0, words_given = 0, gap = 0;
    always @(posedge aclk) begin
        tv <= 0;
        if (claim) begin
            gap <= gap + 1;
            if (gap >= 63) begin gap <= 0; tv <= 1; words_given <= words_given + 1;
                tw <= (tmode == 1) ? 32'd0 : $urandom; end
        end else gap <= 0;
        thf <= (tmode == 2) && claim;
    end
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;
    reg aresetn = 0;
    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg  awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0; reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0] bresp, rresp; wire [31:0] rdata;
    wepwawet_sign_axil #(.MAX_ATTEMPTS(255), .DET_RND(0)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .irq(irq), .trng_claim(claim), .trng_word(tw), .trng_valid(tv), .trng_health_fail(thf));
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

    reg [63:0] rho [0:3]; reg [63:0] mu [0:7]; reg [63:0] kk [0:3];
    reg [63:0] s1_hat [0:511]; reg [63:0] s2_hat [0:511]; reg [63:0] t0_hat [0:511];
    reg [63:0] ca [0:3]; integer i, t, cfd, zfd, hfd, diff, r, a;
    reg [31:0] st, kap, errs, cyc, magic, ver, x, tr; reg [63:0] got;
    task automatic wait_ready; begin
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4] && !st[12]) && t < 20000);
        if (!(st[3] && !st[4] && !st[12])) $fatal(1, "READY_TIMEOUT st=%h", st);
    end endtask
    task automatic sign_job; begin
        for (i = 0; i < 8; i = i + 1) sp_write64(2, 1048 + i, mu[i]);
        words_given = 0;
        axi_wr(17'h1_0000, 32'h1, 0);
        t = 0; do begin repeat (2000) @(posedge aclk); axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!st[1] && t < 200000);
        if (!st[1]) $fatal(1, "JOB_TIMEOUT");
        axi_rd(17'h1_0008, kap, 0); axi_rd(17'h1_000C, errs, 0); axi_rd(17'h1_0010, cyc, 0); axi_rd(17'h1_0020, tr, 0);
        $display("HEDGED_JOB tmode=%0d status=%h kappa=%0d attempts=%0d errors=%h cycles=%0d trng=%h (apt=%0d run=%0d redraws=%0d code=%0d) words=%0d",
                 tmode, st, kap[15:0], kap[31:16], errs, cyc, tr, tr[10:0], tr[16:11], tr[20:17], tr[24:21], words_given);
        axi_wr(17'h1_0000, 32'h2, 0);
    end endtask
    task automatic capture(input [7:0] tag); begin
        cfd = $fopen(tag == "A" ? "capture/A_ctilde_4x64.hex" : "capture/B_ctilde_4x64.hex", "w");
        zfd = $fopen(tag == "A" ? "capture/A_z_512x64.hex" : "capture/B_z_512x64.hex", "w");
        hfd = $fopen(tag == "A" ? "capture/A_hint_512x64.hex" : "capture/B_hint_512x64.hex", "w");
        for (i = 0; i < 4; i = i + 1)   begin sp_read64(1, 1150 + i, got); $fdisplay(cfd, "%016h", got); if (tag == "A") ca[i] = got; else if (got !== ca[i]) diff = diff + 1; end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1400 + i, got); $fdisplay(zfd, "%016h", got); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(1, i, got); $fdisplay(hfd, "%016h", got); end
        $fclose(cfd); $fclose(zfd); $fclose(hfd);
    end endtask
    task automatic residue0(input [255:0] tagname); begin       // READ-ONLY: failed job leaves only key material
        r = 0;
        for (a = 0; a < 2048; a = a + 1) begin
            if (!((a >= 512 && a <= 1023) || a >= 1536) && dut.u_core.u_wcore.u_sp.BANK[1].mem[a] != 0) r = r + 1;
            if (!(a >= 1536 || (a >= 1040 && a <= 1043)) && dut.u_core.u_wcore.u_sp.BANK[2].mem[a] != 0) r = r + 1;
            if (dut.u_core.u_wcore.u_sp.BANK[3].mem[a] != 0) r = r + 1;
        end
        $display("HEDGED_RESIDUE %0s nonzero=%0d", tagname, r); if (r) $fatal(1, "RESIDUE %0s", tagname);
    end endtask
    initial begin
        $readmemh("vectors/rho_4x64.mem", rho); $readmemh("vectors/mu_8x64.mem", mu); $readmemh("vectors/k_4x64.mem", kk);
        $readmemh("vectors/s1_hat_512x64.mem", s1_hat); $readmemh("vectors/s2_hat_512x64.mem", s2_hat);
        $readmemh("vectors/t0_hat_512x64.mem", t0_hat);
        repeat (10) @(negedge aclk); aresetn = 1;
        axi_rd(17'h1_0018, ver, 0); if (ver != 32'h0003_0103) $fatal(1, "VERSION %h", ver);
        wait_ready;
        for (i = 0; i < 512; i = i + 1) begin sp_write64(1, 512 + i, s1_hat[i]); sp_write64(1, 1536 + i, s2_hat[i]); sp_write64(2, 1536 + i, t0_hat[i]); end
        for (i = 0; i < 4; i = i + 1) begin axi_wr(17'h1_0080 + 8*i, rho[i][31:0], 0); axi_wr(17'h1_0084 + 8*i, rho[i][63:32], 0); end
        for (i = 0; i < 4; i = i + 1) sp_write64(2, 1040 + i, kk[i]);
        axi_wr(17'h1_0000, 32'h8, 0);
        // H1
        diff = 0; tmode = 0;
        sign_job; if (!st[2] || errs[7:0] != 0 || tr[24:21] != 0 || tr[25]) $fatal(1, "H1A_FAILED");
        if (words_given < 64) $fatal(1, "H4_WORDS %0d", words_given);
        capture("A");
        sign_job; if (!st[2] || errs[7:0] != 0) $fatal(1, "H1B_FAILED");
        capture("B");
        $display("HEDGED_H1 ctilde_words_differing=%0d (expect 4)", diff); if (diff != 4) $fatal(1, "H1_SAME_SIGNATURE");
        // H2 stuck-at-0
        tmode = 1; sign_job;
        if (st[2] || st[13] || errs[7:0] != 8'h08 || tr[24:21] != 4'd3) $fatal(1, "H2_NOT_FAIL_CLOSED st=%h errs=%h trng=%h", st, errs, tr);
        sp_read64(3, 1400, got); if (got != 0) $fatal(1, "H2_Z_READABLE");
        residue0("AFTER_RCT_FAIL");
        // H3 hardware flag stuck
        tmode = 2; sign_job;
        if (st[2] || errs[7:0] != 8'h08 || tr[24:21] != 4'd2 || tr[20:17] != 4'd3) $fatal(1, "H3_NOT_FAIL_CLOSED st=%h errs=%h trng=%h", st, errs, tr);
        residue0("AFTER_HWFLAG_FAIL");
        // recovery: healthy source signs again
        tmode = 0; sign_job; if (!st[2]) $fatal(1, "H_RECOVERY_FAILED");
        $display("HEDGED_V8_PASS");
        $finish;
    end
endmodule
