`timescale 1ns / 1ps
// WEPWAWET Stage14: autonomous SHAKE byte-length programming.
// New module; DO NOT modify the routed Stage8 checkpoint.
// AXI-Lite writes are serialized through the existing wcore_axil_master.
// SHAKE length registers 0x10/0x18 are the Vitis HLS s_axilite
// msg_bytes/out_bytes arguments of the supplied SHAKE128/256 source.
module wcore_cfg_executor_stage14 #(
    parameter [31:0] NTT_BASE       = 32'h8003_0000,
    parameter [31:0] INTT_BASE      = 32'h8002_0000,
    parameter [31:0] POLYMUL_BASE   = 32'h8004_0000,
    parameter [31:0] SHAKE256_BASE  = 32'h8007_0000,
    parameter [31:0] SHAKE128_BASE  = 32'h8005_0000,
    parameter [31:0] DIST_BASE      = 32'hA002_0000,
    parameter [31:0] COLL_BASE      = 32'hA001_0000
)(
    input wire clk, input wire rst_n, input wire abort,
    input wire cfg_valid, output wire cfg_ready,
    input wire [6:0] cfg_index, input wire [2:0] cfg_lane,
    input wire cfg_phase,
    input wire [11:0] cfg_tx_words, input wire [11:0] cfg_rx_words,
    // Used only with SHAKE dynamic profiles 0x73 and 0x74.
    // MUST originate from a job-latched trusted metadata path, not software
    // writes between WCORE microinstructions.
    input wire shake_dynamic_valid,
    input wire [31:0] shake_msg_bytes,
    input wire [31:0] shake_out_bytes,
    output wire cfg_done, output wire cfg_error,
    output wire req_valid, input wire req_ready, output wire req_write,
    output reg [31:0] req_addr, output reg [31:0] req_wdata,
    output wire [3:0] req_wstrb,
    input wire rsp_valid, output wire rsp_ready,
    input wire rsp_error, input wire poisoned
);
    localparam [2:0] IDLE=3'd0, SEND=3'd1, WAIT_RSP=3'd2,
                     DONE=3'd3, ERROR=3'd4;
    (* fsm_encoding = "none" *) reg [2:0] state;
    reg [3:0] step;
    reg phase_q;
    reg [2:0] lane_q;
    reg [6:0] index_q;
    reg [11:0] tx_q, rx_q;
    reg [31:0] msg_q, out_q;
    reg armed;
    reg [2:0] armed_lane;
    reg [6:0] armed_index;
    reg [11:0] armed_tx, armed_rx;
    reg [31:0] armed_msg, armed_out;

    wire is_shake = (cfg_lane == 3'd3 || cfg_lane == 3'd4);
    wire core_allowed = (cfg_lane <= 3'd2) &&
                        (cfg_index == {4'b0,cfg_lane});
    wire core_counts = ((cfg_lane == 3'd0 || cfg_lane == 3'd1) &&
                        cfg_tx_words == 12'd128 && cfg_rx_words == 12'd128) ||
                       ((cfg_lane == 3'd2) &&
                        cfg_tx_words == 12'd256 && cfg_rx_words == 12'd128);
    // SHAKE profiles, selected by existing seven-bit WCORE instruction cfg_index.
    // Additional profiles can be added after independent algorithm validation.
    reg shake_profile_ok;
    reg shake_profile_dynamic;
    reg [31:0] profile_msg, profile_out;
    always @* begin
        shake_profile_ok = 1'b1;
        shake_profile_dynamic = 1'b0;
        profile_msg = 32'd0;
        profile_out = 32'd0;
        case ({cfg_lane,cfg_index})
            {3'd4,7'h44}: begin profile_msg=32'd34; profile_out=32'd1008; end // ExpandA: rho32+indices2
            {3'd3,7'h43}: begin profile_msg=32'd66; profile_out=32'd576; end  // ExpandMask: seed64+nonce2
            {3'd3,7'h03}: begin profile_msg=32'd832; profile_out=32'd32; end // mu64 || w1 768 -> c_tilde32
            {3'd3,7'h13}: begin profile_msg=32'd32; profile_out=32'd272; end // SampleInBall SHAKE256(c_tilde32)
            {3'd3,7'h53}: begin profile_msg=32'd64; profile_out=32'd272; end  // SampleInBall input, 34x64b
            {3'd3,7'h63}: begin profile_msg=32'd64; profile_out=32'd64; end   // fixed hash fragment
            {3'd3,7'h23}: begin profile_msg=32'd128; profile_out=32'd32; end  // seal_v8: TRNG conditioning 1024 raw bits -> rnd32
            {3'd3,7'h33}: begin profile_msg=32'd128; profile_out=32'd64; end  // seal_v8: rho'' = H(K32||rnd32||mu64, 64)
            {3'd3,7'h2B}: begin profile_msg=32'd34; profile_out=32'd128; end  // seal_v8: KeyGen H(xi||k||l, 128)
            {3'd3,7'h3B}: begin profile_msg=32'd34; profile_out=32'd96; end   // seal_v8: KeyGen H(xi||k||l, 96) = rho||rho'
            {3'd3,7'h73}, {3'd4,7'h74}: begin
                shake_profile_dynamic=1'b1;
                profile_msg=shake_msg_bytes;
                profile_out=shake_out_bytes;
            end
            default: shake_profile_ok=1'b0;
        endcase
    end
    wire [32:0] msg_beats = ({1'b0,profile_msg} + 33'd7) >> 3;
    wire [32:0] out_beats = ({1'b0,profile_out} + 33'd7) >> 3;
    wire sha_counts_ok = is_shake && shake_profile_ok &&
        (!shake_profile_dynamic || shake_dynamic_valid) &&
        (profile_msg != 32'd0) && (profile_out != 32'd0) &&
        (msg_beats <= 33'd2048) && (out_beats <= 33'd2048) &&
        (cfg_tx_words != 12'd0) && (cfg_rx_words != 12'd0) &&
        ({21'd0,cfg_tx_words} == msg_beats) &&
        ({21'd0,cfg_rx_words} == out_beats);
    wire shape_ok = (core_allowed && core_counts) || sha_counts_ok;
    wire start_allowed = armed &&
        (cfg_lane == armed_lane) && (cfg_index == armed_index) &&
        (cfg_tx_words == armed_tx) && (cfg_rx_words == armed_rx) &&
        (!is_shake || (profile_msg == armed_msg && profile_out == armed_out));

    assign cfg_ready = (state == IDLE) && !abort && !poisoned;
    assign cfg_done = (state == DONE) && !abort;
    assign cfg_error = (state == ERROR) && !abort;
    assign req_valid = (state == SEND) && !abort && !poisoned;
    assign req_write = 1'b1;
    assign req_wstrb = 4'hF;
    assign rsp_ready = (state == WAIT_RSP) && !abort;

    reg [31:0] kernel_base;
    always @* begin
        case (lane_q)
            3'd0: kernel_base = NTT_BASE;
            3'd1: kernel_base = INTT_BASE;
            3'd2: kernel_base = POLYMUL_BASE;
            3'd3: kernel_base = SHAKE256_BASE;
            3'd4: kernel_base = SHAKE128_BASE;
            default: kernel_base = 32'd0;
        endcase
        req_addr = 32'd0;
        req_wdata = 32'd0;
        case (step)
            4'd0: begin req_addr = DIST_BASE + 32'h10; req_wdata = {29'd0,lane_q}; end
            4'd1: begin req_addr = DIST_BASE + 32'h18; req_wdata = {20'd0,tx_q}; end
            4'd2: begin req_addr = COLL_BASE + 32'h10; req_wdata = {29'd0,lane_q}; end
            4'd3: begin req_addr = COLL_BASE + 32'h18; req_wdata = {20'd0,rx_q}; end
            4'd4: begin req_addr = kernel_base + 32'h10; req_wdata = msg_q; end
            4'd5: begin req_addr = kernel_base + 32'h18; req_wdata = out_q; end
            4'd6: begin req_addr = DIST_BASE; req_wdata = 32'd1; end
            4'd7: begin req_addr = COLL_BASE; req_wdata = 32'd1; end
            4'd8: begin req_addr = kernel_base; req_wdata = 32'd1; end
            default: begin req_addr = 0; req_wdata = 0; end
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; step<=0; phase_q<=0; lane_q<=0;
            index_q<=0; tx_q<=0; rx_q<=0; msg_q<=0; out_q<=0;
            armed<=0;armed_lane<=0;armed_index<=0;armed_tx<=0;
            armed_rx<=0;armed_msg<=0;armed_out<=0;
        end else if (abort) begin
            state<=IDLE;
            armed<=0;
        end else if (poisoned) begin
            if (state != IDLE) state<=ERROR;
            armed<=0;
        end else begin
            case (state)
                IDLE: if (cfg_valid && cfg_ready) begin
                    if (!shape_ok || (cfg_phase && !start_allowed)) begin
                        state<=ERROR; armed<=0;
                    end else begin
                        lane_q<=cfg_lane; index_q<=cfg_index;
                        tx_q<=cfg_tx_words; rx_q<=cfg_rx_words;
                        msg_q<=profile_msg; out_q<=profile_out;
                        phase_q<=cfg_phase;
                        step<=cfg_phase ? 4'd8 : 4'd0;
                        if (!cfg_phase) armed<=0;
                        state<=SEND;
                    end
                end
                SEND: if (req_valid && req_ready) state<=WAIT_RSP;
                WAIT_RSP: if (rsp_valid && rsp_ready) begin
                    if (rsp_error) begin
                        armed<=0; state<=ERROR;
                    end else if ((phase_q && step==4'd8) ||
                                (!phase_q && step==4'd7)) begin
                        if (phase_q) armed<=0;
                        else begin
                            armed<=1;armed_lane<=lane_q;armed_index<=index_q;
                            armed_tx<=tx_q;armed_rx<=rx_q;
                            armed_msg<=msg_q;armed_out<=out_q;
                        end
                        state<=DONE;
                    end else begin
                        // Original cores configure routers and skip SHAKE argument writes.
                        if (!phase_q && lane_q <= 3'd2 && step==4'd3)
                            step<=4'd6;
                        else step<=step+1'b1;
                        state<=SEND;
                    end
                end
                DONE: state<=IDLE;
                ERROR: state<=IDLE;
                default: begin state<=ERROR;armed<=0;end
            endcase
        end
    end
endmodule
