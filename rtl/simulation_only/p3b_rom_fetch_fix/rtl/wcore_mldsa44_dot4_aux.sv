`timescale 1ns/1ps
// Stage20 candidate: reuse the REAL HLS polymulacc_top for four serial
// 256-coefficient Montgomery products; accumulate the four results in RTL.
// Drop-in replacement for Stage18/19 AUX op 0x33, same four-bank ABI.
// A[term] in scratchpad bank0 at src_addr+128*term, B[term] in bank1.
// Output canonical mod-q 256-coefficient polynomial to bank2[dst_addr..+127].
// Single instantiated multiplier core (NOT the earlier RTL DOT4 multipliers).
// AXI-Lite is real via wcore_axil_master. In this test harness, all inputs
// are preloaded into scratchpad, B0 is supplied by real HLS NTT.
// This remains a candidate until XSim and post-route timing are measured.
module wcore_mldsa44_dot4_aux #(
    parameter integer ADDR_W=11,
    parameter integer BANKS=4
)(
    input wire clk, rst_n, abort,
    input wire aux_valid, output wire aux_ready,
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
    localparam signed [63:0] Q=64'sd8380417;
    localparam [4:0]
        IDLE=0, CLEAR=1, AX_START=2, AX_START_WAIT=3,
        A_REQ=4, A_WAIT=5, A_TX=6, B_REQ=7, B_WAIT=8, B_TX=9,
        RX=10, ACC=11, ACC_COMMIT=12, AX_IDLE=13,
        AX_IDLE_WAIT=14, NEXT_TERM=15, WRITE=16, DONE=17, ERR=18;
    (* fsm_encoding="none" *) reg [4:0] state;
    reg [ADDR_W-1:0] abase,cbase;
    reg cs1_mode;
    reg [1:0] b_bank_q;
    reg [ADDR_W-1:0] b_base_q;
    reg [1:0] term;
    reg [6:0] tx_index,rx_index,save_index,clear_index;
    reg [63:0] tx_word,rx_word;
    // V5: signed(0..2^32-1) + signed 32-bit input fits exactly in 34 bits.
    reg signed [33:0] sum0_q,sum1_q;
    (* ram_style = "distributed" *) reg [31:0] acc0[0:127];
    (* ram_style = "distributed" *) reg [31:0] acc1[0:127];
    reg [15:0] watchdog;
    wire [ADDR_W+1:0] src_end={2'b00,aux_src_addr}+13'd512;
    wire [ADDR_W+1:0] dst_end={2'b00,aux_dst_addr}+13'd128;
    wire [ADDR_W+1:0] cs1_dst_end={2'b00,aux_dst_addr}+13'd512;
    wire valid_descriptor=aux_words==12'd128 && aux_dst_bank==2'd2 &&
        ((aux_op==8'h33 && aux_src_bank==2'd0 &&
          src_end <= (1 << ADDR_W) && dst_end <= (1 << ADDR_W)) ||
         ((aux_op==8'h38 || aux_op==8'h39 || aux_op==8'h3A || aux_op==8'h3B) && aux_src_bank==2'd1 &&
          ({2'b00,aux_src_addr}+13'd128 <= (1 << ADDR_W)) &&
          cs1_dst_end <= (1 << ADDR_W)));
    wire [ADDR_W-1:0] read_addr=abase+({{(ADDR_W-2){1'b0}},term}<<7)+tx_index;
    // Four matrix rows reuse the SAME B vector. Row offset applies only to A.
    wire [ADDR_W-1:0] b_read_addr=(cs1_mode ? b_base_q : {ADDR_W{1'b0}}) +
        ({{(ADDR_W-2){1'b0}},term}<<7)+tx_index;
    wire [ADDR_W-1:0] a_read_addr=cs1_mode ? (abase+tx_index):read_addr;
    wire signed [33:0] sm0 =
        $signed({2'b00,(cs1_mode ? 32'd0 : acc0[rx_index])}) +
        $signed({{2{rx_word[31]}},rx_word[31:0]});
    wire signed [33:0] sm1 =
        $signed({2'b00,(cs1_mode ? 32'd0 : acc1[rx_index])}) +
        $signed({{2{rx_word[63]}},rx_word[63:32]});
    function automatic [31:0] canonical(input signed [63:0] x);
        reg signed [63:0] y;
        begin
            y=(x<0)?(x+Q):((x>=Q)?(x-Q):x);
            canonical=y[31:0];
        end
    endfunction
    // V5: exactly one synchronous write port per accumulator RAM.
    // CLEAR writes all 128 words before any read in the next invocation.
    // No array reset is needed: reset/abort return the FSM to IDLE and
    // a new request always executes CLEAR first.
    wire acc_commit_ok = (sum0_q < 2*Q) && (sum0_q >= -Q) &&
                         (sum1_q < 2*Q) && (sum1_q >= -Q);
    wire acc_mem_we = rst_n && !abort &&
                      ((state == CLEAR) ||
                       ((state == ACC_COMMIT) && acc_commit_ok));
    wire [6:0] acc_mem_addr = (state == CLEAR) ? clear_index : rx_index;
    wire [31:0] acc_mem_data0 = (state == CLEAR) ?
        32'd0 : canonical($signed(sum0_q));
    wire [31:0] acc_mem_data1 = (state == CLEAR) ?
        32'd0 : canonical($signed(sum1_q));
    always @(posedge clk) begin
        if (acc_mem_we) begin
            acc0[acc_mem_addr] <= acc_mem_data0;
            acc1[acc_mem_addr] <= acc_mem_data1;
        end
    end
    assign aux_ready=(state==IDLE) && !abort;
    assign aux_done=(state==DONE) && !abort;
    assign aux_error=(state==ERR) && !abort;
    assign aux_reject_set=1'b0;

    // Internal, direct-to-original-HLS-core AXIS signals.
    wire [63:0] poly_in_tdata=tx_word;
    wire poly_in_tvalid=(state==A_TX || state==B_TX) && !abort;
    wire poly_in_tready;
    wire [7:0] poly_in_tkeep=8'hff,poly_in_tstrb=8'hff;
    wire poly_in_tlast=(state==B_TX && tx_index==7'd127);
    wire [63:0] poly_out_tdata;
    wire poly_out_tvalid,poly_out_tready,poly_out_tlast;
    wire [7:0] poly_out_tkeep,poly_out_tstrb;
    assign poly_out_tready=(state==RX) && !abort;

    wire ax_req_ready,ax_rsp_valid,ax_rsp_error,ax_poisoned;
    wire [31:0] ax_rsp_rdata;
    wire [3:0] awaddr,araddr,wstrb;
    wire awvalid,awready,wvalid,wready,bvalid,bready;
    wire arvalid,arready,rvalid,rready;
    wire [31:0] wdata,rdata;
    wire [1:0] bresp,rresp;
    wire ax_req_valid=(state==AX_START || state==AX_IDLE) && !abort;
    wire ax_req_write=(state==AX_START);
    wire [3:0] ax_req_addr=4'h0;
    wire [31:0] ax_req_wdata=(state==AX_START)?32'd1:32'd0;
    wire ax_rsp_ready=(state==AX_START_WAIT || state==AX_IDLE_WAIT);
    wcore_axil_master #(.ADDR_W(4),.TIMEOUT(2048)) u_poly_axil (
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .req_valid(ax_req_valid),.req_ready(ax_req_ready),
        .req_write(ax_req_write),.req_addr(ax_req_addr),
        .req_wdata(ax_req_wdata),.req_wstrb(4'hf),
        .rsp_valid(ax_rsp_valid),.rsp_ready(ax_rsp_ready),
        .rsp_error(ax_rsp_error),.rsp_rdata(ax_rsp_rdata),
        .poisoned(ax_poisoned),
        .m_axi_awaddr(awaddr),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready)
    );
    wire unused_poly_irq;
    polymulacc_top u_real_polymulacc (
        .ap_clk(clk),.ap_rst_n(rst_n && !abort),
        .in_r_TDATA(poly_in_tdata),.in_r_TVALID(poly_in_tvalid),
        .in_r_TREADY(poly_in_tready),.in_r_TKEEP(poly_in_tkeep),
        .in_r_TSTRB(poly_in_tstrb),.in_r_TLAST(poly_in_tlast),
        .out_r_TDATA(poly_out_tdata),.out_r_TVALID(poly_out_tvalid),
        .out_r_TREADY(poly_out_tready),.out_r_TKEEP(poly_out_tkeep),
        .out_r_TSTRB(poly_out_tstrb),.out_r_TLAST(poly_out_tlast),
        .s_axi_control_AWVALID(awvalid),.s_axi_control_AWREADY(awready),
        .s_axi_control_AWADDR(awaddr),
        .s_axi_control_WVALID(wvalid),.s_axi_control_WREADY(wready),
        .s_axi_control_WDATA(wdata),.s_axi_control_WSTRB(wstrb),
        .s_axi_control_ARVALID(arvalid),.s_axi_control_ARREADY(arready),
        .s_axi_control_ARADDR(araddr),
        .s_axi_control_RVALID(rvalid),.s_axi_control_RREADY(rready),
        .s_axi_control_RDATA(rdata),.s_axi_control_RRESP(rresp),
        .s_axi_control_BVALID(bvalid),.s_axi_control_BREADY(bready),
        .s_axi_control_BRESP(bresp),.interrupt(unused_poly_irq)
    );
    always @* begin
        sp_rd_req_valid=0;sp_rd_req_addr=0;sp_rd_rsp_ready=0;
        sp_wr_req_valid=0;sp_wr_req_addr=0;sp_wr_req_data=0;
        if(!abort) begin
            if(state==A_REQ)begin
                sp_rd_req_valid[cs1_mode?1:0]=1'b1;
                sp_rd_req_addr[(cs1_mode?1:0)*ADDR_W+:ADDR_W]=a_read_addr;
            end
            if(state==B_REQ)begin
                sp_rd_req_valid[b_bank_q]=1'b1;
                sp_rd_req_addr[b_bank_q*ADDR_W+:ADDR_W]=b_read_addr;
            end
            if(state==A_WAIT)sp_rd_rsp_ready[cs1_mode?1:0]=1'b1;
            if(state==B_WAIT)sp_rd_rsp_ready[b_bank_q]=1'b1;
            if(state==WRITE)begin
                sp_wr_req_valid[2]=1'b1;
                sp_wr_req_addr[2*ADDR_W+:ADDR_W]=cbase+save_index+
                    (cs1_mode ? ({{(ADDR_W-2){1'b0}},term}<<7) : {ADDR_W{1'b0}});
                sp_wr_req_data[2*64+:64]={acc1[save_index],acc0[save_index]};
            end
        end
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;abase<=0;cbase<=0;term<=0;cs1_mode<=0;b_bank_q<=0;b_base_q<=0;
            tx_index<=0;rx_index<=0;save_index<=0;clear_index<=0;
            tx_word<=0;rx_word<=0;sum0_q<=0;sum1_q<=0;watchdog<=0;
        end else if(abort)begin
            state<=IDLE;watchdog<=0;
        end else begin
            if(state!=IDLE && state!=DONE && state!=ERR)begin
                if(watchdog==16'hffff)state<=ERR;
                else watchdog<=watchdog+1'b1;
            end else watchdog<=0;
            case(state)
                IDLE:if(aux_valid)begin
                    if(!valid_descriptor)state<=ERR;
                    else begin
                        abase<=aux_src_addr;cbase<=aux_dst_addr;
                        cs1_mode<=(aux_op==8'h38 || aux_op==8'h39 || aux_op==8'h3A || aux_op==8'h3B);
                        // seal_v8: 0x3B = c_hat * t1'_hat from bank3[1536..2047] (VERIFY), keeps bank2[1536..] = sealed t0_hat
                        b_bank_q<=(aux_op==8'h3B) ? 2'd3 : (aux_op==8'h3A) ? 2'd2 : 2'd1;
                        b_base_q<=(aux_op==8'h38) ? 11'd512 : 11'd1536;
                        term<=0;tx_index<=0;rx_index<=0;
                        save_index<=0;clear_index<=0;
                        watchdog<=0;state<=CLEAR;
                    end
                end
                CLEAR:begin
                    if(clear_index==7'd127)state<=AX_START;
                    else clear_index<=clear_index+1'b1;
                end
                AX_START:if(ax_poisoned)state<=ERR;
                         else if(ax_req_ready)state<=AX_START_WAIT;
                AX_START_WAIT:if(ax_rsp_valid)begin
                    if(ax_rsp_error)state<=ERR;
                    else begin tx_index<=0;state<=A_REQ;end
                end
                A_REQ:if(sp_rd_req_ready[cs1_mode?1:0])state<=A_WAIT;
                A_WAIT:if(sp_rd_rsp_valid[cs1_mode ? 1 : 0])begin
                    tx_word<=sp_rd_rsp_data[(cs1_mode?1:0)*64+:64];state<=A_TX;
                end
                A_TX:if(poly_in_tready)begin
                    watchdog<=0;
                    if(tx_index==7'd127)begin tx_index<=0;state<=B_REQ;end
                    else begin tx_index<=tx_index+1'b1;state<=A_REQ;end
                end
                B_REQ:if(sp_rd_req_ready[b_bank_q])state<=B_WAIT;
                B_WAIT:if(sp_rd_rsp_valid[b_bank_q])begin
                    tx_word<=sp_rd_rsp_data[b_bank_q*64+:64];state<=B_TX;
                end
                B_TX:if(poly_in_tready)begin
                    watchdog<=0;
                    if(tx_index==7'd127)begin rx_index<=0;state<=RX;end
                    else begin tx_index<=tx_index+1'b1;state<=B_REQ;end
                end
                RX:if(poly_out_tvalid)begin
                    watchdog<=0;
                    if(poly_out_tkeep!=8'hff || poly_out_tstrb!=8'hff ||
                       poly_out_tlast!=(rx_index==7'd127))state<=ERR;
                    else begin rx_word<=poly_out_tdata;state<=ACC;end
                end
                ACC:begin
                    sum0_q<=sm0;
                    sum1_q<=sm1;
                    state<=ACC_COMMIT;
                end
                ACC_COMMIT:begin
                    // Both operands in [-q,q], acc canonical [0,q-1].
                    // One modular correction is sufficient.
                    if(sum0_q >= 2*Q || sum0_q < -Q ||
                       sum1_q >= 2*Q || sum1_q < -Q)state<=ERR;
                    else begin
                        if(rx_index==7'd127)state<=AX_IDLE;
                        else begin rx_index<=rx_index+1'b1;state<=RX;end
                    end
                end
                AX_IDLE:if(ax_poisoned)state<=ERR;
                        else if(ax_req_ready)state<=AX_IDLE_WAIT;
                AX_IDLE_WAIT:if(ax_rsp_valid)begin
                    watchdog<=0;
                    if(ax_rsp_error)state<=ERR;
                    else if(ax_rsp_rdata[2])state<=NEXT_TERM;
                    else state<=AX_IDLE;
                end
                NEXT_TERM:begin
                    if(cs1_mode || term==2'd3)begin
                        save_index<=0;state<=WRITE;
                    end else begin term<=term+1'b1;state<=AX_START;end
                end
                WRITE:if(sp_wr_req_ready[2])begin
                    watchdog<=0;
                    if(save_index==7'd127)begin
                        if(cs1_mode && term!=2'd3)begin
                            term<=term+1'b1;
                            state<=AX_START;
                        end else state<=DONE;
                    end else save_index<=save_index+1'b1;
                end
                DONE:state<=IDLE;
                ERR:state<=IDLE;
                default:state<=ERR;
            endcase
        end
    end
endmodule
