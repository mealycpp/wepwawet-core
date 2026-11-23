`timescale 1ns/1ps
// WEPWAWET SIGN image control bridge (production variant of stage19_cfg_bridge).
// Real HLS NTT/INTT/SHAKE256/SHAKE128 AXI-Lite slaves are driven through real
// WCORE AXI-Lite masters. In the SIGN image, stream lanes are steered by the
// RTL lane mux driven by the sequencer's route_lane; the HLS distributor and
// collector are NOT instantiated. Their legacy register writes (0xA001_00xx,
// 0xA002_00xx) are therefore accepted and counted as no-ops. Any other address,
// a read, or a partial strobe returns rsp_error (fail closed).
// No program-specific expected-sequence model remains in this module.
module stage19_cfg_bridge (
    input wire clk,rst_n,abort,
    input wire req_valid,output wire req_ready,input wire req_write,
    input wire [31:0] req_addr,req_wdata,input wire [3:0] req_wstrb,
    output wire rsp_valid,input wire rsp_ready,output wire rsp_error,
    output wire poisoned,
    output reg [15:0] router_writes,ntt_starts,intt_starts,
    output wire [3:0] n_awaddr,output wire n_awvalid,input wire n_awready,
    output wire [31:0] n_wdata,output wire [3:0] n_wstrb,
    output wire n_wvalid,input wire n_wready,
    input wire [1:0] n_bresp,input wire n_bvalid,output wire n_bready,
    output wire [3:0] n_araddr,output wire n_arvalid,input wire n_arready,
    input wire [31:0] n_rdata,input wire [1:0] n_rresp,
    input wire n_rvalid,output wire n_rready,
    output wire [3:0] i_awaddr,output wire i_awvalid,input wire i_awready,
    output wire [31:0] i_wdata,output wire [3:0] i_wstrb,
    output wire i_wvalid,input wire i_wready,
    input wire [1:0] i_bresp,input wire i_bvalid,output wire i_bready,
    output wire [3:0] i_araddr,output wire i_arvalid,input wire i_arready,
    input wire [31:0] i_rdata,input wire [1:0] i_rresp,
    input wire i_rvalid,output wire i_rready,
    output wire [4:0] sh_awaddr,output wire sh_awvalid,input wire sh_awready,
    output wire [31:0] sh_wdata,output wire [3:0] sh_wstrb,
    output wire sh_wvalid,input wire sh_wready,
    input wire [1:0] sh_bresp,input wire sh_bvalid,output wire sh_bready,
    output wire [4:0] sh_araddr,output wire sh_arvalid,input wire sh_arready,
    input wire [31:0] sh_rdata,input wire [1:0] sh_rresp,
    input wire sh_rvalid,output wire sh_rready,
    output wire [4:0] s128_awaddr,output wire s128_awvalid,input wire s128_awready,
    output wire [31:0] s128_wdata,output wire [3:0] s128_wstrb,
    output wire s128_wvalid,input wire s128_wready,
    input wire [1:0] s128_bresp,input wire s128_bvalid,output wire s128_bready,
    output wire [4:0] s128_araddr,output wire s128_arvalid,input wire s128_arready,
    input wire [31:0] s128_rdata,input wire [1:0] s128_rresp,
    input wire s128_rvalid,output wire s128_rready
);
    localparam [2:0] IDLE=0,WAIT_NTT=1,WAIT_INTT=2,ACK_ROUTER=3,WAIT_SHAKE=4,WAIT_SHAKE128=5;
    reg [2:0] state;
    reg model_error;
    wire sel_shake=(req_addr[31:5]==(32'h8007_0000>>5));
    wire sel_shake128=(req_addr[31:5]==(32'h8005_0000>>5));
    wire sel_ntt=(req_addr==32'h8003_0000);
    wire sel_intt=(req_addr==32'h8002_0000);
    wire sel_router=(req_addr==32'hA002_0000 ||
                     req_addr==32'hA002_0010 ||
                     req_addr==32'hA002_0018 ||
                     req_addr==32'hA001_0000 ||
                     req_addr==32'hA001_0010 ||
                     req_addr==32'hA001_0018);
    wire n_req_ready,n_rsp_valid,n_rsp_error,n_poisoned;
    wire sh_req_ready,sh_rsp_valid,sh_rsp_error,sh_poisoned;
    wire s128_req_ready,s128_rsp_valid,s128_rsp_error,s128_poisoned;
    wire i_req_ready,i_rsp_valid,i_rsp_error,i_poisoned;
    wire [31:0] n_unused_rdata,i_unused_rdata,sh_unused_rdata,s128_unused_rdata;
    assign poisoned=n_poisoned || i_poisoned || sh_poisoned || s128_poisoned;
    assign req_ready=(state==IDLE && !abort && !poisoned) &&
        (sel_ntt ? n_req_ready : sel_intt ? i_req_ready :
         sel_shake ? sh_req_ready : sel_shake128 ? s128_req_ready : 1'b1);
    assign rsp_valid=state==WAIT_NTT ? n_rsp_valid :
                     state==WAIT_INTT ? i_rsp_valid :
                     state==WAIT_SHAKE ? sh_rsp_valid :
                     state==WAIT_SHAKE128 ? s128_rsp_valid :
                     state==ACK_ROUTER;
    assign rsp_error=state==WAIT_NTT ? n_rsp_error :
                     state==WAIT_INTT ? i_rsp_error :
                     state==WAIT_SHAKE ? sh_rsp_error :
                     state==WAIT_SHAKE128 ? s128_rsp_error : model_error;
    wcore_axil_master #(.ADDR_W(4),.TIMEOUT(2048)) u_axil_ntt(
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .req_valid(req_valid && state==IDLE && sel_ntt),
        .req_ready(n_req_ready),.req_write(req_write),
        .req_addr(req_addr[3:0]),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(n_rsp_valid),.rsp_ready(rsp_ready && state==WAIT_NTT),
        .rsp_error(n_rsp_error),.rsp_rdata(n_unused_rdata),.poisoned(n_poisoned),
        .m_axi_awaddr(n_awaddr),.m_axi_awvalid(n_awvalid),.m_axi_awready(n_awready),
        .m_axi_wdata(n_wdata),.m_axi_wstrb(n_wstrb),
        .m_axi_wvalid(n_wvalid),.m_axi_wready(n_wready),
        .m_axi_bresp(n_bresp),.m_axi_bvalid(n_bvalid),.m_axi_bready(n_bready),
        .m_axi_araddr(n_araddr),.m_axi_arvalid(n_arvalid),.m_axi_arready(n_arready),
        .m_axi_rdata(n_rdata),.m_axi_rresp(n_rresp),
        .m_axi_rvalid(n_rvalid),.m_axi_rready(n_rready)
    );
    wcore_axil_master #(.ADDR_W(4),.TIMEOUT(2048)) u_axil_intt(
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .req_valid(req_valid && state==IDLE && sel_intt),
        .req_ready(i_req_ready),.req_write(req_write),
        .req_addr(req_addr[3:0]),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(i_rsp_valid),.rsp_ready(rsp_ready && state==WAIT_INTT),
        .rsp_error(i_rsp_error),.rsp_rdata(i_unused_rdata),.poisoned(i_poisoned),
        .m_axi_awaddr(i_awaddr),.m_axi_awvalid(i_awvalid),.m_axi_awready(i_awready),
        .m_axi_wdata(i_wdata),.m_axi_wstrb(i_wstrb),
        .m_axi_wvalid(i_wvalid),.m_axi_wready(i_wready),
        .m_axi_bresp(i_bresp),.m_axi_bvalid(i_bvalid),.m_axi_bready(i_bready),
        .m_axi_araddr(i_araddr),.m_axi_arvalid(i_arvalid),.m_axi_arready(i_arready),
        .m_axi_rdata(i_rdata),.m_axi_rresp(i_rresp),
        .m_axi_rvalid(i_rvalid),.m_axi_rready(i_rready)
    );
    wcore_axil_master #(.ADDR_W(5),.TIMEOUT(2048)) u_axil_shake(
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .req_valid(req_valid && state==IDLE && sel_shake),
        .req_ready(sh_req_ready),.req_write(req_write),
        .req_addr(req_addr[4:0]),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(sh_rsp_valid),.rsp_ready(rsp_ready && state==WAIT_SHAKE),
        .rsp_error(sh_rsp_error),.rsp_rdata(sh_unused_rdata),.poisoned(sh_poisoned),
        .m_axi_awaddr(sh_awaddr),.m_axi_awvalid(sh_awvalid),.m_axi_awready(sh_awready),
        .m_axi_wdata(sh_wdata),.m_axi_wstrb(sh_wstrb),
        .m_axi_wvalid(sh_wvalid),.m_axi_wready(sh_wready),
        .m_axi_bresp(sh_bresp),.m_axi_bvalid(sh_bvalid),.m_axi_bready(sh_bready),
        .m_axi_araddr(sh_araddr),.m_axi_arvalid(sh_arvalid),.m_axi_arready(sh_arready),
        .m_axi_rdata(sh_rdata),.m_axi_rresp(sh_rresp),
        .m_axi_rvalid(sh_rvalid),.m_axi_rready(sh_rready)
    );
    wcore_axil_master #(.ADDR_W(5),.TIMEOUT(2048)) u_axil_shake128(
        .clk(clk),.rst_n(rst_n),.abort(abort),
        .req_valid(req_valid && state==IDLE && sel_shake128),
        .req_ready(s128_req_ready),.req_write(req_write),
        .req_addr(req_addr[4:0]),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(s128_rsp_valid),.rsp_ready(rsp_ready && state==WAIT_SHAKE128),
        .rsp_error(s128_rsp_error),.rsp_rdata(s128_unused_rdata),.poisoned(s128_poisoned),
        .m_axi_awaddr(s128_awaddr),.m_axi_awvalid(s128_awvalid),.m_axi_awready(s128_awready),
        .m_axi_wdata(s128_wdata),.m_axi_wstrb(s128_wstrb),
        .m_axi_wvalid(s128_wvalid),.m_axi_wready(s128_wready),
        .m_axi_bresp(s128_bresp),.m_axi_bvalid(s128_bvalid),.m_axi_bready(s128_bready),
        .m_axi_araddr(s128_araddr),.m_axi_arvalid(s128_arvalid),.m_axi_arready(s128_arready),
        .m_axi_rdata(s128_rdata),.m_axi_rresp(s128_rresp),
        .m_axi_rvalid(s128_rvalid),.m_axi_rready(s128_rready)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            state<=IDLE;model_error<=0;
            router_writes<=0;ntt_starts<=0;intt_starts<=0;
        end else if(abort)begin
            state<=IDLE;model_error<=0;
        end else begin
            case(state)
                IDLE:if(req_valid && req_ready)begin
                    if(sel_ntt)begin
                        state<=WAIT_NTT;
                        if(req_write && req_wdata==32'd1 && req_wstrb==4'hf)
                            ntt_starts<=ntt_starts+1'b1;
                    end else if(sel_intt)begin
                        state<=WAIT_INTT;
                        if(req_write && req_wdata==32'd1 && req_wstrb==4'hf)
                            intt_starts<=intt_starts+1'b1;
                    end else if(sel_shake)begin
                        state<=WAIT_SHAKE;
                    end else if(sel_shake128)begin
                        state<=WAIT_SHAKE128;
                    end else begin
                        state<=ACK_ROUTER;
                        model_error<= !sel_router || !req_write || (req_wstrb!=4'hf);
                        if(sel_router && req_write && req_wstrb==4'hf)
                            router_writes<=router_writes+1'b1;
                    end
                end
                WAIT_NTT:if(n_rsp_valid && rsp_ready)state<=IDLE;
                WAIT_INTT:if(i_rsp_valid && rsp_ready)state<=IDLE;
                WAIT_SHAKE:if(sh_rsp_valid && rsp_ready)state<=IDLE;
                WAIT_SHAKE128:if(s128_rsp_valid && rsp_ready)state<=IDLE;
                ACK_ROUTER:if(rsp_ready)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
