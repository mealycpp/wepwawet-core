`timescale 1ns/1ps
// WEPWAWET Stage 13: FIPS204 ML-DSA-44 Gamma1 bit-unpacking for ExpandMask.
// OP 0x32, EXACTLY 72 x 64bit XOF input words (576 bytes) -> 128 x 64bit
// output words (256 coefficients). Input is byte-exact SHAKE256 output,
// little-endian bit order. The upstream SHAKE generator is NOT included.
// Output is signed two's-complement 32-bit coefficients in [-131071,131072],
// each scratchpad word {coeff[2*i+1],coeff[2*i]}.
// Source and destination must occupy DIFFERENT scratchpad banks.
// Invalid descriptors fail before any destination writes. Abort during
// operation may leave a PARTIALLY UPDATED destination; no rollback.
// Shift register only up to 32b; one XOF byte is ingested per cycle,
// with 18b coefficient extraction pipelined through a separate state.
module wcore_mldsa44_gamma1_unpack_aux #(
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
    localparam [7:0] OP_GAMMA1_UNPACK=8'h32;
    localparam [3:0]
        S_IDLE=0, S_STEP=1, S_RD_REQ=2, S_RD_RSP=3,
        S_APPEND=4, S_DECODE=5, S_WRITE=6, S_DONE=7, S_ERROR=8;
    (* fsm_encoding="none" *) reg [3:0] state;
    reg [1:0] src_bank_q,dst_bank_q;
    reg [ADDR_W-1:0] src_base_q,dst_base_q;
    reg [ADDR_W:0] src_word_index;
    reg [7:0] out_word_index;
    reg [8:0] coeff_index;
    reg [63:0] xof_word;
    reg [3:0] byte_index;
    reg [31:0] bit_buffer;
    reg [5:0] bit_count;
    reg [31:0] low_coeff;
    reg [63:0] write_word;
    reg [7:0] byte_stage;
    reg [17:0] coeff_bits;

    wire [ADDR_W+1:0] src_end = {2'b00,aux_src_addr} + 72;
    wire [ADDR_W+1:0] dst_end = {2'b00,aux_dst_addr} + 128;
    wire descriptor_ok =
        (aux_op==OP_GAMMA1_UNPACK) && (aux_words==12'd72) &&
        (aux_src_bank<BANKS) && (aux_dst_bank<BANKS) &&
        (aux_src_bank!=aux_dst_bank) &&
        (src_end <= (1 << ADDR_W)) && (dst_end <= (1 << ADDR_W));

    // Two's-complement signed output. All 18-bit codes accepted: the
    // Gamma1 distribution requires NO rejection sampling.
    wire [31:0] signed_sample = 32'd131072 - {14'b0,coeff_bits};

    assign aux_ready = (state==S_IDLE) && !abort;
    assign aux_done = (state==S_DONE) && !abort;
    assign aux_error = (state==S_ERROR) && !abort;
    assign aux_reject_set = 1'b0;

    always @* begin
        sp_rd_req_valid={BANKS{1'b0}};
        sp_rd_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_rd_rsp_ready={BANKS{1'b0}};
        sp_wr_req_valid={BANKS{1'b0}};
        sp_wr_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_wr_req_data={(BANKS*64){1'b0}};
        if (!abort) begin
            if (state==S_RD_REQ && src_word_index<72) begin
                sp_rd_req_valid[src_bank_q]=1'b1;
                sp_rd_req_addr[src_bank_q*ADDR_W +: ADDR_W]=src_base_q+src_word_index;
            end
            if (state==S_RD_RSP)
                sp_rd_rsp_ready[src_bank_q]=1'b1;
            if (state==S_WRITE) begin
                sp_wr_req_valid[dst_bank_q]=1'b1;
                sp_wr_req_addr[dst_bank_q*ADDR_W +: ADDR_W]=dst_base_q+out_word_index;
                sp_wr_req_data[dst_bank_q*64 +: 64]=write_word;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE;
            src_bank_q<=0;dst_bank_q<=0;src_base_q<=0;dst_base_q<=0;
            src_word_index<=0;out_word_index<=0;coeff_index<=0;
            xof_word<=0;byte_index<=0;bit_buffer<=0;bit_count<=0;
            low_coeff<=0;write_word<=0;byte_stage<=0;coeff_bits<=0;
        end else if (abort) begin
            state<=S_IDLE;
            bit_buffer<=0;
            bit_count<=0;
        end else begin
            case (state)
                S_IDLE: if (aux_valid && aux_ready) begin
                    if (!descriptor_ok) state<=S_ERROR;
                    else begin
                        src_bank_q<=aux_src_bank;
                        dst_bank_q<=aux_dst_bank;
                        src_base_q<=aux_src_addr;
                        dst_base_q<=aux_dst_addr;
                        src_word_index<=0;
                        out_word_index<=0;
                        coeff_index<=0;
                        byte_index<=4'd8; // force first read
                        bit_buffer<=0;
                        bit_count<=0;
                        state<=S_STEP;
                    end
                end
                S_STEP: begin
                    if (coeff_index==9'd256) begin
                        // Exactly 576 source bytes should have been consumed.
                        if (src_word_index==72 && byte_index==8 && bit_count==0)
                            state<=S_DONE;
                        else state<=S_ERROR;
                    end else if (bit_count>=18) begin
                        coeff_bits<=bit_buffer[17:0];
                        bit_buffer<=bit_buffer>>18;
                        bit_count<=bit_count-6'd18;
                        state<=S_DECODE;
                    end else if (byte_index==8) begin
                        if(src_word_index<72) state<=S_RD_REQ;
                        else state<=S_ERROR;
                    end else begin
                        byte_stage<=xof_word[byte_index*8 +: 8];
                        byte_index<=byte_index+1'b1;
                        state<=S_APPEND;
                    end
                end
                S_RD_REQ: if (sp_rd_req_ready[src_bank_q]) state<=S_RD_RSP;
                S_RD_RSP: if (sp_rd_rsp_valid[src_bank_q]) begin
                    xof_word<=sp_rd_rsp_data[src_bank_q*64 +: 64];
                    src_word_index<=src_word_index+1'b1;
                    byte_index<=0;
                    state<=S_STEP;
                end
                S_APPEND: begin
                    bit_buffer<=bit_buffer | ({24'd0,byte_stage} << bit_count);
                    bit_count<=bit_count+6'd8;
                    state<=S_STEP;
                end
                S_DECODE: begin
                    if (!coeff_index[0]) begin
                        low_coeff<=signed_sample;
                        coeff_index<=coeff_index+1'b1;
                        state<=S_STEP;
                    end else begin
                        write_word<={signed_sample,low_coeff};
                        state<=S_WRITE;
                    end
                end
                S_WRITE: if (sp_wr_req_ready[dst_bank_q]) begin
                    coeff_index<=coeff_index+1'b1;
                    out_word_index<=out_word_index+1'b1;
                    state<=S_STEP;
                end
                S_DONE: state<=S_IDLE;
                S_ERROR: state<=S_IDLE;
                default: state<=S_ERROR;
            endcase
        end
    end
endmodule
