`timescale 1ns/1ps
// Stage19 TEST ONLY: real Vitis HLS NTT -> RTL AUX DOT4 -> real Vitis
// HLS INTT, one Stage9 WCORE START and real four-bank scratchpad.
// The distributor/collector AXI-Lite register writes are modeled, but both
// HLS core AXI-Lite register blocks and both AXI4-Stream datapaths are REAL.
// NOT complete ML-DSA-44 SIGN/VERIFY; NOT a routed 300 MHz implementation.
module wcore_stage19_real_ntt_dot4_intt #(
    parameter integer ADDR_W=11,BANKS=4
)(
    input wire clk,por_n,rst_n,start_job,job_ack,soft_reset_req,
    input wire verify_mode,
    output wire job_busy,job_done,job_error,job_irq,
    output wire [7:0] error_code,pc_status,
    output wire [15:0] kappa_status,attempt_status,
    output wire reject_status,adapter_recovery_required,
    output wire route_enable,output wire [2:0] route_lane,
    output wire [15:0] router_writes,ntt_starts,intt_starts,
    input wire host_mode,
    input wire [BANKS-1:0] h_rd_req_valid,
    output wire [BANKS-1:0] h_rd_req_ready,
    input wire [BANKS*ADDR_W-1:0] h_rd_req_addr,
    output wire [BANKS-1:0] h_rd_rsp_valid,
    input wire [BANKS-1:0] h_rd_rsp_ready,
    output wire [BANKS*64-1:0] h_rd_rsp_data,
    input wire [BANKS-1:0] h_wr_req_valid,
    output wire [BANKS-1:0] h_wr_req_ready,
    input wire [BANKS*ADDR_W-1:0] h_wr_req_addr,
    input wire [BANKS*64-1:0] h_wr_req_data,
    output wire sp_init_done,sp_busy,sp_locked,
    input wire ext_scrub_req,       // seal_v8 ZEROIZE
    input wire pro_mode, pro_det,   // seal_v8 phase 2 prologue
    input wire kg_page, kg_kat,     // seal_v8 phase 3 KeyGen ROM page
    output wire sp_scrub_done
);
    wire [63:0] tx_tdata,rx_tdata;
    wire tx_tvalid,tx_tready,tx_tlast,rx_tvalid,rx_tready,rx_tlast;
    wire [7:0] tx_tkeep,tx_tstrb;
    wire cfg_req_valid,cfg_req_ready,cfg_req_write,cfg_rsp_valid,cfg_rsp_ready;
    wire cfg_rsp_error,cfg_poisoned;
    wire [31:0] cfg_req_addr,cfg_req_wdata;
    wire [3:0] cfg_req_wstrb;
    wire ntt_select=route_enable && route_lane==3'd0;
    wire intt_select=route_enable && route_lane==3'd1;
    wire ntt_in_ready,ntt_out_valid,ntt_out_last;
    wire [63:0] ntt_out_data;
    wire [7:0] ntt_out_keep,ntt_out_strb;
    wire intt_in_ready,intt_out_valid,intt_out_last;
    wire [63:0] intt_out_data;
    wire [7:0] intt_out_keep,intt_out_strb;
    wire n_awvalid,n_awready,n_wvalid,n_wready,n_bvalid,n_bready;
    wire n_arvalid,n_arready,n_rvalid,n_rready;
    wire [3:0] n_awaddr,n_araddr,n_wstrb;
    wire [31:0] n_wdata,n_rdata;
    wire [1:0] n_bresp,n_rresp;
    wire i_awvalid,i_awready,i_wvalid,i_wready,i_bvalid,i_bready;
    wire i_arvalid,i_arready,i_rvalid,i_rready;
    wire [3:0] i_awaddr,i_araddr,i_wstrb;
    wire [31:0] i_wdata,i_rdata;
    wire [1:0] i_bresp,i_rresp;
    wire unused_ntt_irq,unused_intt_irq,unused_shake_irq;
    wire shake_select=route_enable && route_lane==3'd3;
    wire shake128_select=route_enable && route_lane==3'd4;
    wire shake_in_ready,shake_out_valid,shake_out_last;
    wire [63:0] shake_out_data;
    wire [7:0] shake_out_keep,shake_out_strb;
    wire shake128_in_ready,shake128_out_valid,shake128_out_last;
    wire [63:0] shake128_out_data;
    wire [7:0] shake128_out_keep,shake128_out_strb;
    wire s128_awvalid,s128_awready,s128_wvalid,s128_wready,s128_bvalid,s128_bready;
    wire s128_arvalid,s128_arready,s128_rvalid,s128_rready;
    wire [4:0] s128_awaddr,s128_araddr;
    wire [3:0] s128_wstrb;
    wire [31:0] s128_wdata,s128_rdata;
    wire [1:0] s128_bresp,s128_rresp;

    wire sh_awvalid,sh_awready,sh_wvalid,sh_wready,sh_bvalid,sh_bready;
    wire sh_arvalid,sh_arready,sh_rvalid,sh_rready;
    wire [4:0] sh_awaddr,sh_araddr;
    wire [3:0] sh_wstrb;
    wire [31:0] sh_wdata,sh_rdata;
    wire [1:0] sh_bresp,sh_rresp;

    assign tx_tready=ntt_select ? ntt_in_ready :
                     intt_select ? intt_in_ready :
                     shake_select ? shake_in_ready :
                     shake128_select ? shake128_in_ready : 1'b0;
    assign rx_tdata=ntt_select ? ntt_out_data :
                    intt_select ? intt_out_data :
                    shake_select ? shake_out_data :
                    shake128_select ? shake128_out_data : 64'd0;
    assign rx_tvalid=ntt_select ? ntt_out_valid :
                     intt_select ? intt_out_valid :
                     shake_select ? shake_out_valid :
                     shake128_select ? shake128_out_valid : 1'b0;
    assign rx_tlast=ntt_select ? ntt_out_last :
                    intt_select ? intt_out_last :
                    shake_select ? shake_out_last :
                    shake128_select ? shake128_out_last : 1'b0;

    wcore_stage19_axis_dot4_integrated #(.ADDR_W(ADDR_W),.BANKS(BANKS)) u_wcore(
        .clk(clk),.por_n(por_n),.rst_n(rst_n),
        .start_job(start_job),.job_ack(job_ack),.soft_reset_req(soft_reset_req),.verify_mode(verify_mode),
        .job_busy(job_busy),.job_done(job_done),.job_error(job_error),
        .job_irq(job_irq),.error_code(error_code),.pc_status(pc_status),
        .kappa_status(kappa_status),.attempt_status(attempt_status),
        .reject_status(reject_status),
        .m_axis_tdata(tx_tdata),.m_axis_tvalid(tx_tvalid),
        .m_axis_tready(tx_tready),.m_axis_tlast(tx_tlast),
        .m_axis_tkeep(tx_tkeep),.m_axis_tstrb(tx_tstrb),
        .s_axis_tdata(rx_tdata),.s_axis_tvalid(rx_tvalid),
        .s_axis_tready(rx_tready),.s_axis_tlast(rx_tlast),
        .adapter_recovery_required(adapter_recovery_required),
        .route_enable(route_enable),.route_lane(route_lane),
        .cfg_req_valid(cfg_req_valid),.cfg_req_ready(cfg_req_ready),
        .cfg_req_write(cfg_req_write),.cfg_req_addr(cfg_req_addr),
        .cfg_req_wdata(cfg_req_wdata),.cfg_req_wstrb(cfg_req_wstrb),
        .cfg_rsp_valid(cfg_rsp_valid),.cfg_rsp_ready(cfg_rsp_ready),
        .cfg_rsp_error(cfg_rsp_error),.cfg_poisoned(cfg_poisoned),
        .host_mode(host_mode),
        .h_rd_req_valid(h_rd_req_valid),.h_rd_req_ready(h_rd_req_ready),
        .h_rd_req_addr(h_rd_req_addr),.h_rd_rsp_valid(h_rd_rsp_valid),
        .h_rd_rsp_ready(h_rd_rsp_ready),.h_rd_rsp_data(h_rd_rsp_data),
        .h_wr_req_valid(h_wr_req_valid),.h_wr_req_ready(h_wr_req_ready),
        .h_wr_req_addr(h_wr_req_addr),.h_wr_req_data(h_wr_req_data),
        .sp_init_done(sp_init_done),.sp_busy(sp_busy),.sp_locked(sp_locked),
        .ext_scrub_req(ext_scrub_req),.sp_scrub_done_o(sp_scrub_done),
        .pro_mode(pro_mode),.pro_det(pro_det),.kg_page(kg_page),.kg_kat(kg_kat)
    );
    stage19_cfg_bridge u_bridge(
        .clk(clk),.rst_n(rst_n),.abort(soft_reset_req),
        .req_valid(cfg_req_valid),.req_ready(cfg_req_ready),
        .req_write(cfg_req_write),.req_addr(cfg_req_addr),
        .req_wdata(cfg_req_wdata),.req_wstrb(cfg_req_wstrb),
        .rsp_valid(cfg_rsp_valid),.rsp_ready(cfg_rsp_ready),
        .rsp_error(cfg_rsp_error),.poisoned(cfg_poisoned),
        .router_writes(router_writes),.ntt_starts(ntt_starts),
        .intt_starts(intt_starts),
        .n_awaddr(n_awaddr),.n_awvalid(n_awvalid),.n_awready(n_awready),
        .n_wdata(n_wdata),.n_wstrb(n_wstrb),.n_wvalid(n_wvalid),.n_wready(n_wready),
        .n_bresp(n_bresp),.n_bvalid(n_bvalid),.n_bready(n_bready),
        .n_araddr(n_araddr),.n_arvalid(n_arvalid),.n_arready(n_arready),
        .n_rdata(n_rdata),.n_rresp(n_rresp),.n_rvalid(n_rvalid),.n_rready(n_rready),
        .i_awaddr(i_awaddr),.i_awvalid(i_awvalid),.i_awready(i_awready),
        .i_wdata(i_wdata),.i_wstrb(i_wstrb),.i_wvalid(i_wvalid),.i_wready(i_wready),
        .i_bresp(i_bresp),.i_bvalid(i_bvalid),.i_bready(i_bready),
        .i_araddr(i_araddr),.i_arvalid(i_arvalid),.i_arready(i_arready),
        .i_rdata(i_rdata),.i_rresp(i_rresp),.i_rvalid(i_rvalid),.i_rready(i_rready),
        .sh_awaddr(sh_awaddr),.sh_awvalid(sh_awvalid),.sh_awready(sh_awready),
        .sh_wdata(sh_wdata),.sh_wstrb(sh_wstrb),.sh_wvalid(sh_wvalid),.sh_wready(sh_wready),
        .sh_bresp(sh_bresp),.sh_bvalid(sh_bvalid),.sh_bready(sh_bready),
        .sh_araddr(sh_araddr),.sh_arvalid(sh_arvalid),.sh_arready(sh_arready),
        .sh_rdata(sh_rdata),.sh_rresp(sh_rresp),.sh_rvalid(sh_rvalid),.sh_rready(sh_rready),
        .s128_awaddr(s128_awaddr),.s128_awvalid(s128_awvalid),.s128_awready(s128_awready),
        .s128_wdata(s128_wdata),.s128_wstrb(s128_wstrb),.s128_wvalid(s128_wvalid),.s128_wready(s128_wready),
        .s128_bresp(s128_bresp),.s128_bvalid(s128_bvalid),.s128_bready(s128_bready),
        .s128_araddr(s128_araddr),.s128_arvalid(s128_arvalid),.s128_arready(s128_arready),
        .s128_rdata(s128_rdata),.s128_rresp(s128_rresp),.s128_rvalid(s128_rvalid),.s128_rready(s128_rready)
    );
    ntt_top u_real_ntt (
        .ap_clk(clk),.ap_rst_n(rst_n),
        .in_r_TDATA(tx_tdata),.in_r_TVALID(tx_tvalid && ntt_select),
        .in_r_TREADY(ntt_in_ready),.in_r_TKEEP(tx_tkeep),
        .in_r_TSTRB(tx_tstrb),.in_r_TLAST(tx_tlast),
        .out_r_TDATA(ntt_out_data),.out_r_TVALID(ntt_out_valid),
        .out_r_TREADY(rx_tready && ntt_select),
        .out_r_TKEEP(ntt_out_keep),.out_r_TSTRB(ntt_out_strb),
        .out_r_TLAST(ntt_out_last),
        .s_axi_control_AWVALID(n_awvalid),.s_axi_control_AWREADY(n_awready),
        .s_axi_control_AWADDR(n_awaddr),
        .s_axi_control_WVALID(n_wvalid),.s_axi_control_WREADY(n_wready),
        .s_axi_control_WDATA(n_wdata),.s_axi_control_WSTRB(n_wstrb),
        .s_axi_control_ARVALID(n_arvalid),.s_axi_control_ARREADY(n_arready),
        .s_axi_control_ARADDR(n_araddr),
        .s_axi_control_RVALID(n_rvalid),.s_axi_control_RREADY(n_rready),
        .s_axi_control_RDATA(n_rdata),.s_axi_control_RRESP(n_rresp),
        .s_axi_control_BVALID(n_bvalid),.s_axi_control_BREADY(n_bready),
        .s_axi_control_BRESP(n_bresp),.interrupt(unused_ntt_irq)
    );
    intt_top u_real_intt (
        .ap_clk(clk),.ap_rst_n(rst_n),
        .in_r_TDATA(tx_tdata),.in_r_TVALID(tx_tvalid && intt_select),
        .in_r_TREADY(intt_in_ready),.in_r_TKEEP(tx_tkeep),
        .in_r_TSTRB(tx_tstrb),.in_r_TLAST(tx_tlast),
        .out_r_TDATA(intt_out_data),.out_r_TVALID(intt_out_valid),
        .out_r_TREADY(rx_tready && intt_select),
        .out_r_TKEEP(intt_out_keep),.out_r_TSTRB(intt_out_strb),
        .out_r_TLAST(intt_out_last),
        .s_axi_control_AWVALID(i_awvalid),.s_axi_control_AWREADY(i_awready),
        .s_axi_control_AWADDR(i_awaddr),
        .s_axi_control_WVALID(i_wvalid),.s_axi_control_WREADY(i_wready),
        .s_axi_control_WDATA(i_wdata),.s_axi_control_WSTRB(i_wstrb),
        .s_axi_control_ARVALID(i_arvalid),.s_axi_control_ARREADY(i_arready),
        .s_axi_control_ARADDR(i_araddr),
        .s_axi_control_RVALID(i_rvalid),.s_axi_control_RREADY(i_rready),
        .s_axi_control_RDATA(i_rdata),.s_axi_control_RRESP(i_rresp),
        .s_axi_control_BVALID(i_bvalid),.s_axi_control_BREADY(i_bready),
        .s_axi_control_BRESP(i_bresp),.interrupt(unused_intt_irq)
    );
    shake256_axis u_real_shake256 (
        .ap_clk(clk),.ap_rst_n(rst_n),
        .in_s_TDATA(tx_tdata),.in_s_TVALID(tx_tvalid && shake_select),
        .in_s_TREADY(shake_in_ready),.in_s_TKEEP(tx_tkeep),
        .in_s_TSTRB(tx_tstrb),.in_s_TLAST(tx_tlast),
        .out_s_TDATA(shake_out_data),.out_s_TVALID(shake_out_valid),
        .out_s_TREADY(rx_tready && shake_select),
        .out_s_TKEEP(shake_out_keep),.out_s_TSTRB(shake_out_strb),
        .out_s_TLAST(shake_out_last),
        .s_axi_CTRL_AWVALID(sh_awvalid),.s_axi_CTRL_AWREADY(sh_awready),
        .s_axi_CTRL_AWADDR(sh_awaddr),
        .s_axi_CTRL_WVALID(sh_wvalid),.s_axi_CTRL_WREADY(sh_wready),
        .s_axi_CTRL_WDATA(sh_wdata),.s_axi_CTRL_WSTRB(sh_wstrb),
        .s_axi_CTRL_ARVALID(sh_arvalid),.s_axi_CTRL_ARREADY(sh_arready),
        .s_axi_CTRL_ARADDR(sh_araddr),
        .s_axi_CTRL_RVALID(sh_rvalid),.s_axi_CTRL_RREADY(sh_rready),
        .s_axi_CTRL_RDATA(sh_rdata),.s_axi_CTRL_RRESP(sh_rresp),
        .s_axi_CTRL_BVALID(sh_bvalid),.s_axi_CTRL_BREADY(sh_bready),
        .s_axi_CTRL_BRESP(sh_bresp),.interrupt(unused_shake_irq)
    );
    shake128_axis u_real_shake128 (
        .ap_clk(clk),.ap_rst_n(rst_n),
        .in_s_TDATA(tx_tdata),.in_s_TVALID(tx_tvalid && shake128_select),
        .in_s_TREADY(shake128_in_ready),.in_s_TKEEP(tx_tkeep),
        .in_s_TSTRB(tx_tstrb),.in_s_TLAST(tx_tlast),
        .out_s_TDATA(shake128_out_data),.out_s_TVALID(shake128_out_valid),
        .out_s_TREADY(rx_tready && shake128_select),
        .out_s_TKEEP(shake128_out_keep),.out_s_TSTRB(shake128_out_strb),
        .out_s_TLAST(shake128_out_last),
        .s_axi_CTRL_AWVALID(s128_awvalid),.s_axi_CTRL_AWREADY(s128_awready),
        .s_axi_CTRL_AWADDR(s128_awaddr),
        .s_axi_CTRL_WVALID(s128_wvalid),.s_axi_CTRL_WREADY(s128_wready),
        .s_axi_CTRL_WDATA(s128_wdata),.s_axi_CTRL_WSTRB(s128_wstrb),
        .s_axi_CTRL_ARVALID(s128_arvalid),.s_axi_CTRL_ARREADY(s128_arready),
        .s_axi_CTRL_ARADDR(s128_araddr),
        .s_axi_CTRL_RVALID(s128_rvalid),.s_axi_CTRL_RREADY(s128_rready),
        .s_axi_CTRL_RDATA(s128_rdata),.s_axi_CTRL_RRESP(s128_rresp),
        .s_axi_CTRL_BVALID(s128_bvalid),.s_axi_CTRL_BREADY(s128_bready),
        .s_axi_CTRL_BRESP(s128_bresp),.interrupt()
    );
endmodule
