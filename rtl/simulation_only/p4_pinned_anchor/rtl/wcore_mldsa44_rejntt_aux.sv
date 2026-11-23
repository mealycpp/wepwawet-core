`timescale 1ns/1ps
// WEPWAWET Stage 11: ExpandA / RejNTT coefficient sampler.
// Consumes SHAKE128 XOF output already present in a scratchpad bank, 8 bytes
// per 64-bit word (least-significant byte is earliest stream byte).
// Produces 256 mod-q NTT-domain coefficients = 128 packed 64-bit words.
// The output order and rejection rule follow FIPS 204 RejNTT:
// candidate = (b0 | (b1<<8) | (b2<<16)) & 23'h7fffff;
// accept if candidate < q (q=8380417).
// NOTE: SHAKE generation, refill/retry, WCORE ROM, and full SIGN/VERIFY are
// external. This unit returns ERROR on insufficient input (never DONE).
// This is an RTL candidate, not a synthesised or routed 300MHz design.
module wcore_mldsa44_rejntt_aux #(
    parameter integer ADDR_W=11,
    parameter integer BANKS=4
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
    localparam [7:0] OP_REJNTT=8'h30;
    localparam [22:0] Q=23'd8380417;
    localparam [2:0]
        S_IDLE=0, S_RD_REQ=1, S_RD_RSP=2,
        S_BYTE=3, S_EVAL=4, S_WR_REQ=5,
        S_DONE=6, S_ERROR=7;
    (* fsm_encoding="none" *) reg [2:0] state;
    reg [1:0] src_bank_q, dst_bank_q;
    reg [ADDR_W-1:0] src_base_q, dst_base_q;
    reg [ADDR_W:0] input_words_q;
    reg [ADDR_W:0] src_word_index;
    reg [2:0] byte_index;
    reg [1:0] triplet_index;
    reg [23:0] triplet;
    reg [63:0] current_word;
    reg [31:0] packed_lo;
    reg [63:0] output_word;
    reg [8:0] coeff_count;
    reg [7:0] output_word_index;

    wire [ADDR_W+1:0] src_end = {2'b0,aux_src_addr} + {1'b0,aux_words};
    wire [ADDR_W+1:0] dst_end = {2'b0,aux_dst_addr} +
                               {{(ADDR_W+1-7){1'b0}},8'd128};
    wire shape_ok = (aux_op==OP_REJNTT) &&
        (aux_src_bank < BANKS) && (aux_dst_bank < BANKS) &&
        (aux_src_bank != aux_dst_bank) &&
        (aux_words >= 12'd96) && // Minimum: 256*3 bytes, without rejection
        (src_end <= (1 << ADDR_W)) &&
        (dst_end <= (1 << ADDR_W));

    assign aux_ready=(state==S_IDLE) && !abort;
    assign aux_done=(state==S_DONE) && !abort;
    assign aux_error=(state==S_ERROR) && !abort;
    assign aux_reject_set=1'b0; // RejNTT filtering is NOT signing rejection.
    wire [22:0] candidate = triplet[22:0];

    always @* begin
        sp_rd_req_valid={BANKS{1'b0}};
        sp_rd_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_rd_rsp_ready={BANKS{1'b0}};
        sp_wr_req_valid={BANKS{1'b0}};
        sp_wr_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_wr_req_data={(BANKS*64){1'b0}};
        if (!abort) begin
            if (state==S_RD_REQ && src_word_index < input_words_q) begin
                sp_rd_req_valid[src_bank_q]=1'b1;
                sp_rd_req_addr[src_bank_q*ADDR_W +: ADDR_W] =
                    src_base_q + src_word_index;
            end
            if (state==S_RD_RSP)
                sp_rd_rsp_ready[src_bank_q]=1'b1;
            if (state==S_WR_REQ) begin
                sp_wr_req_valid[dst_bank_q]=1'b1;
                sp_wr_req_addr[dst_bank_q*ADDR_W +: ADDR_W] =
                    dst_base_q + output_word_index;
                sp_wr_req_data[dst_bank_q*64 +: 64]=output_word;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            src_bank_q<=0; dst_bank_q<=0;
            src_base_q<=0; dst_base_q<=0; input_words_q<=0;
            src_word_index<=0; byte_index<=0; triplet_index<=0;
            triplet<=0; current_word<=0;
            packed_lo<=0; output_word<=0;
            coeff_count<=0; output_word_index<=0;
        end else if (abort) begin
            state<=S_IDLE;
            triplet<=0; current_word<=0; packed_lo<=0; output_word<=0;
            coeff_count<=0;
        end else begin
            case (state)
                S_IDLE: if (aux_valid && aux_ready) begin
                    if (!shape_ok) state<=S_ERROR;
                    else begin
                        src_bank_q<=aux_src_bank;
                        dst_bank_q<=aux_dst_bank;
                        src_base_q<=aux_src_addr;
                        dst_base_q<=aux_dst_addr;
                        input_words_q<=aux_words;
                        src_word_index<=0;
                        byte_index<=0; triplet_index<=0;
                        triplet<=0; coeff_count<=0; output_word_index<=0;
                        state<=S_RD_REQ;
                    end
                end
                S_RD_REQ: begin
                    if (src_word_index>=input_words_q) state<=S_ERROR;
                    else if (sp_rd_req_ready[src_bank_q]) state<=S_RD_RSP;
                end
                S_RD_RSP: if (sp_rd_rsp_valid[src_bank_q]) begin
                    current_word<=sp_rd_rsp_data[src_bank_q*64 +: 64];
                    state<=S_BYTE;
                end
                S_BYTE: begin
                    triplet[triplet_index*8 +: 8] <=
                        current_word[byte_index*8 +: 8];
                    if (byte_index==3'd7) begin
                        byte_index<=0;
                        src_word_index<=src_word_index+1'b1;
                    end else byte_index<=byte_index+1'b1;
                    if (triplet_index==2'd2) begin
                        triplet_index<=0;
                        state<=S_EVAL;
                    end else begin
                        triplet_index<=triplet_index+1'b1;
                        if (byte_index==3'd7) state<=S_RD_REQ;
                    end
                end
                S_EVAL: begin
                    if (candidate<Q) begin
                        coeff_count<=coeff_count+1'b1;
                        if (!coeff_count[0]) begin
                            packed_lo<={9'd0,candidate};
                            if (byte_index==0) state<=S_RD_REQ;
                            else state<=S_BYTE;
                        end else begin
                            output_word<={{9'd0,candidate},packed_lo};
                            state<=S_WR_REQ;
                        end
                    end else begin
                        if (byte_index==0) state<=S_RD_REQ;
                        else state<=S_BYTE;
                    end
                end
                S_WR_REQ: if (sp_wr_req_ready[dst_bank_q]) begin
                    output_word_index<=output_word_index+1'b1;
                    if (coeff_count==9'd256) state<=S_DONE;
                    else if (byte_index==0) state<=S_RD_REQ;
                    else state<=S_BYTE;
                end
                S_DONE: state<=S_IDLE;
                S_ERROR: state<=S_IDLE;
                default: state<=S_ERROR;
            endcase
        end
    end
endmodule
