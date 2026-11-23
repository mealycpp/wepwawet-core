`timescale 1ns/1ps
// seal_v8 phase 4 (PIN) testbench: pk pinning in front of the PL ML-DSA-44 verifier.
// Everything through the AXI4-Lite slave, as the ARM does it. No hierarchical pokes.
// Build: default (PIN_MODE 1, write-once register, unset -> REJECT) or +define+WPIN_HW with
//        +define+WPIN_MODE_DEFAULT=2 +define+WPIN_CONST_DEFAULT=<FP(trusted)> (hard-wired anchor).
module tb_pin;
    localparam AW = 17;
    reg aclk = 0; always #1.667 aclk = ~aclk;
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

    integer nwr = 0, nrd = 0, npass = 0;
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

    reg [63:0] rho [0:3]; reg [63:0] mu [0:7]; reg [63:0] ctl [0:3]; reg [63:0] ctp [0:3];
    reg [63:0] zz [0:511]; reg [63:0] hh [0:511]; reg [63:0] t1h [0:511]; reg [63:0] fpx [0:3];
    reg [31:0] pin_tr [0:7]; reg [31:0] pin_at [0:7];
    reg [63:0] msgp [0:231]; reg [11:0] mlen_m [0:0]; integer mlen, len_override = -1;
    reg [31:0] st, kap, errs, cyc, pstat, verd, pcyc, r32; reg [63:0] got;
    integer i, t, mfd;
    reg [8*16-1:0] cname;

    task automatic load_case(input string c);
        begin
            $readmemh({"vectors/", c, "/rho_4x64.mem"}, rho); $readmemh({"vectors/", c, "/mu_8x64.mem"}, mu);
            $readmemh({"vectors/", c, "/ctilde_4x64.mem"}, ctl); $readmemh({"vectors/", c, "/ctilde_prime_4x64.mem"}, ctp);
            $readmemh({"vectors/", c, "/z_512x64.mem"}, zz); $readmemh({"vectors/", c, "/h_512x64.mem"}, hh);
            $readmemh({"vectors/", c, "/t1hat2d_512x64.mem"}, t1h); $readmemh({"vectors/", c, "/fp_4x64.mem"}, fpx);
            $readmemh({"vectors/", c, "/msgp_232x64.mem"}, msgp); $readmemh({"vectors/", c, "/msglen.mem"}, mlen_m); mlen = mlen_m[0];
        end endtask
    task automatic wait_ready;
        begin
            t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4]) && t < 5000);
            if (!(st[3] && !st[4])) $fatal(1, "SCRATCHPAD_INIT_TIMEOUT st=%h", st);
        end endtask
    task automatic do_reset;
        begin @(negedge aclk); aresetn = 0; repeat (10) @(negedge aclk); aresetn = 1; wait_ready; end endtask
    task automatic write_pin(input integer which);   // 0 trusted, 1 attacker
        begin for (i = 0; i < 8; i = i + 1) axi_wr(17'h1_00A0 + 4*i, which ? pin_at[i] : pin_tr[i], 0); end endtask
    task automatic check_pin(input integer which, input string tag);
        begin for (i = 0; i < 8; i = i + 1) begin
            axi_rd(17'h1_00A0 + 4*i, r32, 0);
            if (r32 !== (which ? pin_at[i] : pin_tr[i])) $fatal(1, "PIN_READBACK_%s i=%0d %h", tag, i, r32);
        end end endtask
    // run one VERIFY of case c; expect verdict code exp; busy_probe = 1 tries pin/scratchpad access mid-job
    task automatic run_verify(input string c, input integer exp, input integer busy_probe);
        begin
            load_case(c);
            for (i = 0; i < 4; i = i + 1)   sp_write64(2, 512 + i, rho[i]);
`ifdef WPIN_MU
            // MU_PL: host writes M' and MSG_LEN; the mu it leaves in b2[1048..] is garbage (true mu only for
            // tamper_msg, to show it is ignored). The PL must compute mu = H(TR_CONST || M') itself.
            for (i = 0; i < (mlen + 7) / 8; i = i + 1) sp_write64(2, 1304 + i, msgp[i]);
            axi_wr(17'h1_00F0, (len_override >= 0) ? len_override : mlen, 0);
            for (i = 0; i < 8; i = i + 1)   sp_write64(2, 1048 + i, (c == "tamper_msg") ? mu[i] : 64'hBAD0_0000_0000_0000 + i);
`else
            for (i = 0; i < 8; i = i + 1)   sp_write64(2, 1048 + i, mu[i]);
`endif
            for (i = 0; i < 4; i = i + 1)   sp_write64(1, 1150 + i, ctl[i]);
            for (i = 0; i < 512; i = i + 1) begin
                sp_write64(3, i, zz[i]); sp_write64(3, 512 + i, hh[i]); sp_write64(3, 1536 + i, t1h[i]);
            end
            axi_wr(17'h1_0000, 32'h5, 0);                                   // LAUNCH | VERIFY
            if (busy_probe) begin                                           // TOCTOU: inputs frozen while hashing
                axi_wr(17'h1_00A0, 32'hDEAD_BEEF, 1);                       // pin write while busy -> SLVERR
                axi_wr(spa(3, 1536, 0), 32'h0, 1);                          // t1'_hat write while busy -> SLVERR
                axi_rd(spa(2, 512, 0), r32, 1);                             // scratchpad read while busy -> SLVERR
                axi_wr(17'h1_0000, 32'h10, 0);                              // ZEROIZE while pin job -> ignored
                axi_rd(17'h1_001C, r32, 0); if (r32[3]) $fatal(1, "ZEROIZE_ACCEPTED_DURING_PIN_JOB");
            end
            t = 0; do begin repeat (500) @(posedge aclk); axi_rd(17'h1_0004, st, 0); t = t + 1; end
            while (!st[1] && t < 400000);
            if (!st[1]) $fatal(1, "VERIFY_TIMEOUT %s st=%h", c, st);
            axi_rd(17'h1_0008, kap, 0); axi_rd(17'h1_000C, errs, 0); axi_rd(17'h1_0010, cyc, 0);
            axi_rd(17'h1_00C0, pstat, 0); axi_rd(17'h1_00C4, verd, 0); axi_rd(17'h1_00C8, pcyc, 0);
            for (i = 0; i < 4; i = i + 1) begin
                axi_rd(17'h1_00D0 + 8*i, r32, 0); got[31:0] = r32; axi_rd(17'h1_00D4 + 8*i, r32, 0); got[63:32] = r32;
                if (got !== fpx[i]) $fatal(1, "PL_FP_MISMATCH %s i=%0d got=%h exp=%h", c, i, got, fpx[i]);
            end
            $display("PIN_VERIFY case=%s verdict=%0d exp=%0d vbits=%02h status=%h errs=%h attempts=%0d cycles=%0d pin_hash_cycles=%0d pin_stat=%h",
                     c, verd[3:0], exp, verd[7:0], st, errs, kap[31:16], cyc, pcyc, pstat);
            if (!verd[4] || verd[3:0] != exp[3:0]) $fatal(1, "VERDICT_MISMATCH %s got=%0d exp=%0d", c, verd[3:0], exp);
            if (pstat[11:8] != exp[3:0]) $fatal(1, "PIN_STAT_VERDICT %h", pstat);
`ifdef WPIN_MU
            if (exp == 1) begin                                              // PL-computed mu landed in b2[1048..]
                for (i = 0; i < 8; i = i + 1) begin
                    sp_read64(2, 1048 + i, got); if (got !== mu[i]) $fatal(1, "PL_MU_MISMATCH %s i=%0d got=%h", c, i, got);
                end
            end
            if (exp == 8 && (st[2] || errs[7:0] != 8'hD7 || kap[31:16] != 0)) $fatal(1, "MSG_LEN_NOT_FAIL_CLOSED");
`endif
            if (exp == 4 || exp == 5) begin                                  // fail-closed: core never ran
                if (st[2] || st[14] || kap[31:16] != 0 || errs[7:0] != (exp == 4 ? 8'hD4 : 8'hD5))
                    $fatal(1, "PIN_REJECT_NOT_FAIL_CLOSED st=%h errs=%h att=%0d", st, errs, kap[31:16]);
                for (i = 0; i < 4; i = i + 1) begin                          // c~ window untouched (no c~' computed)
                    sp_read64(1, 1150 + i, got); if (got !== ctl[i]) $fatal(1, "CORE_RAN_AFTER_PIN_REJECT i=%0d", i);
                end
                if (cyc > 10000) $fatal(1, "PIN_REJECT_TOO_SLOW cyc=%0d", cyc);
            end
            if (exp == 1 || exp == 2 || exp == 7) begin                      // core ran: c~' must equal the oracle
                for (i = 0; i < 4; i = i + 1) begin
                    sp_read64(1, 1150 + i, got);
                    if (c == "tamper_msg") begin if (i == 0 && got === ctl[0]) $fatal(1, "TAMPERED_MSG_GAVE_SIG_CTILDE"); end
                    else if (got !== ctp[i]) $fatal(1, "CTILDE_PRIME_MISMATCH %s i=%0d", c, i);
                end
                if (kap[31:16] != 1) $fatal(1, "ATTEMPTS %0d", kap[31:16]);
            end
            $fdisplay(mfd, "%s verdict=%0d errs=%h cycles=%0d pin_hash_cycles=%0d", c, verd[3:0], errs, cyc, pcyc);
            npass = npass + 1;
        end endtask

    initial begin
        $readmemh("vectors/pins/pin_trusted_8x32.mem", pin_tr); $readmemh("vectors/pins/pin_attacker_8x32.mem", pin_at);
        mfd = $fopen("capture/pin_results.txt", "w");
        repeat (10) @(negedge aclk); aresetn = 1; wait_ready;
        axi_rd(17'h1_00C0, pstat, 0); $display("PIN_STAT_AFTER_RESET %h", pstat);
`ifndef WPIN_HW
        if (pstat[1:0] != 2'b00 || pstat[5:4] != 2'd1) $fatal(1, "PIN_STAT_RESET %h", pstat);
        // T1 fail-closed default: no pin -> REJECT_PIN_UNSET, core never runs
        run_verify("trusted", 5, 0);
        // T2 write-once
        write_pin(0); check_pin(0, "PRECOMMIT");
        axi_wr(17'h1_00C0, 32'h1, 0);
        axi_rd(17'h1_00C0, pstat, 0); if (!pstat[0] || pstat[2]) $fatal(1, "PIN_COMMIT %h", pstat);
        axi_wr(17'h1_00A0, ~pin_tr[0], 0); axi_wr(17'h1_00BC, 32'h0, 0); axi_wr(17'h1_00C0, 32'h1, 0);
        write_pin(1);                                                         // full attacker re-pin attempt
        axi_rd(17'h1_00C0, pstat, 0);
        if (!pstat[0] || !pstat[2] || pstat[31:16] != 11) $fatal(1, "PIN_WRITE_ONCE_NOT_ENFORCED %h", pstat);
        check_pin(0, "AFTER_OVERWRITE_ATTEMPTS");
        $display("PIN_WRITE_ONCE refused=%0d pin_unchanged=1 stat=%h", pstat[31:16], pstat);
        npass = npass + 1;
`else
        if (pstat[1:0] != 2'b11 || pstat[5:4] != 2'd2) $fatal(1, "PIN_STAT_HW %h", pstat);
        write_pin(1); axi_wr(17'h1_00C0, 32'h1, 0);
        axi_rd(17'h1_00C0, pstat, 0); if (!pstat[2] || pstat[31:16] != 9) $fatal(1, "HW_PIN_WRITE_NOT_REFUSED %h", pstat);
        check_pin(0, "HW");
        $display("PIN_HW_CONST refused=%0d stat=%h", pstat[31:16], pstat); npass = npass + 1;
`endif
        // T3 trusted pk + valid signature -> ACCEPT (with mid-job TOCTOU probes)
        run_verify("trusted", 1, 1);
        // T4 attacker pk + attacker signature (valid under attacker key) -> REJECT_PIN
        run_verify("attacker", 4, 0);
        // T5 trusted signature, attacker pk image -> REJECT_PIN
        run_verify("mixed", 4, 0);
        // T6 trusted pk, bad signatures -> PL verdicts
        run_verify("bad_msg", 2, 0); run_verify("bad_ctilde", 2, 0); run_verify("bad_znorm", 3, 0);
`ifdef WPIN_MU
        // T6b host supplies the TRUE mu but an altered M' -> PL mu differs -> REJECT_SIG; MSG_LEN out of range -> 8
        run_verify("tamper_msg", 2, 0);
        len_override = 0;    run_verify("trusted", 8, 0);
        len_override = 1857; run_verify("trusted", 8, 0);
        len_override = -1;
`endif
        // T7 ZEROIZE must not clear the anchor
        axi_wr(17'h1_0000, 32'h10, 0);
        t = 0; do begin axi_rd(17'h1_001C, r32, 0); t = t + 1; end while (r32[3] && t < 20000);
        axi_rd(17'h1_00C0, pstat, 0); if (!pstat[0]) $fatal(1, "ZEROIZE_CLEARED_PIN %h", pstat);
        check_pin(0, "AFTER_ZEROIZE");
        run_verify("trusted", 1, 0);
        run_verify("attacker", 4, 0);
`ifndef WPIN_HW
        // T8 aresetn clears the register anchor (documented limitation); control: attacker sig IS valid under attacker key
        do_reset; axi_rd(17'h1_00C0, pstat, 0); if (pstat[0]) $fatal(1, "PIN_SURVIVED_RESET");
        write_pin(1); axi_wr(17'h1_00C0, 32'h1, 0);
        run_verify("attacker", 1, 0);
        run_verify("trusted", 4, 0);
`else
        do_reset; axi_rd(17'h1_00C0, pstat, 0); if (!pstat[0]) $fatal(1, "HW_PIN_LOST_AT_RESET");
        run_verify("attacker", 4, 0);
        run_verify("trusted", 1, 0);
`endif
        $display("PIN_V8_PASS checks=%0d axi_writes=%0d axi_reads=%0d", npass, nwr, nrd);
        $fclose(mfd);
        $finish;
    end
endmodule
