`timescale 1ns/1ps
// WEPWAWET FIPS 204 ExpandS eta=2 bounded sampler.
// OP 0x34: Consume 72x64-bit SHAKE256 XOF words in a scratchpad source bank
// and emit 256 signed 32-bit coefficients in 128x64-bit destination words.
// Each byte is consumed low nibble then high nibble. Nibble 0xF is rejected;
// otherwise output (2 - nibble%5), matching FIPS 204 RejBoundedPoly eta=2.
// Descriptor requires separate source and destination banks and 72 words.
// Exhausted XOF => ERROR, not DONE; abort/error may leave a partial result.
// AXIS SHAKE generation is handled separately by the existing HLS kernel.
module wcore_mldsa44_eta2_aux #(
    parameter integer ADDR_W=11, BANKS=4
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
    localparam [7:0] OP_ETA2=8'h34;
    localparam [2:0] ST_IDLE=0, ST_STEP=1, ST_RD_REQ=2,
        ST_RD_RSP=3, ST_EVAL=4, ST_WR_REQ=5, ST_DONE=6, ST_ERROR=7;
    (* fsm_encoding="none" *) reg [2:0] state;
    reg [1:0] src_bank_q,dst_bank_q;
    reg [ADDR_W-1:0] src_base_q,dst_base_q;
    reg [ADDR_W:0] src_idx;
    reg [3:0] byte_idx;
    reg hi_nibble;
    reg [63:0] input_word, write_word;
    reg [31:0] low_coeff;
    reg [8:0] coeff_count;
    reg [7:0] out_idx;
    wire [ADDR_W+1:0] src_end={2'b00,aux_src_addr}+72;
    wire [ADDR_W+1:0] dst_end={2'b00,aux_dst_addr}+128;
    wire descriptor_ok=(aux_op==OP_ETA2) && (aux_words==12'd72) &&
        (aux_src_bank<BANKS) && (aux_dst_bank<BANKS) &&
        (aux_src_bank!=aux_dst_bank) &&
        (src_end <= (1 << ADDR_W)) && (dst_end <= (1 << ADDR_W));
    wire [63:0] shifted=input_word >> ({byte_idx,3'b000} + (hi_nibble ? 7'd4 : 7'd0));
    wire [3:0] nibble=shifted[3:0];
    reg [31:0] eta_coeff;
    always @* begin
        // Explicit lookup avoids synthesizing a general divide or modulo.
        case(nibble)
            4'd0,4'd5,4'd10: eta_coeff=32'd2;
            4'd1,4'd6,4'd11: eta_coeff=32'd1;
            4'd2,4'd7,4'd12: eta_coeff=32'd0;
            4'd3,4'd8,4'd13: eta_coeff=32'hffffffff;
            4'd4,4'd9,4'd14: eta_coeff=32'hfffffffe;
            default: eta_coeff=32'd0; // nibble 15 is rejected
        endcase
    end
    assign aux_ready=(state==ST_IDLE) && !abort;
    assign aux_done=(state==ST_DONE) && !abort;
    assign aux_error=(state==ST_ERROR) && !abort;
    assign aux_reject_set=1'b0; // not signing rejection

    always @* begin
        sp_rd_req_valid={BANKS{1'b0}};
        sp_rd_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_rd_rsp_ready={BANKS{1'b0}};
        sp_wr_req_valid={BANKS{1'b0}};
        sp_wr_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_wr_req_data={(BANKS*64){1'b0}};
        if (!abort) begin
            if(state==ST_RD_REQ && src_idx<72) begin
                sp_rd_req_valid[src_bank_q]=1'b1;
                sp_rd_req_addr[src_bank_q*ADDR_W +: ADDR_W]=src_base_q+src_idx;
            end
            if(state==ST_RD_RSP) sp_rd_rsp_ready[src_bank_q]=1'b1;
            if(state==ST_WR_REQ) begin
                sp_wr_req_valid[dst_bank_q]=1'b1;
                sp_wr_req_addr[dst_bank_q*ADDR_W +: ADDR_W]=dst_base_q+out_idx;
                sp_wr_req_data[dst_bank_q*64 +: 64]=write_word;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=ST_IDLE;src_bank_q<=0;dst_bank_q<=0;
            src_base_q<=0;dst_base_q<=0;src_idx<=0;
            byte_idx<=0;hi_nibble<=0;input_word<=0;write_word<=0;
            low_coeff<=0;coeff_count<=0;out_idx<=0;
        end else if(abort) begin
            state<=ST_IDLE;coeff_count<=0;input_word<=0;write_word<=0;
        end else begin
            case(state)
                ST_IDLE: if(aux_valid && aux_ready) begin
                    if(!descriptor_ok) state<=ST_ERROR;
                    else begin
                        src_bank_q<=aux_src_bank;dst_bank_q<=aux_dst_bank;
                        src_base_q<=aux_src_addr;dst_base_q<=aux_dst_addr;
                        src_idx<=0;byte_idx<=0;hi_nibble<=0;
                        coeff_count<=0;out_idx<=0;low_coeff<=0;
                        state<=ST_RD_REQ;
                    end
                end
                ST_STEP: begin
                    if(coeff_count==9'd256) state<=ST_DONE;
                    else if(byte_idx==4'd8) state<=ST_RD_REQ;
                    else state<=ST_EVAL;
                end
                ST_RD_REQ: begin
                    if(src_idx>=72) state<=ST_ERROR;
                    else if(sp_rd_req_ready[src_bank_q]) state<=ST_RD_RSP;
                end
                ST_RD_RSP: if(sp_rd_rsp_valid[src_bank_q]) begin
                    input_word<=sp_rd_rsp_data[src_bank_q*64 +: 64];
                    src_idx<=src_idx+1'b1;
                    byte_idx<=0;
                    hi_nibble<=0;
                    state<=ST_EVAL;
                end
                ST_EVAL: begin
                    if(!hi_nibble) hi_nibble<=1;
                    else begin
                        hi_nibble<=0;
                        byte_idx<=byte_idx+1'b1;
                    end
                    if(nibble!=4'hf) begin
                        coeff_count<=coeff_count+1'b1;
                        if(!coeff_count[0]) low_coeff<=eta_coeff;
                        else begin
                            write_word<={eta_coeff,low_coeff};
                            state<=ST_WR_REQ;
                        end
                    end
                    // After two nibbles of last byte, next ST_STEP must
                    // fetch another source word unless all 256 are done.
                    if (nibble==4'hf || !coeff_count[0]) state<=ST_STEP;
                end
                ST_WR_REQ: if(sp_wr_req_ready[dst_bank_q]) begin
                    out_idx<=out_idx+1'b1;
                    state<=ST_STEP;
                end
                ST_DONE: state<=ST_IDLE;
                ST_ERROR: state<=ST_IDLE;
                default: state<=ST_ERROR;
            endcase
        end
    end
endmodule
