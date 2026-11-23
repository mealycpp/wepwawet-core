`timescale 1ns/1ps
// Stage 18 exclusive-owner auxiliary dispatcher. Five scratchpad-backed
// modules; the parent system MUST arbitrate scratchpad against DMA/AXIS/CPU.
// Coeff <= Stage10, 0x30 RejNTT, 0x31 SampleInBall,
// 0x32 Gamma1_unpack, 0x33 four-term NTT-domain dot product.
module wcore_mldsa_aux_dispatch #(
    parameter integer ADDR_W=11, BANKS=4
)(
    input wire clk, rst_n, abort,
    input wire aux_valid, output wire aux_ready,
    input wire [7:0] aux_op,
    input wire [1:0] aux_src_bank, aux_dst_bank,
    input wire [ADDR_W-1:0] aux_src_addr, aux_dst_addr,
    input wire [ADDR_W:0] aux_words,
    output wire aux_done, aux_error, aux_reject_set,
    output wire [BANKS-1:0] sp_rd_req_valid,
    input wire [BANKS-1:0] sp_rd_req_ready,
    output wire [BANKS*ADDR_W-1:0] sp_rd_req_addr,
    input wire [BANKS-1:0] sp_rd_rsp_valid,
    output wire [BANKS-1:0] sp_rd_rsp_ready,
    input wire [BANKS*64-1:0] sp_rd_rsp_data,
    output wire [BANKS-1:0] sp_wr_req_valid,
    input wire [BANKS-1:0] sp_wr_req_ready,
    output wire [BANKS*ADDR_W-1:0] sp_wr_req_addr,
    output wire [BANKS*64-1:0] sp_wr_req_data
);
    localparam [3:0] UNIT_COEFF=0, UNIT_REJNTT=1, UNIT_BALL=2, UNIT_MASK=3, UNIT_DOT4=4, UNIT_ETA2=5, UNIT_EXPANDA=6, UNIT_W1=7, UNIT_CHALLENGE_MSG=8;
    reg active;
    reg [3:0] current_unit;
    wire [3:0] requested_unit = aux_op==8'h37 ? UNIT_CHALLENGE_MSG :
                                aux_op==8'h36 ? UNIT_W1 :
                                (aux_op==8'h33 || aux_op==8'h38 || aux_op==8'h39 || aux_op==8'h3A) ? UNIT_DOT4 :
                                aux_op==8'h34 ? UNIT_ETA2 :
                                aux_op==8'h35 ? UNIT_EXPANDA :
                                aux_op==8'h30 ? UNIT_REJNTT :
                                aux_op==8'h31 ? UNIT_BALL :
                                aux_op==8'h32 ? UNIT_MASK : UNIT_COEFF;
    wire [8:0] ready_i,done_i,error_i,reject_i;
    wire [BANKS-1:0] rd_valid_i[0:8],rd_ready_i[0:8],wr_valid_i[0:8];
    wire [BANKS*ADDR_W-1:0] rd_addr_i[0:8],wr_addr_i[0:8];
    wire [BANKS*64-1:0] wr_data_i[0:8];
    wire [8:0] start_i;
    // V4_ONEHOT_DISPATCH
    wire [8:0] unit_sel;
    wire [BANKS-1:0] rd_grant_i [0:8];
    wire [BANKS-1:0] wr_grant_i [0:8];
    wire [BANKS-1:0] rsp_valid_i [0:8];

    genvar g;
    generate
        for (g=0; g<9; g=g+1) begin : GEN_UNIT_SELECT
            assign unit_sel[g] = active && (current_unit == g);
            assign rd_grant_i[g] =
                sp_rd_req_ready & {BANKS{unit_sel[g]}};
            assign wr_grant_i[g] =
                sp_wr_req_ready & {BANKS{unit_sel[g]}};
            assign rsp_valid_i[g] =
                sp_rd_rsp_valid & {BANKS{unit_sel[g]}};
        end
    endgenerate

    reg [BANKS-1:0] mux_rd_valid;
    reg [BANKS-1:0] mux_rd_rsp_ready;
    reg [BANKS-1:0] mux_wr_valid;
    reg [BANKS*ADDR_W-1:0] mux_rd_addr;
    reg [BANKS*ADDR_W-1:0] mux_wr_addr;
    reg [BANKS*64-1:0] mux_wr_data;

    integer k;
    always @* begin
        mux_rd_valid = {BANKS{1'b0}};
        mux_rd_rsp_ready = {BANKS{1'b0}};
        mux_wr_valid = {BANKS{1'b0}};
        mux_rd_addr = {(BANKS*ADDR_W){1'b0}};
        mux_wr_addr = {(BANKS*ADDR_W){1'b0}};
        mux_wr_data = {(BANKS*64){1'b0}};

        for (k=0; k<9; k=k+1) begin
            mux_rd_valid = mux_rd_valid |
                (rd_valid_i[k] & {BANKS{unit_sel[k]}});
            mux_rd_rsp_ready = mux_rd_rsp_ready |
                (rd_ready_i[k] & {BANKS{unit_sel[k]}});
            mux_wr_valid = mux_wr_valid |
                (wr_valid_i[k] & {BANKS{unit_sel[k]}});
            mux_rd_addr = mux_rd_addr |
                (rd_addr_i[k] & {(BANKS*ADDR_W){unit_sel[k]}});
            mux_wr_addr = mux_wr_addr |
                (wr_addr_i[k] & {(BANKS*ADDR_W){unit_sel[k]}});
            mux_wr_data = mux_wr_data |
                (wr_data_i[k] & {(BANKS*64){unit_sel[k]}});
        end
    end
    assign aux_ready = !active && !abort && ready_i[requested_unit];
    assign start_i[0] = aux_valid && aux_ready && requested_unit==UNIT_COEFF;
    assign start_i[1] = aux_valid && aux_ready && requested_unit==UNIT_REJNTT;
    assign start_i[2] = aux_valid && aux_ready && requested_unit==UNIT_BALL;
    assign start_i[3] = aux_valid && aux_ready && requested_unit==UNIT_MASK;
    assign start_i[4] = aux_valid && aux_ready && requested_unit==UNIT_DOT4;
    assign start_i[5] = aux_valid && aux_ready && requested_unit==UNIT_ETA2;
    assign start_i[6] = aux_valid && aux_ready && requested_unit==UNIT_EXPANDA;
    assign start_i[7] = aux_valid && aux_ready && requested_unit==UNIT_W1;
    assign start_i[8] = aux_valid && aux_ready && requested_unit==UNIT_CHALLENGE_MSG;
    assign aux_done = active && done_i[current_unit];
    assign aux_error = active && error_i[current_unit];
    assign aux_reject_set = active && reject_i[current_unit];
    assign sp_rd_req_valid = mux_rd_valid;
    assign sp_rd_req_addr = mux_rd_addr;
    assign sp_rd_rsp_ready = mux_rd_rsp_ready;
    assign sp_wr_req_valid = mux_wr_valid;
    assign sp_wr_req_addr = mux_wr_addr;
    assign sp_wr_req_data = mux_wr_data;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin active<=0;current_unit<=UNIT_COEFF;end
        else if(abort) begin active<=0;current_unit<=UNIT_COEFF;end
        else if(!active && aux_valid && aux_ready) begin
            active<=1;current_unit<=requested_unit;
        end else if(active && (aux_done || aux_error)) active<=0;
    end

    wcore_mldsa44_coeff_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_coeff (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[0]),.aux_ready(ready_i[0]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[0]),.aux_error(error_i[0]),
        .aux_reject_set(reject_i[0]),
        .sp_rd_req_valid(rd_valid_i[0]),.sp_rd_req_ready(rd_grant_i[0]),
        .sp_rd_req_addr(rd_addr_i[0]),
        .sp_rd_rsp_valid(rsp_valid_i[0]),.sp_rd_rsp_ready(rd_ready_i[0]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[0]),.sp_wr_req_ready(wr_grant_i[0]),
        .sp_wr_req_addr(wr_addr_i[0]),.sp_wr_req_data(wr_data_i[0])
    );
    wcore_mldsa44_rejntt_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_rejntt (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[1]),.aux_ready(ready_i[1]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[1]),.aux_error(error_i[1]),
        .aux_reject_set(reject_i[1]),
        .sp_rd_req_valid(rd_valid_i[1]),.sp_rd_req_ready(rd_grant_i[1]),
        .sp_rd_req_addr(rd_addr_i[1]),
        .sp_rd_rsp_valid(rsp_valid_i[1]),.sp_rd_rsp_ready(rd_ready_i[1]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[1]),.sp_wr_req_ready(wr_grant_i[1]),
        .sp_wr_req_addr(wr_addr_i[1]),.sp_wr_req_data(wr_data_i[1])
    );
    wcore_mldsa44_sampleinball_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_ball (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[2]),.aux_ready(ready_i[2]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[2]),.aux_error(error_i[2]),
        .aux_reject_set(reject_i[2]),
        .sp_rd_req_valid(rd_valid_i[2]),.sp_rd_req_ready(rd_grant_i[2]),
        .sp_rd_req_addr(rd_addr_i[2]),
        .sp_rd_rsp_valid(rsp_valid_i[2]),.sp_rd_rsp_ready(rd_ready_i[2]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[2]),.sp_wr_req_ready(wr_grant_i[2]),
        .sp_wr_req_addr(wr_addr_i[2]),.sp_wr_req_data(wr_data_i[2])
    );
    wcore_mldsa44_gamma1_unpack_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_mask (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[3]),.aux_ready(ready_i[3]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[3]),.aux_error(error_i[3]),
        .aux_reject_set(reject_i[3]),
        .sp_rd_req_valid(rd_valid_i[3]),.sp_rd_req_ready(rd_grant_i[3]),
        .sp_rd_req_addr(rd_addr_i[3]),
        .sp_rd_rsp_valid(rsp_valid_i[3]),.sp_rd_rsp_ready(rd_ready_i[3]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[3]),.sp_wr_req_ready(wr_grant_i[3]),
        .sp_wr_req_addr(wr_addr_i[3]),.sp_wr_req_data(wr_data_i[3])
    );
    wcore_mldsa44_dot4_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_dot4 (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[4]),.aux_ready(ready_i[4]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[4]),.aux_error(error_i[4]),
        .aux_reject_set(reject_i[4]),
        .sp_rd_req_valid(rd_valid_i[4]),.sp_rd_req_ready(rd_grant_i[4]),
        .sp_rd_req_addr(rd_addr_i[4]),
        .sp_rd_rsp_valid(rsp_valid_i[4]),.sp_rd_rsp_ready(rd_ready_i[4]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[4]),.sp_wr_req_ready(wr_grant_i[4]),
        .sp_wr_req_addr(wr_addr_i[4]),.sp_wr_req_data(wr_data_i[4])
    );
    wcore_mldsa44_eta2_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_eta2 (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[5]),.aux_ready(ready_i[5]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[5]),.aux_error(error_i[5]),
        .aux_reject_set(reject_i[5]),
        .sp_rd_req_valid(rd_valid_i[5]),.sp_rd_req_ready(rd_grant_i[5]),
        .sp_rd_req_addr(rd_addr_i[5]),
        .sp_rd_rsp_valid(rsp_valid_i[5]),.sp_rd_rsp_ready(rd_ready_i[5]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[5]),.sp_wr_req_ready(wr_grant_i[5]),
        .sp_wr_req_addr(wr_addr_i[5]),.sp_wr_req_data(wr_data_i[5])
    );
    wcore_mldsa44_expanda_input_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_expanda_input (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[6]),.aux_ready(ready_i[6]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[6]),.aux_error(error_i[6]),
        .aux_reject_set(reject_i[6]),
        .sp_rd_req_valid(rd_valid_i[6]),.sp_rd_req_ready(rd_grant_i[6]),
        .sp_rd_req_addr(rd_addr_i[6]),
        .sp_rd_rsp_valid(rsp_valid_i[6]),.sp_rd_rsp_ready(rd_ready_i[6]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[6]),.sp_wr_req_ready(wr_grant_i[6]),
        .sp_wr_req_addr(wr_addr_i[6]),.sp_wr_req_data(wr_data_i[6])
    );
    wcore_mldsa44_w1encode_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_w1encode (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[7]),.aux_ready(ready_i[7]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[7]),.aux_error(error_i[7]),
        .aux_reject_set(reject_i[7]),
        .sp_rd_req_valid(rd_valid_i[7]),.sp_rd_req_ready(rd_grant_i[7]),
        .sp_rd_req_addr(rd_addr_i[7]),
        .sp_rd_rsp_valid(rsp_valid_i[7]),.sp_rd_rsp_ready(rd_ready_i[7]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[7]),.sp_wr_req_ready(wr_grant_i[7]),
        .sp_wr_req_addr(wr_addr_i[7]),.sp_wr_req_data(wr_data_i[7])
    );

    wcore_mldsa44_challenge_msg_aux #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_challenge_msg (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .aux_valid(start_i[8]),.aux_ready(ready_i[8]),.aux_op(aux_op),
        .aux_src_bank(aux_src_bank),.aux_dst_bank(aux_dst_bank),
        .aux_src_addr(aux_src_addr),.aux_dst_addr(aux_dst_addr),
        .aux_words(aux_words),.aux_done(done_i[8]),.aux_error(error_i[8]),
        .aux_reject_set(reject_i[8]),
        .sp_rd_req_valid(rd_valid_i[8]),.sp_rd_req_ready(rd_grant_i[8]),
        .sp_rd_req_addr(rd_addr_i[8]),
        .sp_rd_rsp_valid(rsp_valid_i[8]),.sp_rd_rsp_ready(rd_ready_i[8]),
        .sp_rd_rsp_data(sp_rd_rsp_data),
        .sp_wr_req_valid(wr_valid_i[8]),.sp_wr_req_ready(wr_grant_i[8]),
        .sp_wr_req_addr(wr_addr_i[8]),.sp_wr_req_data(wr_data_i[8])
    );
endmodule
