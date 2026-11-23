`timescale 1ns/1ps
// WEPWAWET profile_v1: tb_sign_multi + non-invasive cycle-profile monitor (v5 board RTL). Everything is done through the
// single AXI4-Lite slave exactly as the ARM will do it on the AUP:
//   preload key material / mu / first-attempt mask messages -> write rho'' and
//   rho registers -> LAUNCH -> poll STATUS -> read c~, z, h -> capture files.
// No hierarchical pokes into the DUT except read-only activity counters.
module tb_profile_hls;
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
        .irq(irq));

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

    // ======================= NON-INVASIVE PROFILE MONITOR (TB only) =======================
    // Read-only hierarchical probes; no force/deposit; DUT behaviour unchanged.
    localparam integer NST = 32;
    integer pf, cyc_ctr = 0, rec_open = 0, rec_start = 0, rec_pc = 0, rec_seq = 0;
    integer hist [0:NST-1];
    integer cfg_hs, cfg_busy, cfg_out, tx_beats, tx_first, tx_last, rx_beats, rx_first, rx_last;
    integer k_first, k_done, k_busy, pm_busy, pm_in, pm_out, pm_axil, sp_rd, sp_wr, ad_rd, ad_wr;
    integer mgr_hist [0:15];
    reg [63:0] rec_instr;
    reg [5:0] st_q;
    integer j;
    task automatic rec_reset(input integer pcv, input integer now);
        begin
            rec_pc = pcv; rec_start = now; rec_open = 1;
            for (j = 0; j < NST; j = j + 1) hist[j] = 0;
            for (j = 0; j < 16; j = j + 1) mgr_hist[j] = 0;
            cfg_hs = 0; cfg_busy = 0; tx_beats = 0; tx_first = -1; tx_last = -1;
            rx_beats = 0; rx_first = -1; rx_last = -1; k_first = -1; k_done = -1; k_busy = 0;
            pm_busy = 0; pm_in = 0; pm_out = 0; pm_axil = 0; sp_rd = 0; sp_wr = 0; ad_rd = 0; ad_wr = 0;
        end endtask
    task automatic rec_flush(input integer now);
        begin
            if (rec_open) begin
                $fwrite(pf, "%0d,%0d,%0d,%0d,%016h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                    rec_seq, rec_pc, rec_start, now, rec_instr, cfg_hs, cfg_busy, tx_beats, tx_first, tx_last,
                    rx_beats, rx_first, rx_last, k_first, k_done, k_busy, pm_busy, pm_in, pm_out, pm_axil,
                    sp_rd, sp_wr, ad_rd, ad_wr, dut.u_retry.attempts, dut.u_retry.state);
                for (j = 0; j < NST; j = j + 1) $fwrite(pf, ",%0d", hist[j]);
                for (j = 0; j < 16; j = j + 1) $fwrite(pf, ",%0d", mgr_hist[j]);
                $fwrite(pf, "\n");
                rec_seq = rec_seq + 1;
            end
        end endtask
    initial begin
        pf = $fopen("capture/profile_trace.csv", "w");
        $fwrite(pf, "seq,pc,start,end,instr,cfg_hs,cfg_busy,tx_beats,tx_first,tx_last,rx_beats,rx_first,rx_last,k_first,k_done,k_busy,pm_busy,pm_in,pm_out,pm_axil,sp_rd,sp_wr,ad_rd,ad_wr,attempts,mgr_state");
        for (j = 0; j < NST; j = j + 1) $fwrite(pf, ",st%0d", j);
        for (j = 0; j < 16; j = j + 1) $fwrite(pf, ",mgr%0d", j);
        $fwrite(pf, "\n"); cfg_out = 0; st_q = 0; rec_instr = 0;
    end
    wire [5:0] mon_st = dut.u_core.u_wcore.u_seq.state;
    always @(posedge aclk) if (aresetn && dut.running) begin
        cyc_ctr = cyc_ctr + 1;
        // ---- record boundaries: each ROM instruction = FETCH_REQ entry .. next FETCH_REQ entry;
        //      sequencer IDLE/JOB_DONE stretches (retry-manager restore, ack) are pc=999 records.
        if (mon_st == 6'd1 && st_q != 6'd1) begin rec_flush(cyc_ctr); rec_reset(dut.u_core.u_wcore.u_seq.pc, cyc_ctr); end
        else if ((mon_st == 6'd0 || mon_st == 6'd19) && !(st_q == 6'd0 || st_q == 6'd19)) begin rec_flush(cyc_ctr); rec_reset(999, cyc_ctr); end
        else if (!rec_open) rec_reset(999, cyc_ctr);
        st_q = mon_st;
        if (mon_st == 6'd3) rec_instr = dut.u_core.u_wcore.u_seq.rom_data;   // FETCH_LATCH: ROM word for this pc
        hist[mon_st] = hist[mon_st] + 1;
        mgr_hist[dut.u_retry.state] = mgr_hist[dut.u_retry.state] + 1;
        // ---- AXI-Lite configuration of HLS kernels (sequencer CFG executor -> bridge)
        if (dut.u_core.cfg_req_valid && dut.u_core.cfg_req_ready) begin cfg_hs = cfg_hs + 1; cfg_out = 1; end
        if (cfg_out) cfg_busy = cfg_busy + 1;
        if (dut.u_core.cfg_rsp_valid && dut.u_core.cfg_rsp_ready) cfg_out = 0;
        // ---- AXI-Stream scratchpad <-> HLS kernel transport
        if (dut.u_core.tx_tvalid && dut.u_core.tx_tready) begin tx_beats = tx_beats + 1; if (tx_first < 0) tx_first = cyc_ctr; tx_last = cyc_ctr; end
        if (dut.u_core.rx_tvalid && dut.u_core.rx_tready) begin rx_beats = rx_beats + 1; if (rx_first < 0) rx_first = cyc_ctr; rx_last = cyc_ctr; end
        // ---- HLS kernel control (ap_start .. ap_done) for NTT/INTT/SHAKE256/SHAKE128
        if ((dut.u_core.u_real_ntt.ap_start || dut.u_core.u_real_intt.ap_start ||
             dut.u_core.u_real_shake256.ap_start || dut.u_core.u_real_shake128.ap_start) && k_first < 0) k_first = cyc_ctr;
        if (dut.u_core.u_real_ntt.ap_done || dut.u_core.u_real_intt.ap_done ||
            dut.u_core.u_real_shake256.ap_done || dut.u_core.u_real_shake128.ap_done) k_done = cyc_ctr;
        if (!dut.u_core.u_real_ntt.ap_idle || !dut.u_core.u_real_intt.ap_idle ||
            !dut.u_core.u_real_shake256.ap_idle || !dut.u_core.u_real_shake128.ap_idle) k_busy = k_busy + 1;
        // ---- DOT4 aux: HLS polymulacc, its AXI-Lite master and AXIS beats
        if (!dut.u_core.u_wcore.u_aux.u_dot4.u_real_polymulacc.ap_idle) pm_busy = pm_busy + 1;
        if (dut.u_core.u_wcore.u_aux.u_dot4.poly_in_tvalid  && dut.u_core.u_wcore.u_aux.u_dot4.poly_in_tready)  pm_in = pm_in + 1;
        if (dut.u_core.u_wcore.u_aux.u_dot4.poly_out_tvalid && dut.u_core.u_wcore.u_aux.u_dot4.poly_out_tready) pm_out = pm_out + 1;
        if (dut.u_core.u_wcore.u_aux.u_dot4.u_poly_axil.req_valid && dut.u_core.u_wcore.u_aux.u_dot4.u_poly_axil.req_ready) pm_axil = pm_axil + 1;
        // ---- scratchpad handshakes issued by AUX units
        sp_rd = sp_rd + $countones(dut.u_core.u_wcore.u_aux.sp_rd_req_valid & dut.u_core.u_wcore.u_aux.sp_rd_req_ready);
        sp_wr = sp_wr + $countones(dut.u_core.u_wcore.u_aux.sp_wr_req_valid & dut.u_core.u_wcore.u_aux.sp_wr_req_ready);
    end
    always @(posedge aclk) if (aresetn && !dut.running && rec_open && cyc_ctr > 0) begin
        rec_flush(cyc_ctr); rec_open = 0;
        $fclose(pf); pf = $fopen("capture/profile_done.txt", "w"); $fwrite(pf, "total_cycles=%0d records=%0d\n", cyc_ctr, rec_seq); $fclose(pf);
    end
    // ---- HLS sub-loop profile (read-only): calls and busy cycles of each HLS pipeline region
    `define SUBMON(NAME, PATH) \
        integer NAME``_calls = 0, NAME``_busy = 0; reg NAME``_q = 0; \
        always @(posedge aclk) if (aresetn && dut.running) begin \
            if (PATH.ap_start && !NAME``_q) NAME``_calls = NAME``_calls + 1; \
            NAME``_q = PATH.ap_start && !PATH.ap_done; \
            if (PATH.ap_start) NAME``_busy = NAME``_busy + 1; end
    `SUBMON(ntt_read,  dut.u_core.u_real_ntt.grp_ntt_top_Pipeline_READ_fu_150)
    `SUBMON(ntt_bfly,  dut.u_core.u_real_ntt.grp_ntt_top_Pipeline_BUTTERFLY_fu_178)
    `SUBMON(ntt_write, dut.u_core.u_real_ntt.grp_ntt_top_Pipeline_WRITE_fu_164)
    `SUBMON(intt_read, dut.u_core.u_real_intt.grp_intt_top_Pipeline_READ_fu_166)
    `SUBMON(intt_bfly, dut.u_core.u_real_intt.grp_intt_top_Pipeline_BUTTERFLY_fu_186)
    `SUBMON(intt_scale,dut.u_core.u_real_intt.grp_intt_top_Pipeline_SCALE_fu_180)
    `SUBMON(intt_write,dut.u_core.u_real_intt.grp_intt_top_Pipeline_WRITE_fu_198)
    `SUBMON(pm_ra,     dut.u_core.u_wcore.u_aux.u_dot4.u_real_polymulacc.grp_polymulacc_top_Pipeline_READ_A_fu_82)
    `SUBMON(pm_rb,     dut.u_core.u_wcore.u_aux.u_dot4.u_real_polymulacc.grp_polymulacc_top_Pipeline_READ_B_fu_96)
    `SUBMON(pm_mac,    dut.u_core.u_wcore.u_aux.u_dot4.u_real_polymulacc.grp_polymulacc_top_Pipeline_MULACC_fu_110)
    integer nttcalls = 0, inttcalls = 0, pmcalls = 0; reg ntt_s_q = 0, intt_s_q = 0, pm_s_q = 0;
    always @(posedge aclk) if (aresetn && dut.running) begin
        if (dut.u_core.u_real_ntt.ap_start && !ntt_s_q) nttcalls = nttcalls + 1; ntt_s_q = dut.u_core.u_real_ntt.ap_start;
        if (dut.u_core.u_real_intt.ap_start && !intt_s_q) inttcalls = inttcalls + 1; intt_s_q = dut.u_core.u_real_intt.ap_start;
        if (dut.u_core.u_wcore.u_aux.u_dot4.u_real_polymulacc.ap_start && !pm_s_q) pmcalls = pmcalls + 1;
        pm_s_q = dut.u_core.u_wcore.u_aux.u_dot4.u_real_polymulacc.ap_start;
    end
    integer sfd; reg sub_done = 0;
    always @(posedge aclk) if (aresetn && !dut.running && cyc_ctr > 0 && !sub_done) begin
        sub_done = 1; sfd = $fopen("capture/hls_subloops.txt", "w");
        $fdisplay(sfd, "ntt_top_calls=%0d intt_top_calls=%0d polymul_calls=%0d", nttcalls, inttcalls, pmcalls);
        $fdisplay(sfd, "ntt READ calls=%0d busy=%0d | BUTTERFLY calls=%0d busy=%0d | WRITE calls=%0d busy=%0d", ntt_read_calls, ntt_read_busy, ntt_bfly_calls, ntt_bfly_busy, ntt_write_calls, ntt_write_busy);
        $fdisplay(sfd, "intt READ calls=%0d busy=%0d | BUTTERFLY calls=%0d busy=%0d | SCALE calls=%0d busy=%0d | WRITE calls=%0d busy=%0d", intt_read_calls, intt_read_busy, intt_bfly_calls, intt_bfly_busy, intt_scale_calls, intt_scale_busy, intt_write_calls, intt_write_busy);
        $fdisplay(sfd, "polymul READ_A calls=%0d busy=%0d | READ_B calls=%0d busy=%0d | MULACC calls=%0d busy=%0d", pm_ra_calls, pm_ra_busy, pm_rb_calls, pm_rb_busy, pm_mac_calls, pm_mac_busy);
        $fclose(sfd);
    end
    reg [63:0] rho [0:3]; reg [63:0] mu [0:7]; reg [63:0] seed_nonce [0:35];
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
        repeat (10) @(negedge aclk); aresetn = 1;

        axi_rd(17'h1_0014, magic, 0);
        if (magic != 32'h5743_5331) $fatal(1, "MAGIC_MISMATCH %h", magic);
        t = 0; do begin axi_rd(17'h1_0004, st, 0); t = t + 1; end while (!(st[3] && !st[4]) && t < 5000);
        if (!(st[3] && !st[4])) $fatal(1, "SCRATCHPAD_INIT_TIMEOUT st=%h", st);
        $display("SIGNV2_SCRATCHPAD_READY");

        // --- PS preload (same placement as the frozen V7 regression) ---
        for (i = 0; i < 4; i = i + 1)   sp_write64(2, 512 + i, rho[i]);
        for (i = 0; i < 8; i = i + 1)   sp_write64(2, 1024 + i, mu[i]);
        for (i = 0; i < 512; i = i + 1) begin
            sp_write64(1, 512 + i,  s1_hat[i]);
            sp_write64(1, 1536 + i, s2_hat[i]);
            sp_write64(2, 1536 + i, t0_hat[i]);
        end
        for (i = 0; i < 36; i = i + 1)
            sp_write64(2, i, (i % 9 == 8) ? {48'd0, 16'(i / 9)} : seed_nonce[i]);
        // read-back spot check through the same window
        sp_read64(1, 512, got);  if (got !== s1_hat[0])  $fatal(1, "READBACK_S1 %h", got);
        sp_read64(2, 2047, got); if (got !== t0_hat[511]) $fatal(1, "READBACK_T0 %h", got);
        // rho'' (16 words) and public rho (8 words)
        for (i = 0; i < 8; i = i + 1) begin
            axi_wr(17'h1_0040 + 8*i, seed_nonce[i][31:0], 0);
            axi_wr(17'h1_0044 + 8*i, seed_nonce[i][63:32], 0);
        end
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
        axi_wr(17'h1_0040, 32'hDEAD, 1);                      // seed locked while busy
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
