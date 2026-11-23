`timescale 1ns/1ps
// seal_v8 phase 3: KeyGen KAT in the PL (build-time KAT_XI=1 injects xi; board build draws xi from the PL TRNG).
//  K1 KEYGEN -> rho, t1 read through the PS window == oracle pk (dilithium-py 1.5.1 KeyGen_internal(xi))
//  K2 READ-ONLY peek: sealed homes hold exactly s1_hat, s2_hat, t0_hat, K of the oracle sk; every other word
//     except A_hat / rho / t1 is zero (no xi, rho', s1, s2, t, t0 residue)
//  K3 LOCKED: key words read 0; hardware-captured public rho == pk rho; KEYGEN while LOCKED is refused
//  K4 SIGN after KEYGEN (DET_RND=1) -> capture; checker: equals oracle deterministic signature and verifies under pk
module tb_keygen;
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;
    reg aresetn = 0;
    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg  awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0; reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0] bresp, rresp; wire [31:0] rdata;
    wepwawet_sign_axil #(.MAX_ATTEMPTS(255), .DET_RND(1), .KAT_XI(1)) dut (
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

    reg [63:0] xi [0:3]; reg [63:0] rho [0:3]; reg [63:0] kk [0:3]; reg [63:0] mu [0:7]; reg [63:0] t1 [0:511];
    reg [63:0] s1_hat [0:511]; reg [63:0] s2_hat [0:511]; reg [63:0] t0_hat [0:511];
    integer k1bad, ms1, ms2, mt0, mk, i, t, a, bad, r, cfd, zfd, hfd, mfd; reg [31:0] st, kap, errs, cyc, x, sreg; reg [63:0] got;
    task automatic wait_ready; begin
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4] && !st[12]) && t < 20000);
        if (!(st[3] && !st[4] && !st[12])) $fatal(1, "READY_TIMEOUT st=%h", st);
    end endtask
    task automatic run_job(input [31:0] ctrl); begin
        axi_wr(17'h1_0000, ctrl, 0);
        t = 0; do begin repeat (2000) @(posedge aclk); axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!st[1] && t < 200000);
        if (!st[1]) $fatal(1, "JOB_TIMEOUT");
        axi_rd(17'h1_0008, kap, 0); axi_rd(17'h1_000C, errs, 0); axi_rd(17'h1_0010, cyc, 0);
        $display("KG_JOB ctrl=%h status=%h kappa=%0d attempts=%0d errors=%h cycles=%0d", ctrl, st, kap[15:0], kap[31:16], errs, cyc);
        axi_wr(17'h1_0000, 32'h2, 0);
    end endtask
    initial begin
        $readmemh("vectors/xi_4x64.mem", xi); $readmemh("vectors/rho_4x64.mem", rho); $readmemh("vectors/k_4x64.mem", kk);
        $readmemh("vectors/mu_8x64.mem", mu); $readmemh("vectors/t1_512x64.mem", t1);
        $readmemh("vectors/s1_hat_512x64.mem", s1_hat); $readmemh("vectors/s2_hat_512x64.mem", s2_hat); $readmemh("vectors/t0_hat_512x64.mem", t0_hat);
        repeat (10) @(negedge aclk); aresetn = 1;
        axi_rd(17'h1_0018, x, 0); if (x != 32'h0003_0003) $fatal(1, "VERSION %h", x);
        wait_ready;
        for (i = 0; i < 4; i = i + 1) sp_write64(2, 1160 + i, xi[i]);          // KAT build only
        run_job(32'h20);
        if (!st[2] || !st[15] || !st[10] || errs[7:0] != 0) $fatal(1, "K1_KEYGEN_FAILED st=%h errs=%h", st, errs);
        bad = 0;
        for (i = 0; i < 4; i = i + 1) begin sp_read64(2, 1028 + i, got); if (got !== rho[i]) bad = bad + 1; end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1536 + i, got); if (got !== t1[i]) begin if (bad < 4) $display("T1_MISMATCH %0d got=%h exp=%h", i, got, t1[i]); bad = bad + 1; end end
        $display("KG_K1 pk(rho,t1) mismatches=%0d cycles=%0d", bad, cyc); k1bad = bad;
        cfd = $fopen("capture/t1_512x64.hex", "w"); for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1536 + i, got); $fdisplay(cfd, "%016h", got); end $fclose(cfd);
        bad = 0; r = 0; ms1 = 0; ms2 = 0; mt0 = 0; mk = 0;
        for (a = 0; a < 2048; a = a + 1) begin
            if (a >= 512 && a < 1024 && dut.u_core.u_wcore.u_sp.BANK[1].mem[a] !== s1_hat[a-512]) begin ms1 = ms1 + 1; if (ms1 < 3) $display("S1H_MISMATCH %0d got=%h exp=%h", a-512, dut.u_core.u_wcore.u_sp.BANK[1].mem[a], s1_hat[a-512]); end
            if (a >= 1536 && dut.u_core.u_wcore.u_sp.BANK[1].mem[a] !== s2_hat[a-1536]) ms2 = ms2 + 1;
            if (a >= 1536 && dut.u_core.u_wcore.u_sp.BANK[2].mem[a] !== t0_hat[a-1536]) begin mt0 = mt0 + 1; if (mt0 < 3) $display("T0H_MISMATCH %0d got=%h exp=%h", a-1536, dut.u_core.u_wcore.u_sp.BANK[2].mem[a], t0_hat[a-1536]); end
            if (a >= 1040 && a <= 1043 && dut.u_core.u_wcore.u_sp.BANK[2].mem[a] !== kk[a-1040]) mk = mk + 1;
            if (a >= 512 && a < 1024) begin if (dut.u_core.u_wcore.u_sp.BANK[1].mem[a] !== s1_hat[a-512]) bad = bad + 1; end
            else if (a >= 1536) begin if (dut.u_core.u_wcore.u_sp.BANK[1].mem[a] !== s2_hat[a-1536]) bad = bad + 1; end
            else if (dut.u_core.u_wcore.u_sp.BANK[1].mem[a] != 0) r = r + 1;
            if (a >= 1536) begin if (dut.u_core.u_wcore.u_sp.BANK[2].mem[a] !== t0_hat[a-1536]) bad = bad + 1; end
            else if (a >= 1040 && a <= 1043) begin if (dut.u_core.u_wcore.u_sp.BANK[2].mem[a] !== kk[a-1040]) bad = bad + 1; end
            else if (!(a >= 1028 && a <= 1031) && dut.u_core.u_wcore.u_sp.BANK[2].mem[a] != 0) r = r + 1;
            if (a < 1536 && dut.u_core.u_wcore.u_sp.BANK[3].mem[a] != 0) r = r + 1;
        end
        $display("KG_K2 sealed_key_mismatches=%0d (s1_hat %0d s2_hat %0d t0_hat %0d K %0d) residue_nonzero=%0d", bad, ms1, ms2, mt0, mk, r);
        if (k1bad) $fatal(1, "K1_PK_MISMATCH"); if (bad || r) $fatal(1, "K2_FAILED");
        sp_read64(1, 512, got); if (got != 0) $fatal(1, "K3_S1_READABLE");
        sp_read64(2, 1040, got); if (got != 0) $fatal(1, "K3_K_READABLE");
        for (i = 0; i < 4; i = i + 1) begin axi_rd(17'h1_0080 + 8*i, x, 0); if (x != rho[i][31:0]) $fatal(1, "K3_RHO_REG %0d %h", i, x); end
        axi_rd(17'h1_001C, sreg, 0); axi_wr(17'h1_0000, 32'h20, 0); axi_rd(17'h1_001C, x, 0);
        if (x[31:16] != sreg[31:16] + 1) $fatal(1, "K3_KEYGEN_NOT_REFUSED");
        $display("KG_K3 locked: key words read 0, public rho captured by hardware, KEYGEN refused while LOCKED");
        for (i = 0; i < 8; i = i + 1) sp_write64(2, 1048 + i, mu[i]);
        run_job(32'h1);
        if (!st[2] || errs[7:0] != 0) $fatal(1, "K4_SIGN_FAILED");
        cfd = $fopen("capture/ctilde_4x64.hex", "w"); zfd = $fopen("capture/z_512x64.hex", "w"); hfd = $fopen("capture/hint_512x64.hex", "w");
        for (i = 0; i < 4; i = i + 1)   begin sp_read64(1, 1150 + i, got); $fdisplay(cfd, "%016h", got); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1400 + i, got); $fdisplay(zfd, "%016h", got); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(1, i, got); $fdisplay(hfd, "%016h", got); end
        $fclose(cfd); $fclose(zfd); $fclose(hfd);
        mfd = $fopen("capture/status.txt", "w"); $fdisplay(mfd, "kappa=%0d\nattempts=%0d\ncycles=%0d", kap[15:0], kap[31:16], cyc); $fclose(mfd);
        $display("KG_V8_PASS");
        $finish;
    end
endmodule
