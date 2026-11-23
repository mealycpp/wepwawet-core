`timescale 1ns/1ps
// ============================================================================
// wpin_gate -- seal_v8 phase 4 (PIN): public-key pinning for the PL ML-DSA-44 verifier.
//
// The VERIFY ROM program (PC150..235) consumes exactly two pk-derived inputs from the scratchpad:
//   rho      b2[512..515]   (ExpandA seed)
//   t1'_hat  b3[1536..2047] (NTT(t1 * 2^d) mod q, two 32-bit coefficients per 64-bit word)
// Everything else it reads is signature (c~ b1[1150..1153], z b3[0..511], h b3[512..1023]) or mu.
// This block, started by the wrapper at VERIFY LAUNCH *before* the core runs (host scratchpad access is
// refused for the whole job), computes the verifier-image fingerprint
//     FP = SHAKE256( TAG || rho || t1'_hat , 32 bytes ),  TAG = "WPINv1\0\0" (one 64-bit LE lane)
// over the 64-bit words exactly as the core will consume them (517 lanes = 4136 bytes, 31 Keccak blocks),
// and latches the host-supplied c~ (which the program later overwrites with c~').
// pk -> (rho, t1'_hat) is injective (t1 < 2^10, t1*2^13 < q, NTT bijective), so pinning FP pins pk.
// After the core finishes, op POST re-reads c~' and compares it with the latched c~ in PL, so the
// accept/reject verdict is a PL fact (v7/v8 left the final c~ == c~' comparison to the host).
// The pin register itself (write-once after reset, or build-time constant) also lives here.
// Dedicated Keccak-f[1600], one round per clock (24 clk / block); no change to the core, ROM or HLS IP.
// MU_PL = 1 (PL message binding): after the FP check PRE also computes mu = SHAKE256(tr || M', 64) in PL, with
// tr = TR_CONST (bitstream constant = H(pk_pinned, 64), from the same provisioning tool as PIN_CONST) and M'
// (= 0 || |ctx| || ctx || M for pure ML-DSA) read from b2[1304..1535] (msg_len bytes, <= 1856), and writes it to
// b2[1048..1055], overwriting whatever mu the host left there. The host can no longer choose mu.
// ============================================================================
module wpin_gate #(
    parameter integer PIN_MODE  = 1,          // 1 = write-once register, 2 = hard-wired PIN_CONST
    parameter [255:0] PIN_CONST = 256'd0,
    parameter integer MU_PL     = 0,
    parameter [511:0] TR_CONST  = 512'd0
)(
    input  wire          clk,
    input  wire          rst_n,
    // pin register interface (wrapper decodes AXI; only called while the engine is idle)
    input  wire          pin_wr,             // write word pin_wr_idx
    input  wire [2:0]    pin_wr_idx,
    input  wire [31:0]   pin_wr_data,
    input  wire          pin_commit,         // write-once lock
    output wire          pin_valid,
    output wire [255:0]  pin_value,
    output reg           pin_wv,             // sticky: refused write/commit after lock
    output reg  [15:0]   pin_viol_cnt,
    // job interface
    input  wire          start_pre,          // pulse: hash pk image + latch c~
    input  wire          start_post,         // pulse: read c~' and compare
    output wire          busy,
    output reg           done,               // pulse
    output reg           fail,               // watchdog (with done)
    output reg  [255:0]  fp,                 // last computed fingerprint (public)
    output wire          fp_match,           // fp == pin (combinational, valid after pre done)
    output reg           ct_match,           // valid after post done
    output reg  [31:0]   pre_cycles,         // cycles of the last pre (pk hash) op
    // scratchpad host read port (muxed onto the core's h_rd_* by the wrapper while busy)
    output reg  [3:0]    rd_req_valid,
    input  wire [3:0]    rd_req_ready,
    output reg  [43:0]   rd_req_addr,
    input  wire [3:0]    rd_rsp_valid,
    output reg  [3:0]    rd_rsp_ready,
    input  wire [255:0]  rd_rsp_data,
    // PL-mu write port + message length
    input  wire [11:0]   msg_len,
    output reg           len_fail,           // msg_len out of range (with done)
    output reg  [3:0]    wr_valid,
    input  wire [3:0]    wr_ready,
    output reg  [43:0]   wr_addr,
    output reg  [255:0]  wr_data
);
    localparam integer MSG_BASE = 1304, MSG_MAXB = 1856;
    localparam [63:0] TAG = 64'h0000_3176_4E49_5057;     // "WPINv1\0\0" little-endian
    localparam integer NMSG = 517;                        // 1 tag + 4 rho + 512 t1'_hat lanes

    // ------------------------------------------------------------------ pin register
    reg [255:0] pin_r; reg pin_set;
    assign pin_valid = (PIN_MODE == 2) ? (PIN_CONST != 256'd0) : pin_set;   // zero constant = no anchor (fail closed)
    assign pin_value = (PIN_MODE == 2) ? PIN_CONST : pin_r;
    assign fp_match  = pin_valid && (fp == pin_value);

    // ------------------------------------------------------------------ Keccak-f[1600]
    function [63:0] rotl(input [63:0] v, input integer r);
        rotl = (r == 0) ? v : ((v << r) | (v >> (64 - r)));
    endfunction
    function integer rotc(input integer i);
        case (i)
            0: rotc = 0;  1: rotc = 1;  2: rotc = 62; 3: rotc = 28; 4: rotc = 27;
            5: rotc = 36; 6: rotc = 44; 7: rotc = 6;  8: rotc = 55; 9: rotc = 20;
            10: rotc = 3; 11: rotc = 10; 12: rotc = 43; 13: rotc = 25; 14: rotc = 39;
            15: rotc = 41; 16: rotc = 45; 17: rotc = 15; 18: rotc = 21; 19: rotc = 8;
            20: rotc = 18; 21: rotc = 2; 22: rotc = 61; 23: rotc = 56; default: rotc = 14;
        endcase
    endfunction
    function [63:0] rcon(input [4:0] r);
        case (r)
            5'd0:  rcon = 64'h0000000000000001; 5'd1:  rcon = 64'h0000000000008082;
            5'd2:  rcon = 64'h800000000000808A; 5'd3:  rcon = 64'h8000000080008000;
            5'd4:  rcon = 64'h000000000000808B; 5'd5:  rcon = 64'h0000000080000001;
            5'd6:  rcon = 64'h8000000080008081; 5'd7:  rcon = 64'h8000000000008009;
            5'd8:  rcon = 64'h000000000000008A; 5'd9:  rcon = 64'h0000000000000088;
            5'd10: rcon = 64'h0000000080008009; 5'd11: rcon = 64'h000000008000000A;
            5'd12: rcon = 64'h000000008000808B; 5'd13: rcon = 64'h800000000000008B;
            5'd14: rcon = 64'h8000000000008089; 5'd15: rcon = 64'h8000000000008003;
            5'd16: rcon = 64'h8000000000008002; 5'd17: rcon = 64'h8000000000000080;
            5'd18: rcon = 64'h000000000000800A; 5'd19: rcon = 64'h800000008000000A;
            5'd20: rcon = 64'h8000000080008081; 5'd21: rcon = 64'h8000000000008080;
            5'd22: rcon = 64'h0000000080000001; default: rcon = 64'h8000000080008008;
        endcase
    endfunction
    function [1599:0] kround(input [1599:0] s, input [4:0] r);
        reg [63:0] a [0:24]; reg [63:0] b [0:24]; reg [63:0] c [0:4]; reg [63:0] d [0:4];
        integer i, x, y;
        begin
            for (i = 0; i < 25; i = i + 1) a[i] = s[64*i +: 64];
            for (x = 0; x < 5; x = x + 1) c[x] = a[x] ^ a[x+5] ^ a[x+10] ^ a[x+15] ^ a[x+20];
            for (x = 0; x < 5; x = x + 1) d[x] = c[(x+4)%5] ^ rotl(c[(x+1)%5], 1);
            for (i = 0; i < 25; i = i + 1) a[i] = a[i] ^ d[i%5];
            for (x = 0; x < 5; x = x + 1)
                for (y = 0; y < 5; y = y + 1)
                    b[y + 5*((2*x + 3*y) % 5)] = rotl(a[x + 5*y], rotc(x + 5*y));
            for (x = 0; x < 5; x = x + 1)
                for (y = 0; y < 5; y = y + 1)
                    a[x + 5*y] = b[x + 5*y] ^ (~b[(x+1)%5 + 5*y] & b[(x+2)%5 + 5*y]);
            a[0] = a[0] ^ rcon(r);
            for (i = 0; i < 25; i = i + 1) kround[64*i +: 64] = a[i];
        end
    endfunction

    // ------------------------------------------------------------------ FSM
    localparam [3:0] G_IDLE=0, G_FETCH=1, G_REQ=2, G_RSP=3, G_ABS=4, G_PERM=5, G_PAD=6, G_CT=7, G_FIN=8,
                     G_MU0=9, G_MUW=10, G_MUWW=11;
    reg          ph;                   // absorb source: 0 = pk image (FP), 1 = tr || M' (mu)
    reg  [9:0]   nlanes;               // message lanes of the current hash
    reg          pad_inline;           // last M' lane partial: 0x1F already placed
    reg  [2:0]   rem_b;                // msg_len % 8
    reg  [3:0]   muw;                  // mu word being written
    wire [9:0]   mu_lanes = 10'd8 + {1'b0, msg_len[11:3]} + (msg_len[2:0] != 3'd0);
    function [63:0] lane_mask(input [2:0] r);       // keep r low bytes (r = 1..7)
        lane_mask = ~(64'hFFFF_FFFF_FFFF_FFFF << (8*r));
    endfunction
    reg [3:0]    gst;
    reg          post;                 // 0 = PRE (hash + latch c~), 1 = POST (compare c~')
    reg [1599:0] S;
    reg [4:0]    lane, rnd;
    reg [9:0]    widx;                 // message lane index 0..NMSG
    reg [2:0]    cidx;                 // c~ word index 0..3
    reg          in_ct, msg_done, padded;
    reg [1:0]    bank;
    reg [63:0]   word;
    reg [255:0]  ct_in;
    reg [15:0]   wdog;
    reg          ct_ok;
    assign busy = (gst != G_IDLE);
    wire [1599:0] S_rnd = kround(S, rnd);           // the single round instance

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            pin_r <= 256'd0; pin_set <= 1'b0; pin_wv <= 1'b0; pin_viol_cnt <= 16'd0;
            gst <= G_IDLE; post <= 1'b0; S <= 1600'd0; lane <= 0; rnd <= 0; widx <= 0; cidx <= 0;
            in_ct <= 1'b0; msg_done <= 1'b0; padded <= 1'b0; bank <= 0; word <= 0; ct_in <= 0;
            wdog <= 0; ct_ok <= 1'b0; done <= 1'b0; fail <= 1'b0; fp <= 256'd0; ct_match <= 1'b0;
            pre_cycles <= 0; rd_req_valid <= 0; rd_req_addr <= 0; rd_rsp_ready <= 0;
            ph <= 1'b0; nlanes <= 0; pad_inline <= 1'b0; rem_b <= 0; muw <= 0; len_fail <= 1'b0;
            wr_valid <= 0; wr_addr <= 0; wr_data <= 0;
        end else begin
            done <= 1'b0;
            // ---- pin register: write-once after reset (or hard-wired) ----
            if (pin_wr || pin_commit) begin
                if (PIN_MODE == 2 || pin_valid) begin
                    pin_wv <= 1'b1; if (~&pin_viol_cnt) pin_viol_cnt <= pin_viol_cnt + 1'b1;
                end else if (pin_commit) pin_set <= 1'b1;
                else pin_r[pin_wr_idx*32 +: 32] <= pin_wr_data;
            end
            // ---- job FSM ----
            if (gst != G_IDLE) begin
                wdog <= wdog + 1'b1;
                if (!post) pre_cycles <= pre_cycles + 1'b1;
            end
            case (gst)
                G_IDLE: begin
                    fail <= 1'b0; wdog <= 0;
                    if (start_pre) begin
                        ph <= 1'b0; nlanes <= NMSG; pad_inline <= 1'b0; len_fail <= 1'b0;
                        post <= 1'b0; S <= 1600'd0; lane <= 0; widx <= 0; cidx <= 0; in_ct <= 1'b0;
                        msg_done <= 1'b0; padded <= 1'b0; ct_in <= 256'd0; pre_cycles <= 32'd1;
                        fp <= 256'd0; ct_match <= 1'b0; gst <= G_FETCH;
                    end else if (start_post) begin
                        post <= 1'b1; cidx <= 0; in_ct <= 1'b1; ct_ok <= 1'b1; ct_match <= 1'b0; gst <= G_CT;
                    end
                end
                G_FETCH: begin                                   // next message lane
                    if (ph) begin                                // tr lanes from the constant, then M' words
                        if (widx < 10'd8) begin word <= TR_CONST[widx[2:0]*64 +: 64]; gst <= G_ABS; end
                        else begin
                            in_ct <= 1'b0; bank <= 2'd2; rd_req_valid <= 4'b0100;
                            rd_req_addr <= {4{11'd1296 + {1'b0, widx}}};          // MSG_BASE + (widx - 8)
                            gst <= G_REQ;
                        end
                    end else if (widx == 10'd0) begin word <= TAG; gst <= G_ABS; end
                    else begin
                        in_ct <= 1'b0;
                        if (widx <= 10'd4) begin bank <= 2'd2; rd_req_valid <= 4'b0100; rd_req_addr <= {4{11'd511 + {1'b0, widx}}}; end
                        else begin bank <= 2'd3; rd_req_valid <= 4'b1000; rd_req_addr <= {4{11'd1531 + {1'b0, widx}}}; end
                        gst <= G_REQ;
                    end
                end
                G_CT: begin                                      // c~ (PRE) / c~' (POST) word cidx
                    bank <= 2'd1; rd_req_valid <= 4'b0010; rd_req_addr <= {4{11'd1150 + {8'd0, cidx}}};
                    gst <= G_REQ;
                end
                G_REQ: begin
                    if (|(rd_req_valid & rd_req_ready)) begin
                        rd_req_valid <= 4'b0000; rd_rsp_ready <= 4'b0001 << bank; gst <= G_RSP;
                    end
                end
                G_RSP: begin
                    if (|(rd_rsp_ready & rd_rsp_valid)) begin
                        rd_rsp_ready <= 4'b0000;
                        if (in_ct) begin
                            if (post) begin if (rd_rsp_data[bank*64 +: 64] != ct_in[cidx*64 +: 64]) ct_ok <= 1'b0; end
                            else ct_in[cidx*64 +: 64] <= rd_rsp_data[bank*64 +: 64];
                            if (cidx == 3'd3) gst <= G_FIN; else begin cidx <= cidx + 1'b1; gst <= G_CT; end
                        end else if (ph && widx == nlanes - 1'b1 && rem_b != 3'd0) begin   // partial last M' lane
                            word <= (rd_rsp_data[bank*64 +: 64] & lane_mask(rem_b)) | (64'h1F << (8*rem_b));
                            pad_inline <= 1'b1; gst <= G_ABS;
                        end else begin
                            word <= rd_rsp_data[bank*64 +: 64]; gst <= G_ABS;
                        end
                    end
                end
                G_ABS: begin                                     // XOR lane into the rate
                    for (k = 0; k < 17; k = k + 1) if (lane == k) S[64*k +: 64] <= S[64*k +: 64] ^ word;
                    widx <= widx + 1'b1;
                    if (widx == nlanes - 1'b1) msg_done <= 1'b1;
                    if (widx == nlanes - 1'b1 && pad_inline) begin gst <= G_PAD; end      // 0x1F inline; G_PAD adds 0x80
                    else if (lane == 5'd16) begin lane <= 0; rnd <= 0; gst <= G_PERM; end
                    else begin
                        lane <= lane + 1'b1;
                        gst <= (widx == nlanes - 1'b1) ? G_PAD : G_FETCH;
                    end
                end
                G_PAD: begin                                     // SHAKE pad: 0x1F ... 0x80
                    for (k = 0; k < 17; k = k + 1) begin
                        if (pad_inline) begin if (k == 16) S[64*k +: 64] <= S[64*k +: 64] ^ 64'h8000_0000_0000_0000; end
                        else if (lane == k && k == 16) S[64*k +: 64] <= S[64*k +: 64] ^ 64'h8000_0000_0000_001F;
                        else if (lane == k) S[64*k +: 64] <= S[64*k +: 64] ^ 64'h0000_0000_0000_001F;
                        else if (k == 16) S[64*k +: 64] <= S[64*k +: 64] ^ 64'h8000_0000_0000_0000;
                    end
                    padded <= 1'b1; rnd <= 0; gst <= G_PERM;
                end
                G_PERM: begin
                    S <= S_rnd;
                    if (rnd == 5'd23) begin
                        if (!msg_done) gst <= G_FETCH;
                        else if (!padded) gst <= G_PAD;
                        else if (ph) begin S <= S_rnd; muw <= 0; gst <= G_MUW; end        // squeeze mu (8 lanes)
                        else begin fp <= S_rnd[255:0]; in_ct <= 1'b1; cidx <= 0; gst <= G_CT; end
                    end else rnd <= rnd + 1'b1;
                end
                G_FIN: begin
                    if (post) ct_match <= ct_ok;
                    if (!post && MU_PL != 0 && !ph && fp_match) gst <= G_MU0;            // mu only for a pinned pk
                    else begin done <= 1'b1; gst <= G_IDLE; end
                end
                G_MU0: begin
                    if (msg_len < 12'd2 || msg_len > MSG_MAXB) begin len_fail <= 1'b1; done <= 1'b1; gst <= G_IDLE; end
                    else begin
                        ph <= 1'b1; S <= 1600'd0; lane <= 0; widx <= 0; msg_done <= 1'b0; padded <= 1'b0;
                        pad_inline <= 1'b0; nlanes <= mu_lanes; rem_b <= msg_len[2:0]; gst <= G_FETCH;
                    end
                end
                G_MUW: begin                                     // write mu lane muw to b2[1048 + muw]
                    wr_valid <= 4'b0100; wr_addr <= {4{11'd1048 + {7'd0, muw}}};
                    wr_data  <= {4{S[muw[2:0]*64 +: 64]}}; gst <= G_MUWW;
                end
                G_MUWW: begin
                    if (|(wr_valid & wr_ready)) begin
                        wr_valid <= 4'd0;
                        if (muw == 4'd7) begin done <= 1'b1; gst <= G_IDLE; end
                        else begin muw <= muw + 1'b1; gst <= G_MUW; end
                    end
                end
                default: gst <= G_IDLE;
            endcase
            if (gst != G_IDLE && &wdog) begin                    // fail closed
                rd_req_valid <= 0; rd_rsp_ready <= 0; wr_valid <= 0; fail <= 1'b1; done <= 1'b1; ct_match <= 1'b0;
                fp <= 256'd0; gst <= G_IDLE;
            end
        end
    end
endmodule
