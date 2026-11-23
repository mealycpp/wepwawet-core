`timescale 1ns/1ps
// seal_v8 phase 2: PL-only TRNG draw for ML-DSA rnd (no host path).
// Mirrors wcore_drv/wcore_trng_rnd(): 32 warm-up + 32 raw 32-bit words from the Stage 8 RO TRNG,
//  - Stage-8 hardware health flag seen during a draw -> discard + redraw (max 3 redraws, then FAIL 2)
//  - SP 800-90B RCT  (cutoff C=41, at assumed H=0.5) over each 1024-bit block   -> FAIL 3
//  - SP 800-90B APT  (W=1024, C=793)                  over each 1024-bit block  -> FAIL 4
//  - no word within 2^22 cycles                                                 -> FAIL 1
// The 32 raw words (1024 bits) are written as 16 x 64-bit words to scratchpad b2[1100..1115]; the
// prologue ROM program conditions them in the PL: rnd = SHAKE256(raw, 32 B) (PC236).
// DET_RND = 1 (BUILD-TIME, SIMULATION/KAT ONLY, MUST BE 0 IN THE BOARD BUILD): no draw; rnd = 0^32 is
// written to b2[1044..1047] (FIPS 204 deterministic variant) and the prologue starts at PC237.
// Health statistics stay visible (status), failures are fail-closed (the SIGN job ends without output).
module seal_trng_fill #(parameter integer DET_RND = 0)(
    input  wire clk, input wire rst_n,
    input  wire req,                       // level, from the retry manager (S_TRNG)
    output reg  done, output reg fail,
    output reg  claim,                     // TRNG owned by the PL: AXI RAND_WORD path muted
    input  wire [31:0] trng_word, input wire trng_valid, input wire trng_hw_fail,
    output reg  [3:0]  wr_valid, input wire [3:0] wr_ready,
    output reg  [43:0] wr_addr,  output reg [255:0] wr_data,
    output reg  [3:0]  fail_code, output reg [3:0] redraws,
    output reg  [5:0]  max_run,   output reg [10:0] apt_worst
);
    localparam [2:0] T_IDLE=0, T_DRAW=1, T_BITS=2, T_WR=3, T_EVAL=4, T_DONE=5, T_FAIL=6, T_DET=7;
    reg [2:0] st;
    reg [6:0] n;            // words consumed in this draw (0..63)
    reg [31:0] sh, prev_w, buf_w; reg buf_v, ovr, hwf;
    reg [4:0] bitc; reg pb; reg [5:0] run, mrun; reg [10:0] ones; reg [10:0] worst;
    reg [21:0] tmo; reg [1:0] dk;
    reg [31:0] sh_full_hi;   // copy of the word being shifted out in T_BITS
    always @(posedge clk) if (st==T_DRAW && buf_v) sh_full_hi <= buf_w;
    wire [10:0] dev = (ones > 11'd512) ? ones : (11'd1024 - ones);
    wire [10:0] worst_n = (dev > worst) ? dev : worst;
    always @(posedge clk) begin
        if (!rst_n) begin
            st<=T_IDLE; done<=0; fail<=0; claim<=0; wr_valid<=0; wr_addr<=0; wr_data<=0;
            fail_code<=0; redraws<=0; max_run<=0; apt_worst<=0; n<=0; sh<=0; prev_w<=0; buf_w<=0; buf_v<=0;
            ovr<=0; hwf<=0; bitc<=0; pb<=0; run<=0; mrun<=0; ones<=0; worst<=0; tmo<=0; dk<=0;
        end else begin
            if (claim && trng_hw_fail) hwf <= 1'b1;
            if (claim && trng_valid && st != T_IDLE) begin       // one-deep buffer; overrun voids the draw
                if (buf_v) ovr <= 1'b1; else begin buf_w <= trng_word; buf_v <= 1'b1; end
            end
            case (st)
            T_IDLE: begin
                done<=0; fail<=0; wr_valid<=0;
                if (req) begin
                    redraws<=0; fail_code<=0; mrun<=0; worst<=0;
                    if (DET_RND != 0) begin dk<=0; st<=T_DET; end
                    else begin claim<=1; n<=0; hwf<=0; ovr<=0; buf_v<=0; tmo<=0; st<=T_DRAW; end
                end
            end
            T_DET: begin                                         // rnd = 0^32 -> b2[1044..1047]
                if (!wr_valid[2]) begin
                    wr_valid<=4'b0100; wr_addr<={4{11'd1044+{9'd0,dk}}}; wr_data<=256'd0;
                end else if (wr_ready[2]) begin
                    wr_valid<=0; dk<=dk+1'b1; if (dk==2'd3) st<=T_DONE;
                end
            end
            T_DRAW: begin
                tmo <= tmo + 1'b1;
                if (&tmo) begin fail_code<=4'd1; st<=T_FAIL; end
                else if (buf_v) begin
                    sh<=buf_w; buf_v<=1'b0; bitc<=0; st<=T_BITS;
                    if (n==7'd0 || n==7'd32) begin run<=0; ones<=0; end
                end
            end
            T_BITS: begin                                        // LSB first, same order as the driver
                if ((n==7'd0 || n==7'd32) && bitc==5'd0) run<=6'd1;
                else if (sh[0]==pb) begin if (~&run) run<=run+1'b1; end
                else run<=6'd1;
                pb<=sh[0]; ones<=ones+sh[0];
                if (run > mrun) mrun<=run;
                sh<={1'b0,sh[31:1]}; bitc<=bitc+1'b1;
                if (bitc==5'd31) st<=T_WR;
            end
            T_WR: begin
                if (run > mrun) mrun<=run;
                if (n>=7'd32 && n[0] && !wr_valid[2]) begin     // pack raw pair (even=low, odd=high)
                    wr_valid<=4'b0100; wr_addr<={4{11'd1100+{5'd0,n[5:1]}-11'd16}};
                    wr_data<={4{sh_full_hi, prev_w}};
                end else if (wr_valid[2]) begin
                    if (wr_ready[2]) begin wr_valid<=0; st<=T_EVAL; end
                end else st<=T_EVAL;
            end
            T_EVAL: begin
                prev_w <= sh_full_hi;
                if (n==7'd31) worst<=worst_n;
                if (n==7'd63) begin
                    max_run<=mrun; apt_worst<=worst_n;
                    if (hwf || ovr) begin
                        if (redraws==4'd3) begin fail_code<=4'd2; st<=T_FAIL; end
                        else begin redraws<=redraws+1'b1; n<=0; hwf<=0; ovr<=0; buf_v<=0; tmo<=0; mrun<=0; worst<=0; st<=T_DRAW; end
                    end else if (mrun >= 6'd41) begin fail_code<=4'd3; st<=T_FAIL; end
                    else if (worst_n >= 11'd793) begin fail_code<=4'd4; st<=T_FAIL; end
                    else st<=T_DONE;
                end else begin n<=n+1'b1; tmo<=0; st<=T_DRAW; end
            end
            T_DONE: begin claim<=0; done<=1; if (!req) begin done<=0; st<=T_IDLE; end end
            T_FAIL: begin claim<=0; fail<=1; wr_valid<=0; if (!req) begin fail<=0; st<=T_IDLE; end end
            default: st<=T_IDLE;
            endcase
        end
    end
endmodule
