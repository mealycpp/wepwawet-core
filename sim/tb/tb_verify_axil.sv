`timescale 1ns/1ps
// WEPWAWET verify_v1: FPGA ML-DSA-44 VERIFY through the AXI4-Lite slave. Everything is done through the
// single AXI4-Lite slave exactly as the ARM will do it on the AUP:
//   preload key material / mu / first-attempt mask messages -> write rho'' and
//   rho registers -> LAUNCH -> poll STATUS -> read c~, z, h -> capture files.
// No hierarchical pokes into the DUT except read-only activity counters.
module tb_verify_axil;
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;          // 300 MHz
    reg aresetn = 0;
    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg  awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0; reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0] bresp, rresp; wire [31:0] rdata;

    wepwawet_sign_axil #(.MAX_ATTEMPTS(255)) dut (
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

    reg [63:0] rho [0:3]; reg [63:0] mu [0:7]; reg [63:0] ctl [0:3]; reg [63:0] ctp [0:3];
    reg [63:0] zz [0:511]; reg [63:0] hh [0:511]; reg [63:0] t1h [0:511];
    reg [63:0] wap [0:511]; reg [63:0] w1p [0:511];
    integer i, t, bad_w, bad_w1, zrej, mfd; reg [31:0] st, kap, errs, cyc, magic, ver; reg [63:0] got;
    reg ct_match; reg [7:0] zrej_m [0:0];
    initial begin
        ct_match = 0;
        $readmemh("vectors/zrej.mem", zrej_m); zrej = (zrej_m[0] == 8'h01);
        $readmemh("vectors/rho_4x64.mem", rho); $readmemh("vectors/mu_8x64.mem", mu);
        $readmemh("vectors/ctilde_4x64.mem", ctl); $readmemh("vectors/ctilde_prime_4x64.mem", ctp);
        $readmemh("vectors/z_512x64.mem", zz); $readmemh("vectors/h_512x64.mem", hh);
        $readmemh("vectors/t1hat2d_512x64.mem", t1h);
        $readmemh("vectors/wapprox_512x64.mem", wap); $readmemh("vectors/w1p_512x64.mem", w1p);
        repeat (10) @(negedge aclk); aresetn = 1;
        axi_rd(17'h1_0014, magic, 0); axi_rd(17'h1_0018, ver, 0);
        if (magic != 32'h5743_5331 || ver != 32'h0003_0003) $fatal(1, "MAGIC/VERSION %h %h", magic, ver);
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4]) && t < 5000);
        if (!(st[3] && !st[4])) $fatal(1, "SCRATCHPAD_INIT_TIMEOUT st=%h", st);
        // ---- PS preload (verify contract) ----
        for (i = 0; i < 4; i = i + 1)   sp_write64(2, 512 + i, rho[i]);
        for (i = 0; i < 8; i = i + 1)   sp_write64(2, 1048 + i, mu[i]);   // phase 2: mu at b2[1048..]
        for (i = 0; i < 4; i = i + 1)   sp_write64(1, 1150 + i, ctl[i]);
        for (i = 0; i < 512; i = i + 1) begin
            sp_write64(3, i, zz[i]); sp_write64(3, 512 + i, hh[i]); sp_write64(3, 1536 + i, t1h[i]);   // seal_v8: t1'_hat at b3[1536..]
        end
        for (i = 0; i < 4; i = i + 1) begin
            axi_wr(17'h1_0080 + 8*i, rho[i][31:0], 0); axi_wr(17'h1_0084 + 8*i, rho[i][63:32], 0);
        end
        $display("VERIFYV1_PRELOAD_DONE axi_writes=%0d", nwr);
        axi_wr(17'h1_0000, 32'h5, 0);                         // LAUNCH | MODE_VERIFY
        t = 0;
        do begin repeat (2000) @(posedge aclk); axi_rd(17'h1_0004, st, 0); t = t + 1; end
        while (!st[1] && t < 200000);
        if (!st[1]) $fatal(1, "VERIFY_TIMEOUT st=%h", st);
        axi_rd(17'h1_0008, kap, 0); axi_rd(17'h1_000C, errs, 0); axi_rd(17'h1_0010, cyc, 0);
        $display("VERIFYV1_DONE status=%h attempts=%0d errors=%h pc=%0d cycles=%0d irq=%b mode=%b",
                 st, kap[31:16], errs, errs[23:16], cyc, irq, st[9]);
        if (!st[9]) $fatal(1, "MODE_BIT_NOT_SET");
        if (kap[31:16] != 1) $fatal(1, "VERIFY_MUST_BE_SINGLE_PASS attempts=%0d", kap[31:16]);
        if (zrej) begin
            if (st[2] || errs[7:0] != 8'h06 || errs[23:16] != 8'd235) $fatal(1, "ZNORM_REJECT_EXPECTED st=%h errs=%h", st, errs);
            $display("VERIFYV1_RESULT verdict=REJECT reason=z_norm cycles=%0d", cyc);
        end else begin
            if (!st[2] || st[6] || errs[7:0] != 0 || errs[23:16] != 8'd234) $fatal(1, "VERIFY_PROGRAM_FAILED st=%h errs=%h", st, errs);
            bad_w = 0; bad_w1 = 0;
            for (i = 0; i < 512; i = i + 1) begin
                sp_read64(3, 1024 + i, got); if (got !== wap[i]) begin if (bad_w < 4) $display("WAPPROX_MISMATCH i=%0d got=%h exp=%h", i, got, wap[i]); bad_w = bad_w + 1; end
                sp_read64(3, 512 + i, got);  if (got !== w1p[i]) begin if (bad_w1 < 4) $display("W1P_MISMATCH i=%0d got=%h exp=%h", i, got, w1p[i]); bad_w1 = bad_w1 + 1; end
            end
            $display("VERIFYV1_INTERMEDIATES wapprox_mismatch=%0d w1prime_mismatch=%0d", bad_w, bad_w1);
            if (bad_w || bad_w1) $fatal(1, "INTERMEDIATE_MISMATCH");
            ct_match = 1;
            for (i = 0; i < 4; i = i + 1) begin
                sp_read64(1, 1150 + i, got);
                if (got !== ctp[i]) $fatal(1, "CTILDE_PRIME_MISMATCH i=%0d got=%h exp=%h", i, got, ctp[i]);
                if (got !== ctl[i]) ct_match = 0;
            end
            $display("VERIFYV1_RESULT verdict=%s ctilde_prime==oracle ctilde_prime==sig_ctilde=%0d cycles=%0d",
                     ct_match ? "ACCEPT" : "REJECT", ct_match, cyc);
        end
        mfd = $fopen("capture/status.txt", "w");
        $fdisplay(mfd, "status=%h\nerrors=%h\ncycles=%0d\nverdict_accept=%0d", st, errs, cyc, (!zrej && ct_match));
        $fclose(mfd);
        $finish;
    end
endmodule
