`timescale 1ns/1ps
// Original WCORE AXI-Lite master from user Stage 8 sources.
module wcore_axil_master #(
    parameter integer ADDR_W = 32,
    parameter integer TIMEOUT = 1024
)(
    input wire clk,
    input wire rst_n,
    input wire abort,
    input wire req_valid,
    output wire req_ready,
    input wire req_write,
    input wire [ADDR_W-1:0] req_addr,
    input wire [31:0] req_wdata,
    input wire [3:0] req_wstrb,
    output wire rsp_valid,
    input wire rsp_ready,
    output reg rsp_error,
    output reg [31:0] rsp_rdata,
    output reg poisoned,
    output wire [ADDR_W-1:0] m_axi_awaddr,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0] m_axi_wstrb,
    output wire m_axi_wvalid,
    input wire m_axi_wready,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [ADDR_W-1:0] m_axi_araddr,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [31:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rvalid,
    output wire m_axi_rready
);
    localparam [2:0] AX_IDLE=0, AX_W_SEND=1, AX_W_RESP=2,
                     AX_R_SEND=3, AX_R_RESP=4, AX_RESULT=5;
    (* fsm_encoding = "none" *) reg [2:0] state;
    reg [ADDR_W-1:0] addr_q;
    reg [31:0] data_q;
    reg [3:0] strb_q;
    reg aw_done, w_done;
    reg [31:0] timer;
    assign req_ready = (state == AX_IDLE) && !poisoned && !abort;
    assign rsp_valid = (state == AX_RESULT);
    assign m_axi_awaddr = addr_q;
    assign m_axi_wdata = data_q;
    assign m_axi_wstrb = strb_q;
    assign m_axi_araddr = addr_q;
    assign m_axi_awvalid = (state == AX_W_SEND) && !aw_done;
    assign m_axi_wvalid = (state == AX_W_SEND) && !w_done;
    assign m_axi_bready = (state == AX_W_RESP);
    assign m_axi_arvalid = (state == AX_R_SEND);
    assign m_axi_rready = (state == AX_R_RESP);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= AX_IDLE;
            addr_q <= 0; data_q <= 0; strb_q <= 0;
            aw_done <= 0; w_done <= 0;
            timer <= 0; rsp_error <= 0; rsp_rdata <= 0;
            poisoned <= 0;
        end else if (abort && state != AX_IDLE && state != AX_RESULT) begin
            poisoned <= 1;
            rsp_error <= 1;
            rsp_rdata <= 0;
            state <= AX_RESULT;
        end else begin
            case (state)
                AX_IDLE: begin
                    if (req_valid && req_ready) begin
                        addr_q <= req_addr;
                        data_q <= req_wdata;
                        strb_q <= req_wstrb;
                        aw_done <= 0; w_done <= 0;
                        timer <= 0;
                        rsp_error <= 0;
                        rsp_rdata <= 0;
                        state <= req_write ? AX_W_SEND : AX_R_SEND;
                    end
                end
                AX_W_SEND: begin
                    if (m_axi_awvalid && m_axi_awready) aw_done <= 1;
                    if (m_axi_wvalid && m_axi_wready) w_done <= 1;
                    if ((aw_done || m_axi_awready) &&
                        (w_done || m_axi_wready)) begin
                        timer <= 0;
                        state <= AX_W_RESP;
                    end else if (timer >= TIMEOUT-1) begin
                        poisoned <= 1; rsp_error <= 1;
                        state <= AX_RESULT;
                    end else timer <= timer + 1'b1;
                end
                AX_W_RESP: begin
                    if (m_axi_bvalid) begin
                        rsp_error <= (m_axi_bresp != 2'b00);
                        state <= AX_RESULT;
                    end else if (timer >= TIMEOUT-1) begin
                        poisoned <= 1; rsp_error <= 1;
                        state <= AX_RESULT;
                    end else timer <= timer + 1'b1;
                end
                AX_R_SEND: begin
                    if (m_axi_arready) begin
                        timer <= 0;
                        state <= AX_R_RESP;
                    end else if (timer >= TIMEOUT-1) begin
                        poisoned <= 1; rsp_error <= 1;
                        state <= AX_RESULT;
                    end else timer <= timer + 1'b1;
                end
                AX_R_RESP: begin
                    if (m_axi_rvalid) begin
                        rsp_rdata <= m_axi_rdata;
                        rsp_error <= (m_axi_rresp != 2'b00);
                        state <= AX_RESULT;
                    end else if (timer >= TIMEOUT-1) begin
                        poisoned <= 1; rsp_error <= 1;
                        state <= AX_RESULT;
                    end else timer <= timer + 1'b1;
                end
                AX_RESULT: if (rsp_ready) state <= AX_IDLE;
                default: begin
                    poisoned <= 1;
                    rsp_error <= 1;
                    state <= AX_RESULT;
                end
            endcase
        end
    end
endmodule
