`timescale 1ns/1ps
// WEPWAWET ExpandA seed/index composer -- SYNTHESIS CANDIDATE, not yet XSim-verified.
// Copies public rho[0:31] from four 64-bit scratchpad words at source base
// to output scratchpad words [0:3]; writes [col,row] as bytes 32,33 in
// output word 4 (low 16 bits). Output is exactly 34 bytes for SHAKE128.
// One operation for each (row,col): aux_words = row*4+col+1 in [1,16].
// Scratchpad word order is little-endian stream order.
// This is a public-seed transformation, not a CSPRNG or full ExpandA.
// To feed SHAKE128, AXI-stream last TKEEP/TSTRB MUST be 8'h03.
module wcore_mldsa44_expanda_input_aux #(
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
    localparam [7:0] OP_EXPANDA_INPUT=8'h35;
    localparam [2:0] ST_IDLE=0, ST_READ_REQ=1, ST_READ_RSP=2,
                     ST_WRITE=3, ST_TAIL=4, ST_DONE=5, ST_ERROR=6;
    (* fsm_encoding="none" *) reg [2:0] state;
    reg [1:0] src_bank_q,dst_bank_q;
    reg [ADDR_W-1:0] src_addr_q,dst_addr_q;
    reg [3:0] index_q;
    reg [2:0] word_q;
    reg [63:0] data_q;
    wire [ADDR_W+1:0] src_end={2'b00,aux_src_addr}+13'd4;
    wire [ADDR_W+1:0] dst_end={2'b00,aux_dst_addr}+13'd5;
    wire valid_descriptor = aux_op==OP_EXPANDA_INPUT &&
        aux_src_bank<BANKS && aux_dst_bank<BANKS &&
        aux_src_bank==aux_dst_bank &&
        (aux_words >= 12'd1 && aux_words <= 12'd16) &&
        (src_end <= (1<<ADDR_W)) &&
        (dst_end <= (1<<ADDR_W)) &&
        // Disallow overlapping input and output regions.
        ((dst_end <= {2'b00,aux_src_addr}) ||
         (src_end <= {2'b00,aux_dst_addr}));
    assign aux_ready=(state==ST_IDLE) && !abort;
    assign aux_done=(state==ST_DONE) && !abort;
    assign aux_error=(state==ST_ERROR) && !abort;
    assign aux_reject_set=1'b0;
    wire [7:0] col={6'b0,index_q[1:0]};
    wire [7:0] row={6'b0,index_q[3:2]};

    always @* begin
        sp_rd_req_valid={BANKS{1'b0}};
        sp_rd_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_rd_rsp_ready={BANKS{1'b0}};
        sp_wr_req_valid={BANKS{1'b0}};
        sp_wr_req_addr={(BANKS*ADDR_W){1'b0}};
        sp_wr_req_data={(BANKS*64){1'b0}};
        if (!abort) begin
            if(state==ST_READ_REQ)begin
                sp_rd_req_valid[src_bank_q]=1'b1;
                sp_rd_req_addr[src_bank_q*ADDR_W+:ADDR_W]=src_addr_q+word_q;
            end
            if(state==ST_READ_RSP)sp_rd_rsp_ready[src_bank_q]=1'b1;
            if(state==ST_WRITE || state==ST_TAIL)begin
                sp_wr_req_valid[dst_bank_q]=1'b1;
                sp_wr_req_addr[dst_bank_q*ADDR_W+:ADDR_W]=dst_addr_q+word_q;
                sp_wr_req_data[dst_bank_q*64+:64]=
                    (state==ST_TAIL) ? {48'd0,row,col} : data_q;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)begin
            state<=ST_IDLE;
            src_bank_q<=0;dst_bank_q<=0;src_addr_q<=0;dst_addr_q<=0;
            index_q<=0;word_q<=0;data_q<=0;
        end else if(abort) begin
            state<=ST_IDLE;word_q<=0;data_q<=0;
        end else case(state)
            ST_IDLE: if(aux_valid && aux_ready)begin
                if(!valid_descriptor)state<=ST_ERROR;
                else begin
                    src_bank_q<=aux_src_bank;dst_bank_q<=aux_dst_bank;
                    src_addr_q<=aux_src_addr;dst_addr_q<=aux_dst_addr;
                    index_q<=aux_words[3:0]-1'b1;word_q<=0;
                    state<=ST_READ_REQ;
                end
            end
            ST_READ_REQ: if(sp_rd_req_ready[src_bank_q])state<=ST_READ_RSP;
            ST_READ_RSP: if(sp_rd_rsp_valid[src_bank_q])begin
                data_q<=sp_rd_rsp_data[src_bank_q*64+:64];
                state<=ST_WRITE;
            end
            ST_WRITE: if(sp_wr_req_ready[dst_bank_q])begin
                if(word_q==3'd3)begin word_q<=3'd4;state<=ST_TAIL;end
                else begin word_q<=word_q+1'b1;state<=ST_READ_REQ;end
            end
            ST_TAIL: if(sp_wr_req_ready[dst_bank_q])state<=ST_DONE;
            ST_DONE: state<=ST_IDLE;
            ST_ERROR: state<=ST_IDLE;
            default: state<=ST_ERROR;
        endcase
    end
endmodule
