`timescale 1ns/1ps
// WEPWAWET SIGN image: PS-view regression. Everything is done through the
// single AXI4-Lite slave exactly as the ARM will do it on the AUP:
//   preload key material / mu / first-attempt mask messages -> write rho'' and
//   rho registers -> LAUNCH -> poll STATUS -> read c~, z, h -> capture files.
// No hierarchical pokes into the DUT except read-only activity counters.
// seal_v8 phase 2 version: the host provides only K (b2[1040..1043], provisioning), s1/s2/t0_hat, public rho,
// mu (b2[1048..1055]). rho'' is computed in the PL (prologue PC237 with build-time DET_RND=1, rnd = 0^32,
// = FIPS 204 deterministic variant used by the oracle vectors). TRNG port idle.
module tb_sign_p2;
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;          // 300 MHz
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
            @(negedge aclk); awaddr = a; wdata = d; awvalid = 1; wvalid = 1; bready = 1;
            t = 0;
            while ((awvalid || wvalid) && t < 2000) begin
                @(posedge aclk); #0.01;
                if (awvalid && awready) awvalid = 0;
                if (wvalid && wready) wvalid = 0;
                t = t + 1;
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

    // read-only activity probes (real HLS traffic must happen)
    integer poly_tx = 0, poly_rx = 0;
    always @(posedge aclk) if (aresetn) begin
        if (dut.u_core.u_wcore.u_aux.u_dot4.poly_in_tvalid  && dut.u_core.u_wcore.u_aux.u_dot4.poly_in_tready)  poly_tx <= poly_tx + 1;
        if (dut.u_core.u_wcore.u_aux.u_dot4.poly_out_tvalid && dut.u_core.u_wcore.u_aux.u_dot4.poly_out_tready) poly_rx <= poly_rx + 1;
    end

    reg [63:0] rho [0:3]; reg [63:0] mu [0:7]; reg [63:0] seed_nonce [0:35]; reg [63:0] kk [0:3];
    reg [63:0] s1_hat [0:511]; reg [63:0] s2_hat [0:511]; reg [63:0] t0_hat [0:511];
    integer i, t, cfd, zfd, hfd, mfd;
    reg [31:0] st, kap, errs, cyc, magic; reg [63:0] got;

    initial begin
        $readmemh("vectors/rho_4x64.mem", rho);
        $readmemh("vectors/mu_8x64.mem", mu);
        $readmemh("vectors/candidate_mask_seed_nonce_36x64.mem", seed_nonce);
        $readmemh("vectors/s1_hat_512x64.mem", s1_hat);
        $readmemh("vectors/s2_hat_512x64.mem", s2_hat);
        $readmemh("vectors/t0_hat_512x64.mem", t0_hat);
        $readmemh("vectors/k_4x64.mem", kk);
        repeat (10) @(negedge aclk); aresetn = 1;

        axi_rd(17'h1_0014, magic, 0);
        if (magic != 32'h5743_5331) $fatal(1, "MAGIC_MISMATCH %h", magic);
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4]) && t < 5000);
        if (!(st[3] && !st[4])) $fatal(1, "SCRATCHPAD_INIT_TIMEOUT st=%h", st);
        $display("SIGNV2_SCRATCHPAD_READY");

        // --- PS preload (same placement as the frozen V7 regression) ---
        for (i = 0; i < 4; i = i + 1)   sp_write64(2, 512 + i, rho[i]);
        for (i = 0; i < 4; i = i + 1)   sp_write64(2, 1040 + i, kk[i]);      // K (sealed after LOCK)
        for (i = 0; i < 8; i = i + 1)   sp_write64(2, 1048 + i, mu[i]);      // mu (phase 2 ABI)
        for (i = 0; i < 512; i = i + 1) begin
            sp_write64(1, 512 + i,  s1_hat[i]);
            sp_write64(1, 1536 + i, s2_hat[i]);
            sp_write64(2, 1536 + i, t0_hat[i]);
        end
        // read-back spot check through the same window
        sp_read64(1, 512, got);  if (got !== s1_hat[0])  $fatal(1, "READBACK_S1 %h", got);
        sp_read64(2, 2047, got); if (got !== t0_hat[511]) $fatal(1, "READBACK_T0 %h", got);
        // public rho (8 words); no rho'' from the host in phase 2
        for (i = 0; i < 4; i = i + 1) begin
            axi_wr(17'h1_0080 + 8*i, rho[i][31:0], 0);
            axi_wr(17'h1_0084 + 8*i, rho[i][63:32], 0);
        end
        $display("SIGNV2_PRELOAD_DONE axi_writes=%0d", nwr);

        // --- negative checks before launch ---
        axi_wr(17'h1_0300, 32'h1, 1);                         // unmapped register
        // --- LAUNCH: from here on the PS only polls ---
        axi_wr(17'h1_0000, 32'h1, 0);
        axi_rd(spa(1, 0, 0), got[31:0], 1);                   // window locked while busy
        axi_wr(17'h1_0040, 32'hDEAD, 1);                      // (former rho'' reg) refused while busy
        t = 0;
        do begin repeat (2000) @(posedge aclk); axi_rd(17'h1_0004, st, 0); t = t + 1; end
        while (!st[1] && t < 200000);
        if (!st[1]) $fatal(1, "SIGN_TIMEOUT st=%h", st);
        axi_rd(17'h1_0008, kap, 0); axi_rd(17'h1_000C, errs, 0); axi_rd(17'h1_0010, cyc, 0);
        $display("SIGNV2_DONE status=%h kappa=%0d attempts=%0d errors=%h cycles=%0d irq=%b",
                 st, kap[15:0], kap[31:16], errs, cyc, irq);
        if (!st[2] || st[5] || st[6] || errs[7:0] != 0) $fatal(1, "SIGN_NOT_SUCCESSFUL st=%h errs=%h", st, errs);
        if (kap[15:0] != 4*(kap[31:16]-1)) $fatal(1, "KAPPA_ATTEMPTS_INCONSISTENT %h", kap);
        if (!irq) $fatal(1, "IRQ_NOT_RAISED");
        if (poly_tx != 7168*kap[31:16] || poly_rx != 3584*kap[31:16]) $fatal(1, "HLS_POLYMUL_ACTIVITY %0d/%0d", poly_tx, poly_rx);
        axi_rd(17'h1_0040, st, 0); if (st != 0) $fatal(1, "SEED_NOT_CLEARED");

        // --- read result through the PS window ---
        cfd = $fopen("capture/ctilde_4x64.hex", "w"); zfd = $fopen("capture/z_512x64.hex", "w");
        hfd = $fopen("capture/hint_512x64.hex", "w"); mfd = $fopen("capture/status.txt", "w");
        for (i = 0; i < 4; i = i + 1)   begin sp_read64(1, 1150 + i, got); $fdisplay(cfd, "%016h", got); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1400 + i, got); $fdisplay(zfd, "%016h", got); end
        for (i = 0; i < 512; i = i + 1) begin sp_read64(1, i, got);        $fdisplay(hfd, "%016h", got); end
        $fdisplay(mfd, "kappa=%0d\nattempts=%0d\ncycles=%0d\naxi_writes=%0d\naxi_reads=%0d\npoly_tx=%0d", kap[15:0], kap[31:16], cyc, nwr, nrd, poly_tx);
        $fclose(cfd); $fclose(zfd); $fclose(hfd); $fclose(mfd);
        $display("SIGNV2_AXI_LITE_FULL_SIGN_CAPTURE_DONE cycles=%0d us_at_300MHz=%0d", cyc, cyc / 300);
        $finish;
    end
endmodule
