`timescale 1ns/1ps
// Stage challenge message builder. AUX op 0x37.
// One scratchpad job constructs mu[64] || w1Encode(w1)[768] = 832 bytes.
// Memory ABI: mu is in the destination bank starting at aux_src_addr,
// w1 is in aux_src_bank starting at aux_src_addr, and concatenation is
// written to aux_dst_bank starting at aux_dst_addr.
// aux_words=96 describes the 96-word w1 input, NOT output count (104).
// Fail closed on invalid descriptor; outputs must be discarded on abort.
// This is not a key decoder or message hasher; mu is a test input here.
module wcore_mldsa44_challenge_msg_aux #(
    parameter integer ADDR_W=11, BANKS=4
)(
    input wire clk,rst_n,abort,
    input wire aux_valid,output wire aux_ready,
    input wire [7:0] aux_op,
    input wire [1:0] aux_src_bank,aux_dst_bank,
    input wire [ADDR_W-1:0] aux_src_addr,aux_dst_addr,
    input wire [ADDR_W:0] aux_words,
    output wire aux_done,aux_error,aux_reject_set,
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
    localparam [2:0] S_IDLE=0,S_READ=1,S_RESPONSE=2,S_WRITE=3,S_DONE=4,S_ERROR=5;
    (* fsm_encoding="none" *) reg [2:0] state;
    reg [1:0] src_bank_q,dst_bank_q;
    reg [ADDR_W-1:0] src_addr_q,dst_addr_q;
    reg [6:0] index_q;
    reg [63:0] word_q;
    wire [ADDR_W+1:0] src_end={2'b00,aux_src_addr}+13'd96;
    wire [ADDR_W+1:0] mu_end={2'b00,aux_src_addr}+13'd8;
    wire [ADDR_W+1:0] dst_end={2'b00,aux_dst_addr}+13'd104;
    wire valid_desc=(aux_op==8'h37)&&(aux_words==12'd96)&&
        (aux_src_bank<BANKS)&&(aux_dst_bank<BANKS)&&
        (aux_src_bank!=aux_dst_bank)&&(src_end<=2048)&&
        (mu_end<=2048)&&(dst_end<=2048)&&
        ({2'b00,aux_dst_addr}>=mu_end);
    wire [1:0] read_bank=(index_q<7'd8)?dst_bank_q:src_bank_q;
    wire [ADDR_W-1:0] read_addr=src_addr_q+((index_q<7'd8)?
                                          {{(ADDR_W-7){1'b0}},index_q}:
                                          {{(ADDR_W-7){1'b0}},index_q-7'd8});
    assign aux_ready=(state==S_IDLE)&&!abort;
    assign aux_done=(state==S_DONE)&&!abort;
    assign aux_error=(state==S_ERROR)&&!abort;
    assign aux_reject_set=1'b0;
    always @* begin
        sp_rd_req_valid={BANKS{1'b0}};
        sp_rd_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_rd_rsp_ready={BANKS{1'b0}};
        sp_wr_req_valid={BANKS{1'b0}};
        sp_wr_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_wr_req_data={(BANKS*64){1'b0}};
        if (!abort) begin
            if(state==S_READ) begin
                sp_rd_req_valid[read_bank]=1'b1;
                sp_rd_req_addr[read_bank*ADDR_W+:ADDR_W]=read_addr;
            end
            if(state==S_RESPONSE)sp_rd_rsp_ready[read_bank]=1'b1;
            if(state==S_WRITE) begin
                sp_wr_req_valid[dst_bank_q]=1'b1;
                sp_wr_req_addr[dst_bank_q*ADDR_W+:ADDR_W]=dst_addr_q+index_q;
                sp_wr_req_data[dst_bank_q*64+:64]=word_q;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=S_IDLE;src_bank_q<=0;dst_bank_q<=0;
            src_addr_q<=0;dst_addr_q<=0;index_q<=0;word_q<=0;
        end else if(abort)begin
            state<=S_IDLE;word_q<=0;
        end else begin
            case(state)
                S_IDLE:if(aux_valid && aux_ready)begin
                    if(!valid_desc)state<=S_ERROR;
                    else begin
                        src_bank_q<=aux_src_bank;dst_bank_q<=aux_dst_bank;
                        src_addr_q<=aux_src_addr;dst_addr_q<=aux_dst_addr;
                        index_q<=0;state<=S_READ;
                    end
                end
                S_READ:if(sp_rd_req_ready[read_bank])state<=S_RESPONSE;
                S_RESPONSE:if(sp_rd_rsp_valid[read_bank])begin
                    word_q<=sp_rd_rsp_data[read_bank*64+:64];state<=S_WRITE;
                end
                S_WRITE:if(sp_wr_req_ready[dst_bank_q])begin
                    if(index_q==7'd103)state<=S_DONE;
                    else begin index_q<=index_q+1'b1;state<=S_READ;end
                end
                S_DONE:state<=S_IDLE;
                S_ERROR:state<=S_IDLE;
                default:state<=S_ERROR;
            endcase
        end
    end
endmodule
