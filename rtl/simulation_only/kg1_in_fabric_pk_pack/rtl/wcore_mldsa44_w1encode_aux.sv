`timescale 1ns / 1ps
// WEPWAWET ML-DSA-44 W1 encoding (gamma2=(q-1)/88).
// AUX op 0x36. Exactly 512 64-bit words = 1024 coefficients (4 polys),
// packed as 6-bit integers into exactly 96 64-bit output words.
// Inputs must be canonical HighBits values in [0,43]. The source bank
// must differ from the destination bank. Invalid descriptor fails closed.
// keygen: AUX op 0x3C = SimpleBitPack(t1, 10) (FIPS 204 Alg. 22 line 2): 512 words (4 polys, values
// in [0,1023]) -> exactly 160 output words, LSB-first, i.e. pk[32..1311] as little-endian 64-bit words.
// Any invalid coefficient discovered after processing starts can leave
// a partially written destination; caller must discard on error.
module wcore_mldsa44_w1encode_aux #(
    parameter integer ADDR_W=11, BANKS=4
)(
    input wire clk, rst_n, abort,
    input wire aux_valid, output wire aux_ready,
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
    localparam [2:0] S_IDLE=0,S_STEP=1,S_RD_REQ=2,S_RD_RSP=3,
                     S_APPEND=4,S_WRITE=5,S_DONE=6,S_ERROR=7;
    (* fsm_encoding="none" *) reg [2:0] state;
    reg [1:0] src_bank_q,dst_bank_q;
    reg [ADDR_W-1:0] src_addr_q,dst_addr_q;
    reg [9:0] rd_index;
    reg [7:0] wr_index;
    reg [83:0] bits_q;
    reg [6:0] bit_count;
    reg [19:0] pair_q;
    reg is_t1;
    wire [ADDR_W+1:0] src_end = {2'd0,aux_src_addr}+13'd512;
    wire [ADDR_W+1:0] dst_end = {2'd0,aux_dst_addr}+((aux_op==8'h3C) ? 13'd160 : 13'd96);
    wire descriptor_ok = (aux_op==8'h36 || aux_op==8'h3C) && (aux_words==12'd512) &&
                          (aux_src_bank<BANKS) && (aux_dst_bank<BANKS) &&
                          (aux_src_bank!=aux_dst_bank) &&
                          (src_end<=(1<<ADDR_W)) &&
                          (dst_end<=(1<<ADDR_W));
    wire [63:0] input_word = sp_rd_rsp_data[src_bank_q*64 +: 64];
    wire [31:0] val0 = input_word[31:0];
    wire [31:0] val1 = input_word[63:32];
    assign aux_ready = (state==S_IDLE) && !abort;
    assign aux_done = (state==S_DONE) && !abort;
    assign aux_error = (state==S_ERROR) && !abort;
    assign aux_reject_set = 1'b0;
    always @* begin
        sp_rd_req_valid = {BANKS{1'b0}};
        sp_rd_req_addr = {(BANKS*ADDR_W){1'b0}};
        sp_rd_rsp_ready = {BANKS{1'b0}};
        sp_wr_req_valid = {BANKS{1'b0}};
        sp_wr_req_addr = {(BANKS*ADDR_W){1'b0}};
        sp_wr_req_data = {(BANKS*64){1'b0}};
        if (!abort) begin
            if (state==S_RD_REQ) begin
                sp_rd_req_valid[src_bank_q]=1'b1;
                sp_rd_req_addr[src_bank_q*ADDR_W +: ADDR_W]=src_addr_q+rd_index;
            end
            if (state==S_RD_RSP) sp_rd_rsp_ready[src_bank_q]=1'b1;
            if (state==S_WRITE) begin
                sp_wr_req_valid[dst_bank_q]=1'b1;
                sp_wr_req_addr[dst_bank_q*ADDR_W +: ADDR_W]=dst_addr_q+wr_index;
                sp_wr_req_data[dst_bank_q*64 +: 64]=bits_q[63:0];
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE;src_bank_q<=0;dst_bank_q<=0;
            src_addr_q<=0;dst_addr_q<=0;rd_index<=0;wr_index<=0;
            bits_q<=0;bit_count<=0;pair_q<=0;is_t1<=0;
        end else if (abort) begin
            state<=S_IDLE;bits_q<=0;bit_count<=0;
        end else begin
            case (state)
                S_IDLE: if (aux_valid && aux_ready) begin
                    if (!descriptor_ok) state<=S_ERROR;
                    else begin
                        src_bank_q<=aux_src_bank;dst_bank_q<=aux_dst_bank;
                        src_addr_q<=aux_src_addr;dst_addr_q<=aux_dst_addr;
                        rd_index<=0;wr_index<=0;bits_q<=0;bit_count<=0;
                        is_t1<=(aux_op==8'h3C);
                        state<=S_STEP;
                    end
                end
                S_STEP: begin
                    if (bit_count>=7'd64) state<=S_WRITE;
                    else if (rd_index<10'd512) state<=S_RD_REQ;
                    else if (wr_index==(is_t1 ? 8'd160 : 8'd96) && bit_count==0) state<=S_DONE;
                    else state<=S_ERROR;
                end
                S_RD_REQ: if (sp_rd_req_ready[src_bank_q]) state<=S_RD_RSP;
                S_RD_RSP: if (sp_rd_rsp_valid[src_bank_q]) begin
                    if (is_t1 ? (val0>32'd1023 || val1>32'd1023) : (val0>32'd43 || val1>32'd43)) state<=S_ERROR;
                    else begin
                        pair_q<=is_t1 ? {val1[9:0],val0[9:0]} : {8'd0,val1[5:0],val0[5:0]};
                        rd_index<=rd_index+1'b1;
                        state<=S_APPEND;
                    end
                end
                S_APPEND: begin
                    bits_q<=bits_q | ({64'd0,pair_q} << bit_count);
                    bit_count<=bit_count+(is_t1 ? 7'd20 : 7'd12);
                    state<=S_STEP;
                end
                S_WRITE: if(sp_wr_req_ready[dst_bank_q]) begin
                    bits_q<=bits_q>>64;
                    bit_count<=bit_count-7'd64;
                    wr_index<=wr_index+1'b1;
                    state<=S_STEP;
                end
                S_DONE: state<=S_IDLE;
                S_ERROR: state<=S_IDLE;
                default:state<=S_ERROR;
            endcase
        end
    end
endmodule
