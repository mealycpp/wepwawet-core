`timescale 1ns/1ps
// WEPWAWET Stage 10 - standalone ML-DSA-44 coefficient auxiliary engine.
// FPGA datapath (NOT a signer). Synchronous Stage9 AUX handshake.
// Use only with an ARBITRATED scratchpad connection in the full system.
// One 64-bit word / iteration = two signed 32-bit coefficients.
// 300 MHz TARGET only; no synthesis/timing result is claimed.
module wcore_mldsa44_coeff_aux #(
    parameter integer ADDR_W = 11,
    parameter integer BANKS = 4
)(
    input  wire clk,
    input  wire rst_n,
    input  wire abort,
    input  wire aux_valid,
    output wire aux_ready,
    input  wire [7:0] aux_op,
    input  wire [1:0] aux_src_bank,
    input  wire [1:0] aux_dst_bank,
    input  wire [ADDR_W-1:0] aux_src_addr,
    input  wire [ADDR_W-1:0] aux_dst_addr,
    input  wire [ADDR_W:0] aux_words,
    output wire aux_done,
    output wire aux_error,
    output wire aux_reject_set,
    output reg  [BANKS-1:0] sp_rd_req_valid,
    input  wire [BANKS-1:0] sp_rd_req_ready,
    output reg  [BANKS*ADDR_W-1:0] sp_rd_req_addr,
    input  wire [BANKS-1:0] sp_rd_rsp_valid,
    output reg  [BANKS-1:0] sp_rd_rsp_ready,
    input  wire [BANKS*64-1:0] sp_rd_rsp_data,
    output reg  [BANKS-1:0] sp_wr_req_valid,
    input  wire [BANKS-1:0] sp_wr_req_ready,
    output reg  [BANKS*ADDR_W-1:0] sp_wr_req_addr,
    output reg  [BANKS*64-1:0] sp_wr_req_data
);
    // Explicit operation ABI. No hidden CPU computations.
    localparam [7:0]
        A_FREEZE=8'h01, A_CENTER=8'h02,
        A_HIGHBITS=8'h03, A_LOWBITS=8'h04,
        A_P2R_HIGH=8'h05, A_P2R_LOW=8'h06,
        A_ADD=8'h10, A_SUB=8'h11,
        A_MAKE_HINT=8'h12, A_USE_HINT=8'h13,
        A_NORM_Z=8'h20, A_NORM_W0=8'h21,
        A_NORM_CT0=8'h22;
    localparam signed [63:0] Q=64'sd8380417;
    localparam signed [63:0] GAMMA2=64'sd95232;
    localparam integer BOUND_Z = 130994;   // GAMMA1 - BETA, ML-DSA-44
    localparam integer BOUND_W0 = 95154;   // GAMMA2 - BETA
    localparam integer BOUND_CT0 = 95232;  // GAMMA2
    localparam [3:0]
        S_IDLE=0, S_SRC_REQ=1, S_SRC_RSP=2,
        S_DST_REQ=3, S_DST_RSP=4,
        S_CANON_SRC=5, S_CANON_DST=6, S_DECOMP=7,
        S_LOW=8, S_SUM=9, S_CALC=10, S_WRITE=11, S_NEXT=12,
        S_DONE=13, S_ERROR=14;
    (* fsm_encoding = "none" *) reg [4:0] state;
    reg signed [63:0] lo_prod0, lo_prod1;
    reg signed [63:0] lo_tmp0, lo_tmp1;
    // V5: HighBits is computed from canonical residues in [0,Q-1].
    // t=(a+127)>>7 fits 16 bits; t*11275+8388608 fits 30 bits.
    // Register each arithmetic boundary instead of making one 21-level cone.
    reg [15:0] hi_pre0, hi_pre1;
    (* use_dsp = "yes" *) reg [29:0] hi_product0, hi_product1;
    reg [29:0] hi_rounded0, hi_rounded1;
    localparam [4:0] S_RED_QUOT = 5'd15,
                     S_RED_SUB  = 5'd16,
                     S_RED_FIX  = 5'd17,
                     S_CANON_SRC_SUB = 5'd18,
                     S_CANON_SRC_FIX = 5'd19,
                     S_CANON_DST_SUB = 5'd20,
                     S_CANON_DST_FIX = 5'd21,
                     S_LOW_SUB = 5'd22,
                     S_LOW_FIX = 5'd23,
                     S_HI_MUL = 5'd24,
                     S_HI_ROUND = 5'd25,
                     S_HI_FINISH = 5'd26,
                     S_CANON_SRC_MUL = 5'd27,
                     S_CANON_DST_MUL = 5'd28,
                     S_RED_MUL       = 5'd29;
    reg [7:0] op_q;
    reg [1:0] src_bank_q, dst_bank_q;
    reg [ADDR_W-1:0] src_base_q, dst_base_q;
    reg [ADDR_W:0] words_q, index_q;
    reg [63:0] src_word, dst_word, result_word;
    reg signed [31:0] src0, src1, dst0, dst1, high0, high1;
    reg signed [31:0] low0, low1, sum0, sum1;
    // V7: For any signed 32-bit operand x,
    // t = floor((x + 2^22)/2^23) is in [-256,256] (signed 10 bits).
    // Q*t fits signed 32 bits. Splitting multiplication and subtraction
    // removes their DSP/adder chain from the same clock period.
    reg signed [9:0] red_t0, red_t1;
    reg signed [31:0] red_product0, red_product1;
    // r = x - Q*t = 8191*t + remainder - 2^22.
    // Therefore r is in [-6,291,200,6,291,199], signed 32 bits suffice.
    reg signed [31:0] red_r0, red_r1;

    wire do_binary = (op_q == A_ADD || op_q == A_SUB ||
                      op_q == A_MAKE_HINT || op_q == A_USE_HINT);
    wire do_norm = (op_q == A_NORM_Z || op_q == A_NORM_W0 ||
                    op_q == A_NORM_CT0);
    wire valid_op = (aux_op == A_FREEZE || aux_op == A_CENTER ||
                     aux_op == A_HIGHBITS || aux_op == A_LOWBITS ||
                     aux_op == A_P2R_HIGH || aux_op == A_P2R_LOW ||
                     aux_op == A_ADD || aux_op == A_SUB ||
                     aux_op == A_MAKE_HINT || aux_op == A_USE_HINT ||
                     aux_op == A_NORM_Z || aux_op == A_NORM_W0 ||
                     aux_op == A_NORM_CT0);
    wire [ADDR_W+1:0] src_end = {2'b00,aux_src_addr} + {1'b0,aux_words};
    wire [ADDR_W+1:0] dst_end = {2'b00,aux_dst_addr} + {1'b0,aux_words};
    wire descriptor_ok = valid_op && (aux_words != 0) &&
                         (src_end <= (1 << ADDR_W)) &&
                         (dst_end <= (1 << ADDR_W)) &&
                         (aux_src_bank < BANKS) && (aux_dst_bank < BANKS);

    // General 32-bit signed reduction without a generic hardware divider.
    // t is about +/-256, and the post-correction is in [0,Q-1].
    function automatic signed [31:0] freeze32(input signed [31:0] a);
        reg signed [63:0] x,t,r;
        begin
            x = {{32{a[31]}},a};
            t = (x + 64'sd4194304) >>> 23;
            r = x - t * Q;
            if (r < 0) r = r + Q;
            if (r >= Q) r = r - Q;
            freeze32 = r[31:0];
        end
    endfunction
    // Algorithm equivalent to CRYSTALS-Dilithium decompose for GAMMA2=(Q-1)/88.
    function automatic signed [31:0] hi_decomp(input signed [31:0] a);
        reg signed [63:0] t,h;
        begin
            t = ({{32{a[31]}},a} + 64'sd127) >>> 7;
            h = (t * 64'sd11275 + 64'sd8388608) >>> 24;
            if (h >= 44) h = 0;
            hi_decomp = h[31:0];
        end
    endfunction
    function automatic signed [31:0] lo_decomp(
        input signed [31:0] a, input signed [31:0] h);
        reg signed [63:0] t;
        begin
            t = {{32{a[31]}},a} - ({{32{h[31]}},h} * 64'sd190464);
            if (t > 64'sd4190208) t = t - Q;
            lo_decomp = t[31:0];
        end
    endfunction
    function automatic signed [31:0] p2r_hi(input signed [31:0] a);
        begin p2r_hi = (a + 32'sd4095) >>> 13; end
    endfunction
    function automatic signed [31:0] p2r_lo(input signed [31:0] a);
        reg signed [31:0] h;
        begin h = p2r_hi(a); p2r_lo = a - h * 32'sd8192; end
    endfunction
    function automatic [31:0] makehint(input signed [31:0] lo,
                                       input signed [31:0] hi);
        begin
            makehint = ((lo > 32'sd95232) || (lo < -32'sd95232) ||
                        ((lo == -32'sd95232) && (hi != 0))) ? 32'd1:32'd0;
        end
    endfunction
    function automatic [31:0] usehint(input signed [31:0] hi,
                                      input signed [31:0] lo,
                                      input signed [31:0] hint);
        begin
            if (hint == 0) usehint = hi;
            else if (lo > 0) usehint = (hi == 43) ? 32'd0 : (hi + 1);
            else usehint = (hi == 0) ? 32'd43 : (hi - 1);
        end
    endfunction
    function automatic norm_fail(input signed [31:0] v, input integer bound);
        reg signed [63:0] x;
        begin
            x = {{32{v[31]}},v};
            if (x < 0) x = -x;
            norm_fail = (x >= bound);
        end
    endfunction
    wire [31:0] in0 = src_word[31:0];
    wire [31:0] in1 = src_word[63:32];
    wire [31:0] other0 = dst_word[31:0];
    wire [31:0] other1 = dst_word[63:32];
    wire bad_hint = (op_q == A_USE_HINT) &&
                    ((other0 != 32'd0 && other0 != 32'd1) ||
                     (other1 != 32'd0 && other1 != 32'd1));
    wire [31:0] norm_bound = (op_q == A_NORM_Z) ? BOUND_Z :
                             (op_q == A_NORM_W0) ? BOUND_W0 : BOUND_CT0;
    // OMEGA_V1: FIPS 204 Alg. 7 requires rejecting (z,h) when the hint vector has more than
    // OMEGA=80 ones. hint_cnt accumulates the ones written by consecutive A_MAKE_HINT passes
    // (Sign ROM PC141..144) and is cleared when any other op is accepted. The comparison is
    // registered in S_NEXT and the reject is raised in S_DONE of a MAKE_HINT op, before the
    // ROM's reject BRANCH (PC145). Verify never issues A_MAKE_HINT, so it is unaffected.
    localparam [9:0] OMEGA = 10'd80;
    reg [9:0] hint_cnt;
    reg hint_over_q;
    wire hint_reject = (state == S_DONE) && (op_q == A_MAKE_HINT) && hint_over_q;
    assign aux_reject_set = ((state == S_CALC) && do_norm &&
        (norm_fail($signed(in0),norm_bound) ||
         norm_fail($signed(in1),norm_bound))) || hint_reject;

    function automatic [31:0] red_correct(input signed [63:0] rin);
        reg signed [63:0] r;
        begin
            r = rin;
            if (r < 0) r = r + 64'sd8380417;
            if (r >= 64'sd8380417) r = r - 64'sd8380417;
            red_correct = r[31:0];
        end
    endfunction
    function automatic [31:0] calc_one(
        input [7:0] op, input signed [31:0] canonical,
        input signed [31:0] other_canon,
        input signed [31:0] raw, input signed [31:0] other_raw,
        input signed [31:0] hi, input signed [31:0] lo,
        input signed [31:0] sum);
        begin
            case (op)
                A_FREEZE: calc_one = canonical;
                A_CENTER: calc_one = (canonical > 32'sd4190208) ?
                     (canonical - 32'sd8380417) : canonical;
                A_HIGHBITS: calc_one = hi;
                A_LOWBITS: calc_one = lo;
                A_P2R_HIGH: calc_one = p2r_hi(canonical);
                A_P2R_LOW: calc_one = p2r_lo(canonical);
                A_ADD, A_SUB: calc_one = 32'd0;
                A_MAKE_HINT: calc_one = makehint(raw,other_raw);
                A_USE_HINT: calc_one = usehint(hi,lo,other_raw);
                default: calc_one = 32'd0;
            endcase
        end
    endfunction

    assign aux_ready = (state == S_IDLE) && !abort;
    assign aux_done = (state == S_DONE) && !abort;
    assign aux_error = (state == S_ERROR) && !abort;

    always @* begin
        sp_rd_req_valid = {BANKS{1'b0}};
        sp_rd_req_addr = {(BANKS*ADDR_W){1'b0}};
        sp_rd_rsp_ready = {BANKS{1'b0}};
        sp_wr_req_valid = {BANKS{1'b0}};
        sp_wr_req_addr = {(BANKS*ADDR_W){1'b0}};
        sp_wr_req_data = {(BANKS*64){1'b0}};
        if (!abort) begin
            if (state == S_SRC_REQ) begin
                sp_rd_req_valid[src_bank_q] = 1'b1;
                sp_rd_req_addr[src_bank_q*ADDR_W +: ADDR_W] = src_base_q + index_q;
            end
            if (state == S_SRC_RSP)
                sp_rd_rsp_ready[src_bank_q] = 1'b1;
            if (state == S_DST_REQ) begin
                sp_rd_req_valid[dst_bank_q] = 1'b1;
                sp_rd_req_addr[dst_bank_q*ADDR_W +: ADDR_W] = dst_base_q + index_q;
            end
            if (state == S_DST_RSP)
                sp_rd_rsp_ready[dst_bank_q] = 1'b1;
            if (state == S_WRITE) begin
                sp_wr_req_valid[dst_bank_q] = 1'b1;
                sp_wr_req_addr[dst_bank_q*ADDR_W +: ADDR_W] = dst_base_q + index_q;
                sp_wr_req_data[dst_bank_q*64 +: 64] = result_word;
            end
        end
    end

    // OMEGA_V1 hint counter (separate process; no change to the datapath FSM)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hint_cnt <= 10'd0; hint_over_q <= 1'b0;
        end else if (abort) begin
            hint_cnt <= 10'd0; hint_over_q <= 1'b0;
        end else begin
            if (state == S_IDLE && aux_valid && aux_ready && aux_op != A_MAKE_HINT) begin
                hint_cnt <= 10'd0; hint_over_q <= 1'b0;
            end else if (state == S_WRITE && sp_wr_req_ready[dst_bank_q] && op_q == A_MAKE_HINT) begin
                hint_cnt <= hint_cnt + {9'd0, result_word[0]} + {9'd0, result_word[32]};
            end
            if (state == S_NEXT && op_q == A_MAKE_HINT)
                hint_over_q <= (hint_cnt > OMEGA);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            op_q <= 0;
            src_bank_q <= 0; dst_bank_q <= 0;
            src_base_q <= 0; dst_base_q <= 0;
            words_q <= 0; index_q <= 0;
            src_word <= 0; dst_word <= 0; result_word <= 0;
            src0 <= 0; src1 <= 0; dst0 <= 0; dst1 <= 0;
            high0 <= 0; high1 <= 0;
            low0 <= 0; low1 <= 0; sum0 <= 0; sum1 <= 0;
        end else if (abort) begin
            state <= S_IDLE;
            src_word <= 0; dst_word <= 0; result_word <= 0;
        end else begin
            case (state)
                S_IDLE: if (aux_valid && aux_ready) begin
                    if (!descriptor_ok) state <= S_ERROR;
                    else begin
                        op_q <= aux_op;
                        src_bank_q <= aux_src_bank;
                        dst_bank_q <= aux_dst_bank;
                        src_base_q <= aux_src_addr;
                        dst_base_q <= aux_dst_addr;
                        words_q <= aux_words;
                        index_q <= 0;
                        state <= S_SRC_REQ;
                    end
                end
                S_SRC_REQ: if (sp_rd_req_ready[src_bank_q]) state <= S_SRC_RSP;
                S_SRC_RSP: if (sp_rd_rsp_valid[src_bank_q]) begin
                    src_word <= sp_rd_rsp_data[src_bank_q*64 +: 64];
                    state <= do_binary ? S_DST_REQ : S_CANON_SRC;
                end
                S_DST_REQ: if (sp_rd_req_ready[dst_bank_q]) state <= S_DST_RSP;
                S_DST_RSP: if (sp_rd_rsp_valid[dst_bank_q]) begin
                    dst_word <= sp_rd_rsp_data[dst_bank_q*64 +: 64];
                    state <= S_CANON_SRC;
                end
                S_CANON_SRC: begin
                    red_t0 <= ($signed({{32{in0[31]}},in0}) + 64'sd4194304) >>> 23;
                    red_t1 <= ($signed({{32{in1[31]}},in1}) + 64'sd4194304) >>> 23;
                    state <= S_CANON_SRC_MUL;
                end
                S_CANON_SRC_MUL: begin
                    red_product0 <= red_t0 * 32'sd8380417;
                    red_product1 <= red_t1 * 32'sd8380417;
                    state <= S_CANON_SRC_SUB;
                end
                S_CANON_SRC_SUB: begin
                    red_r0 <= $signed(in0) - red_product0;
                    red_r1 <= $signed(in1) - red_product1;
                    state <= S_CANON_SRC_FIX;
                end
                S_CANON_SRC_FIX: begin
                    src0 <= red_correct(red_r0);
                    src1 <= red_correct(red_r1);
                    state <= S_CANON_DST;
                end
                S_CANON_DST: begin
                    red_t0 <= ($signed({{32{other0[31]}},other0}) + 64'sd4194304) >>> 23;
                    red_t1 <= ($signed({{32{other1[31]}},other1}) + 64'sd4194304) >>> 23;
                    state <= S_CANON_DST_MUL;
                end
                S_CANON_DST_MUL: begin
                    red_product0 <= red_t0 * 32'sd8380417;
                    red_product1 <= red_t1 * 32'sd8380417;
                    state <= S_CANON_DST_SUB;
                end
                S_CANON_DST_SUB: begin
                    red_r0 <= $signed(other0) - red_product0;
                    red_r1 <= $signed(other1) - red_product1;
                    state <= S_CANON_DST_FIX;
                end
                S_CANON_DST_FIX: begin
                    dst0 <= red_correct(red_r0);
                    dst1 <= red_correct(red_r1);
                    state <= S_DECOMP;
                end
                // V5 HighBits. src0/src1 are already canonical from
                // S_CANON_SRC_FIX. Exhaustive equivalence over 0..Q-1
                // was checked against the original hi_decomp function.
                S_DECOMP: begin
                    hi_pre0 <= ($unsigned(src0) + 32'd127) >> 7;
                    hi_pre1 <= ($unsigned(src1) + 32'd127) >> 7;
                    state <= S_HI_MUL;
                end
                S_HI_MUL: begin
                    hi_product0 <= hi_pre0 * 14'd11275;
                    hi_product1 <= hi_pre1 * 14'd11275;
                    state <= S_HI_ROUND;
                end
                S_HI_ROUND: begin
                    hi_rounded0 <= hi_product0 + 30'd8388608;
                    hi_rounded1 <= hi_product1 + 30'd8388608;
                    state <= S_HI_FINISH;
                end
                S_HI_FINISH: begin
                    high0 <= (hi_rounded0[29:24] >= 6'd44) ?
                             32'sd0 : $signed({26'd0,hi_rounded0[29:24]});
                    high1 <= (hi_rounded1[29:24] >= 6'd44) ?
                             32'sd0 : $signed({26'd0,hi_rounded1[29:24]});
                    state <= S_LOW;
                end
                S_LOW: begin
                    lo_prod0 <= $signed({{32{high0[31]}},high0}) * 64'sd190464;
                    lo_prod1 <= $signed({{32{high1[31]}},high1}) * 64'sd190464;
                    state <= S_LOW_SUB;
                end
                S_LOW_SUB: begin
                    lo_tmp0 <= $signed({{32{src0[31]}},src0}) - lo_prod0;
                    lo_tmp1 <= $signed({{32{src1[31]}},src1}) - lo_prod1;
                    state <= S_LOW_FIX;
                end
                S_LOW_FIX: begin
                    low0 <= (lo_tmp0 > 64'sd4190208) ?
                            (lo_tmp0 - 64'sd8380417) : lo_tmp0;
                    low1 <= (lo_tmp1 > 64'sd4190208) ?
                            (lo_tmp1 - 64'sd8380417) : lo_tmp1;
                    state <= S_SUM;
                end
                S_SUM: begin
                    sum0 <= (op_q == A_SUB) ? (src0 - dst0) : (src0 + dst0);
                    sum1 <= (op_q == A_SUB) ? (src1 - dst1) : (src1 + dst1);
                    state <= S_CALC;
                end
                S_CALC: begin
                    if ((op_q == A_ADD) || (op_q == A_SUB)) begin
                        state <= S_RED_QUOT;
                    end else begin
                        result_word <= {
                            calc_one(op_q,src1,dst1,$signed(in1),$signed(other1),high1,low1,sum1),
                            calc_one(op_q,src0,dst0,$signed(in0),$signed(other0),high0,low0,sum0)
                        };
                        if (bad_hint) state <= S_ERROR;
                        else state <= do_norm ? S_NEXT : S_WRITE;
                    end
                end
                S_RED_QUOT: begin
                    red_t0 <= ($signed({{32{sum0[31]}},sum0}) + 64'sd4194304) >>> 23;
                    red_t1 <= ($signed({{32{sum1[31]}},sum1}) + 64'sd4194304) >>> 23;
                    state <= S_RED_MUL;
                end
                S_RED_MUL: begin
                    red_product0 <= red_t0 * 32'sd8380417;
                    red_product1 <= red_t1 * 32'sd8380417;
                    state <= S_RED_SUB;
                end
                S_RED_SUB: begin
                    red_r0 <= sum0 - red_product0;
                    red_r1 <= sum1 - red_product1;
                    state <= S_RED_FIX;
                end
                S_RED_FIX: begin
                    result_word <= {red_correct(red_r1),red_correct(red_r0)};
                    state <= S_WRITE;
                end
                S_WRITE: if (sp_wr_req_ready[dst_bank_q]) state <= S_NEXT;
                S_NEXT: begin
                    if (index_q == words_q - 1'b1) state <= S_DONE;
                    else begin
                        index_q <= index_q + 1'b1;
                        state <= S_SRC_REQ;
                    end
                end
                S_DONE: state <= S_IDLE;
                S_ERROR: state <= S_IDLE;
                default: state <= S_ERROR;
            endcase
        end
    end
endmodule
