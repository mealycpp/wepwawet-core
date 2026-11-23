`timescale 1ns/1ps
// Stage 12: FIPS 204 Algorithm 29 SampleInBall for ML-DSA-44 (TAU=39).
// Input: SHAKE256(seed32) XOF output as 64-bit packed words, first byte at
// bits [7:0]. Input stream must start at XOF byte zero (8-byte sign prefix).
// Output: 256 coefficients c in {0,1,Q-1}, packed 2 x 32b per 64b word.
// Source and destination scratchpad banks must be different.
// Phase 1 clears LOCAL 256x2-bit coefficient memory, not destination.
// Phase 2 performs FIPS204 Fisher-Yates swaps with sequential RAM updates.
// Phase 3 writes exactly 128 output words *only after complete sampling*.
// Insufficient XOF bytes produce ERROR without writing any destination data.
// NOT a SHAKE core: upstream FPGA must provide correct streaming SHAKE256 XOF.
// The implementation is intended to be resource-shared and pipelined;
// the 300MHz timing target requires independent synthesis and routing.
module wcore_mldsa44_sampleinball_aux #(
    parameter integer ADDR_W=11,
    parameter integer BANKS=4
)(
    input wire clk, rst_n, abort,
    input wire aux_valid,
    output wire aux_ready,
    input wire [7:0] aux_op,
    input wire [1:0] aux_src_bank, aux_dst_bank,
    input wire [ADDR_W-1:0] aux_src_addr, aux_dst_addr,
    input wire [ADDR_W:0] aux_words,
    output wire aux_done, aux_error, aux_reject_set,
    output reg [BANKS-1:0] sp_rd_req_valid,
    input wire [BANKS-1:0] sp_rd_req_ready,
    output reg [BANKS*ADDR_W-1:0] sp_rd_req_addr,
    input wire [BANKS-1:0] sp_rd_rsp_valid,
    output reg [BANKS-1:0] sp_rd_rsp_ready,
    input wire [BANKS*64-1:0] sp_rd_rsp_data,
    output reg [BANKS-1:0] sp_wr_req_valid,
    input wire [BANKS-1:0] sp_wr_req_ready,
    output reg [BANKS*ADDR_W-1:0] sp_wr_req_addr,
    output reg [BANKS*64-1:0] sp_wr_req_data
);
    localparam [7:0] OP_SAMPLEINBALL = 8'h31;
    localparam [31:0] QMINUS1 = 32'd8380416;
    localparam [7:0] FIRST_INDEX = 8'd217;
    localparam [3:0]
        S_IDLE=0, S_CLEAR=1, S_RD_REQ=2, S_RD_RSP=3,
        S_SIGNS=4, S_BYTE=5, S_EVAL=6, S_CJ_READ=7,
        S_CI_WRITE=8, S_CJ_WRITE=9, S_PACK=10,
        S_WRITE=11, S_DONE=12, S_ERROR=13;
    (* fsm_encoding="none" *) reg [3:0] state;
    reg [1:0] src_bank_q, dst_bank_q;
    reg [ADDR_W-1:0] src_addr_q, dst_addr_q;
    reg [ADDR_W:0] src_words_q, word_ptr;
    reg [63:0] xof_word, signs, output_word;
    reg [3:0] byte_ptr;
    reg [7:0] candidate, j;
    reg [7:0] i;
    reg [7:0] clear_ptr;
    reg [7:0] out_ptr;
    reg [1:0] coeff [0:255];  // 0 zero, 1 +1, 2 -1
    reg [1:0] saved_cj;

    // Explicit widened bounds protect 2048-word scratchpad per bank.
    wire [ADDR_W+1:0] src_end = {2'b0,aux_src_addr} + {1'b0,aux_words};
    wire [ADDR_W+1:0] dst_end = {2'b0,aux_dst_addr} + {{(ADDR_W+1-7){1'b0}},8'd128};
    wire shape_ok = aux_op==OP_SAMPLEINBALL &&
        aux_src_bank < BANKS && aux_dst_bank < BANKS &&
        aux_src_bank != aux_dst_bank && aux_words>=6 &&
        src_end <= (1 << ADDR_W) && dst_end <= (1 << ADDR_W);

    function [31:0] encode_coeff;
        input [1:0] c;
        begin
            case (c)
                2'd0: encode_coeff = 32'd0;
                2'd1: encode_coeff = 32'd1;
                2'd2: encode_coeff = QMINUS1;
                default: encode_coeff = 32'hffffffff;
            endcase
        end
    endfunction

    assign aux_ready = (state==S_IDLE) && !abort;
    assign aux_done  = (state==S_DONE) && !abort;
    assign aux_error = (state==S_ERROR) && !abort;
    assign aux_reject_set = 1'b0; // sample-position rejection != signature rejection

    always @* begin
        sp_rd_req_valid={BANKS{1'b0}};
        sp_rd_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_rd_rsp_ready={BANKS{1'b0}};
        sp_wr_req_valid={BANKS{1'b0}};
        sp_wr_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_wr_req_data={(BANKS*64){1'b0}};
        if(!abort) begin
            if(state==S_RD_REQ && word_ptr<src_words_q) begin
                sp_rd_req_valid[src_bank_q]=1'b1;
                sp_rd_req_addr[src_bank_q*ADDR_W +: ADDR_W]=src_addr_q+word_ptr;
            end
            if(state==S_RD_RSP) sp_rd_rsp_ready[src_bank_q]=1'b1;
            if(state==S_WRITE) begin
                sp_wr_req_valid[dst_bank_q]=1'b1;
                sp_wr_req_addr[dst_bank_q*ADDR_W +: ADDR_W]=dst_addr_q+out_ptr;
                sp_wr_req_data[dst_bank_q*64 +: 64]=output_word;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=S_IDLE;
            src_bank_q<=0; dst_bank_q<=0;
            src_addr_q<=0; dst_addr_q<=0;
            src_words_q<=0; word_ptr<=0; xof_word<=0;
            signs<=0; byte_ptr<=0; candidate<=0; j<=0; i<=0;
            clear_ptr<=0; out_ptr<=0; output_word<=0; saved_cj<=0;
        end else if(abort) begin
            state<=S_IDLE;
            // No destination writes while aborted. Next start clears local RAM.
        end else begin
            case(state)
                S_IDLE: if(aux_valid && aux_ready) begin
                    if(!shape_ok) state<=S_ERROR;
                    else begin
                        src_bank_q<=aux_src_bank;
                        dst_bank_q<=aux_dst_bank;
                        src_addr_q<=aux_src_addr;
                        dst_addr_q<=aux_dst_addr;
                        src_words_q<=aux_words;
                        word_ptr<=0;
                        byte_ptr<=0;
                        i<=FIRST_INDEX;
                        clear_ptr<=0;
                        out_ptr<=0;
                        state<=S_CLEAR;
                    end
                end
                S_CLEAR: begin
                    coeff[clear_ptr]<=2'd0;
                    if(clear_ptr==8'hff) state<=S_RD_REQ;
                    else clear_ptr<=clear_ptr+1'b1;
                end
                S_RD_REQ: begin
                    if(word_ptr>=src_words_q) state<=S_ERROR;
                    else if(sp_rd_req_ready[src_bank_q]) state<=S_RD_RSP;
                end
                S_RD_RSP: if(sp_rd_rsp_valid[src_bank_q]) begin
                    xof_word<=sp_rd_rsp_data[src_bank_q*64 +:64];
                    word_ptr<=word_ptr+1'b1;
                    byte_ptr<=0;
                    if(word_ptr==0) state<=S_SIGNS;
                    else state<=S_BYTE;
                end
                S_SIGNS: begin
                    signs<=xof_word;
                    byte_ptr<=4'd8;  // next consumed byte is in next word
                    state<=S_BYTE;
                end
                S_BYTE: begin
                    if(byte_ptr==4'd8) state<=S_RD_REQ;
                    else begin
                        candidate<=xof_word[byte_ptr*8 +:8];
                        byte_ptr<=byte_ptr+1'b1;
                        state<=S_EVAL;
                    end
                end
                S_EVAL: begin
                    if(candidate<=i) begin
                        j<=candidate;
                        state<=S_CJ_READ;
                    end else state<=S_BYTE;
                end
                S_CJ_READ: begin
                    saved_cj<=coeff[j];
                    state<=S_CI_WRITE;
                end
                S_CI_WRITE: begin
                    coeff[i]<=saved_cj;
                    state<=S_CJ_WRITE;
                end
                S_CJ_WRITE: begin
                    coeff[j]<=signs[i-FIRST_INDEX] ? 2'd2 : 2'd1;
                    if(i==8'hff) begin
                        out_ptr<=0;
                        state<=S_PACK;
                    end else begin
                        i<=i+1'b1;
                        state<=S_BYTE;
                    end
                end
                S_PACK: begin
                    output_word<={encode_coeff(coeff[{out_ptr[6:0],1'b1}]),
                                  encode_coeff(coeff[{out_ptr[6:0],1'b0}])};
                    state<=S_WRITE;
                end
                S_WRITE: if(sp_wr_req_ready[dst_bank_q]) begin
                    if(out_ptr==8'd127) state<=S_DONE;
                    else begin
                        out_ptr<=out_ptr+1'b1;
                        state<=S_PACK;
                    end
                end
                S_DONE: state<=S_IDLE;
                S_ERROR: state<=S_IDLE;
                default: state<=S_ERROR;
            endcase
        end
    end
endmodule
