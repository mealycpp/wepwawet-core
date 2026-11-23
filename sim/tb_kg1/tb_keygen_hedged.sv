`timescale 1ns/1ps
// KEYGEN: BOARD configuration (DET_XI=0, DET_RND=0): xi from the PL TRNG path. TRNG model as tb_hedged.
//  G1 host pre-writes a known xi into b2[1160..1163]: ignored (checker: pk != PQClean(that xi))
//  G2 two KeyGens (ZEROIZE between) -> different pk; host computes mu from the PL tr; hedged sign verifies under each pk
//  G3 stuck-at-0 TRNG -> KeyGen fails closed: no pk window, every bank zero (keys too), error 08
//  G4 recovery after ZEROIZE
module tb_keygen_hedged;
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;
    reg aresetn = 0;
    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg  awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0; reg [3:0] wstrb = 4'hF;
    wire awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0] bresp, rresp; wire [31:0] rdata;
    wepwawet_sign_axil #(.MAX_ATTEMPTS(255), .DET_RND(0), .DET_XI(0)) dut (
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


    wire claim; reg [31:0] tw = 0; reg tv = 0, thf = 0; integer tmode = 0, words_given = 0, gap = 0;
    always @(posedge aclk) begin
        tv <= 0;
        if (claim) begin
            gap <= gap + 1;
            if (gap >= 63) begin gap <= 0; tv <= 1; words_given <= words_given + 1; tw <= (tmode == 1) ? 32'd0 : $urandom; end
        end else gap <= 0;
        thf <= (tmode == 2) && claim;
    end
    reg [63:0] xi [0:3]; reg [63:0] mu [0:7]; reg [63:0] pkA [0:171];
    integer i, t, fd, r, a, same;
    reg [31:0] st, kap, errs, cyc, ver, trg; reg [63:0] got;
    task automatic wait_done(input [8*20-1:0] tag);
        begin t = 0;
            do begin repeat (2000) @(posedge aclk); axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!st[1] && t < 100000);
            if (!st[1]) $fatal(1, "TIMEOUT %0s st=%h", tag, st);
            axi_rd(17'h1_0008, kap, 0); axi_rd(17'h1_000C, errs, 0); axi_rd(17'h1_0010, cyc, 0); axi_rd(17'h1_0020, trg, 0);
            $display("KGH_JOB %0s status=%h kappa=%0d attempts=%0d errors=%h cycles=%0d trng=%h words=%0d", tag, st, kap[15:0], kap[31:16], errs, cyc, trg, words_given);
            axi_wr(17'h1_0000, 32'h2, 0);
        end endtask
    task automatic zeroize; begin
        axi_wr(17'h1_0000, 32'h10, 0);
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while ((st[12] || st[10]) && t < 20000);
        if (st[10]) $fatal(1, "ZEROIZE_STUCK");
    end endtask
    task automatic keygen_sign(input [7:0] tag); begin
        for (i = 0; i < 4; i = i + 1) sp_write64(2, 1160 + i, xi[i]);   // G1: host tries to choose xi
        words_given = 0; axi_wr(17'h1_0000, 32'h20, 0); wait_done(tag == "A" ? "KEYGEN_A" : "KEYGEN_B");
        if (!st[2] || !st[15] || !st[10] || errs[7:0] != 0 || words_given < 64) $fatal(1, "KEYGEN_%c_NOT_OK st=%h words=%0d", tag, st, words_given);
        $display("KGH_CYCLES keygen_%c=%0d (incl. TRNG draw, model 64 cyc/word)", tag, cyc);
        fd = $fopen(tag == "A" ? "capture/A_pk_tr_172x64.hex" : "capture/B_pk_tr_172x64.hex", "w");
        same = 0;
        for (i = 0; i < 172; i = i + 1) begin sp_read64(1, i, got); $fdisplay(fd, "%016h", got);
            if (tag == "A") pkA[i] = got; else if (got === pkA[i]) same = same + 1; end
        $fclose(fd);
        if (tag == "B") begin $display("KGH_G2 pk_words_equal_A=%0d of 172", same); if (same > 4) $fatal(1, "G2_SAME_PK"); end
        r = $system(tag == "A" ? "python3 tools/mu_from_tr.py capture/A_pk_tr_172x64.hex vectors/msg.bin capture/A_mu.mem"
                               : "python3 tools/mu_from_tr.py capture/B_pk_tr_172x64.hex vectors/msg.bin capture/B_mu.mem");
        if (r != 0) $fatal(1, "MU_TOOL");
        if (tag == "A") $readmemh("capture/A_mu.mem", mu); else $readmemh("capture/B_mu.mem", mu);
        for (i = 0; i < 8; i = i + 1) sp_write64(2, 1048 + i, mu[i]);
        words_given = 0; axi_wr(17'h1_0000, 32'h1, 0); wait_done(tag == "A" ? "SIGN_A" : "SIGN_B");
        if (!st[2] || !st[13] || errs[7:0] != 0) $fatal(1, "SIGN_%c_NOT_OK st=%h errs=%h", tag, st, errs);
        fd = $fopen(tag == "A" ? "capture/A_ctilde_4x64.hex" : "capture/B_ctilde_4x64.hex", "w"); for (i = 0; i < 4; i = i + 1) begin sp_read64(1, 1150 + i, got); $fdisplay(fd, "%016h", got); end $fclose(fd);
        fd = $fopen(tag == "A" ? "capture/A_z_512x64.hex" : "capture/B_z_512x64.hex", "w"); for (i = 0; i < 512; i = i + 1) begin sp_read64(3, 1400 + i, got); $fdisplay(fd, "%016h", got); end $fclose(fd);
        fd = $fopen(tag == "A" ? "capture/A_hint_512x64.hex" : "capture/B_hint_512x64.hex", "w"); for (i = 0; i < 512; i = i + 1) begin sp_read64(1, i, got); $fdisplay(fd, "%016h", got); end $fclose(fd);
    end endtask
    initial begin
        $readmemh("vectors/xi_4x64.mem", xi);
        repeat (10) @(negedge aclk); aresetn = 1;
        axi_rd(17'h1_0018, ver, 0); if (ver != 32'h0003_0103) $fatal(1, "VERSION %h", ver);
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4]) && t < 5000);
        keygen_sign("A"); zeroize; keygen_sign("B"); zeroize;
        // G3 stuck-at-0 source
        tmode = 1; words_given = 0; axi_wr(17'h1_0000, 32'h20, 0); wait_done("KEYGEN_STUCK0");
        if (st[2] || st[15] || errs[7:0] != 8'h08 || trg[24:21] != 4'd3) $fatal(1, "G3_NOT_FAIL_CLOSED st=%h errs=%h trng=%h", st, errs, trg);
        r = 0;
        for (a = 0; a < 2048; a = a + 1) begin
            if (dut.u_core.u_wcore.u_sp.BANK[0].mem[a] != 0) r = r + 1; if (dut.u_core.u_wcore.u_sp.BANK[1].mem[a] != 0) r = r + 1;
            if (dut.u_core.u_wcore.u_sp.BANK[2].mem[a] != 0) r = r + 1; if (dut.u_core.u_wcore.u_sp.BANK[3].mem[a] != 0) r = r + 1;
        end
        same = 0; for (i = 0; i < 172; i = i + 1) begin sp_read64(1, i, got); if (got != 0) same = same + 1; end
        $display("KGH_G3 fail_closed errs=%h trng_code=%0d residue_all_banks=%0d pk_window_nonzero=%0d locked=%0d", errs, trg[24:21], r, same, st[10]);
        if (r || same) $fatal(1, "G3_RESIDUE");
        // G4 recovery
        zeroize; tmode = 0; words_given = 0; axi_wr(17'h1_0000, 32'h20, 0); wait_done("KEYGEN_RECOVERY");
        if (!st[2] || !st[15]) $fatal(1, "G4_RECOVERY_FAILED");
        $display("KGH_AGENT_PASS axi_writes=%0d axi_reads=%0d", nwr, nrd);
        $finish;
    end
endmodule
