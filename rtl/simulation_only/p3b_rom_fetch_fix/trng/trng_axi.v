`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/14/2026 09:48:37 PM
// Design Name: 
// Module Name: trng_axi
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////



module trng_axi #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)(
    input  wire                                s_axi_aclk,
    input  wire                                s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
    input  wire [2:0]                          s_axi_awprot,
    input  wire                                s_axi_awvalid,
    output reg                                 s_axi_awready,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]       s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   s_axi_wstrb,
    input  wire                                s_axi_wvalid,
    output reg                                 s_axi_wready,

    output reg  [1:0]                          s_axi_bresp,
    output reg                                 s_axi_bvalid,
    input  wire                                s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
    input  wire [2:0]                          s_axi_arprot,
    input  wire                                s_axi_arvalid,
    output reg                                 s_axi_arready,

    output reg  [C_S_AXI_DATA_WIDTH-1:0]       s_axi_rdata,
    output reg  [1:0]                          s_axi_rresp,
    output reg                                 s_axi_rvalid,
    input  wire                                s_axi_rready,
    // seal_v8 phase 2: PL-only entropy port to wepwawet_sign_axil (same clock domain, pl_clk0).
    // While pl_claim=1 the source is forced on at the characterised SAMPLE_DIV=16, every word goes
    // ONLY to pl_word, and the AXI RAND_WORD/valid path is muted (reads 0, valid never set).
    input  wire                                pl_claim,
    output wire [31:0]                         pl_word,
    output wire                                pl_valid,
    output wire                                pl_health_fail
);

    // 0x00 CTRL        bit0 = enable
    // 0x04 MODE        bits[1:0]
    // 0x08 SAMPLE_DIV  bits[7:0]
    // 0x0C STATUS      bit0 = valid, bit1 = health_fail
    // 0x10 RAND_WORD   [31:0]

    localparam [2:0] REG_CTRL       = 3'd0;
    localparam [2:0] REG_MODE       = 3'd1;
    localparam [2:0] REG_SAMPLE_DIV = 3'd2;
    localparam [2:0] REG_STATUS     = 3'd3;
    localparam [2:0] REG_RAND_WORD  = 3'd4;

    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_latched;
    reg [C_S_AXI_DATA_WIDTH-1:0] wdata_latched;
    reg [(C_S_AXI_DATA_WIDTH/8)-1:0] wstrb_latched;

    reg aw_seen;
    reg w_seen;

    reg        enable_reg;
    reg [1:0]  mode_reg;
    reg [7:0]  sample_div_reg;

    reg [31:0] rand_word_reg;
    reg        valid_sticky;

    wire [31:0] rand_word_w;
    wire        valid_w;
    wire        health_fail_w;

    wire [2:0] wr_idx = awaddr_latched[4:2];
    wire [2:0] rd_idx = s_axi_araddr[4:2];

    wire [31:0] status_word = {29'd0, pl_claim, health_fail_w, valid_sticky};
    assign pl_word = rand_word_w;
    assign pl_valid = valid_w & pl_claim;
    assign pl_health_fail = health_fail_w;
    wire do_write = aw_seen && w_seen && !s_axi_bvalid;

    entropy_src u_entropy_src (
        .clk         (s_axi_aclk),
        .rst_n       (s_axi_aresetn),
        .enable      (enable_reg | pl_claim),
        .mode        (2'b10),
        .sample_div  (pl_claim ? 8'd16 : sample_div_reg),
        .rand_word   (rand_word_w),
        .valid       (valid_w),
        .health_fail (health_fail_w)
    );

    // Capture generated word and sticky valid
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            rand_word_reg <= 32'd0;
            valid_sticky  <= 1'b0;
        end else begin
            if (!enable_reg || pl_claim) begin
                valid_sticky <= 1'b0;
                if (pl_claim) rand_word_reg <= 32'd0;            // words drawn for the PL never reach the AXI path
            end else begin
                if (valid_w) begin
                    rand_word_reg <= rand_word_w;
                    valid_sticky  <= 1'b1;
                end

                if (!s_axi_rvalid && s_axi_arvalid && (rd_idx == REG_RAND_WORD)) begin
                    valid_sticky <= 1'b0;
                end
            end
        end
    end

    // Write address/data capture
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            aw_seen        <= 1'b0;
            w_seen         <= 1'b0;
            awaddr_latched <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_latched  <= {C_S_AXI_DATA_WIDTH{1'b0}};
            wstrb_latched  <= {(C_S_AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            s_axi_awready <= (!aw_seen && !s_axi_bvalid);
            s_axi_wready  <= (!w_seen  && !s_axi_bvalid);

            if (s_axi_awready && s_axi_awvalid) begin
                aw_seen        <= 1'b1;
                awaddr_latched <= s_axi_awaddr;
            end

            if (s_axi_wready && s_axi_wvalid) begin
                w_seen        <= 1'b1;
                wdata_latched <= s_axi_wdata;
                wstrb_latched <= s_axi_wstrb;
            end

            if (s_axi_bvalid && s_axi_bready) begin
                aw_seen <= 1'b0;
                w_seen  <= 1'b0;
            end
        end
    end

    // Register writes
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            enable_reg     <= 1'b0;
            mode_reg       <= 2'b00;
            sample_div_reg <= 8'd16;
        end else begin
            if (do_write) begin
                case (wr_idx)
                    REG_CTRL: begin
                        if (wstrb_latched[0]) enable_reg <= wdata_latched[0];
                    end

                    REG_MODE: begin
                        if (wstrb_latched[0]) mode_reg <= wdata_latched[1:0];
                    end

                    REG_SAMPLE_DIV: begin
                        if (wstrb_latched[0]) sample_div_reg <= wdata_latched[7:0];
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

    // Write response
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            if (do_write) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // Read path
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'd0;
        end else begin
            s_axi_arready <= (!s_axi_rvalid);

            if (!s_axi_rvalid && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;

                case (rd_idx)
                    REG_CTRL:       s_axi_rdata <= {31'd0, enable_reg};
                    REG_MODE:       s_axi_rdata <= {30'd0, mode_reg};
                    REG_SAMPLE_DIV: s_axi_rdata <= {24'd0, sample_div_reg};
                    REG_STATUS:     s_axi_rdata <= status_word;
                    REG_RAND_WORD:  s_axi_rdata <= rand_word_reg;
                    default:        s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule