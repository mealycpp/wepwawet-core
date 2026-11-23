`timescale 1ns/1ps
// ============================================================================
// WEPWAWET SIGN image -- PS-facing wrapper (AXI4-Lite slave, 32-bit).
//
// One AXI4-Lite slave in front of the V7 signing core and the registered
// retry manager. Once LAUNCH is written, every ML-DSA-44 signing attempt and
// every rejection/retry decision runs in PL; the PS only preloads inputs
// before launch and reads c~, z, h after DONE.
//
// Byte address map (C_ADDR_W = 17):
//   0x0_0000 .. 0x0_FFFF  scratchpad window (only while the engine is idle)
//                         bank = addr[15:14], word = addr[13:3], half = addr[2]
//                         write low half first; writing the high half commits
//                         the 64-bit word. Reads fetch the word, return a half.
//   0x1_0000  CTRL    W   bit0 LAUNCH (self-clearing), bit1 IRQ_CLEAR,
//                         bit2 MODE at LAUNCH: 0 = SIGN, 1 = VERIFY (verify_v1)
//   0x1_0004  STATUS  R   bit0 busy, bit1 done, bit2 success, bit3 sp_init_done,
//                         bit4 sp_busy, bit5 sp_locked, bit6 job_error,
//                         bit7 adapter_recovery_required, bit8 irq, bit9 mode(1=verify)
//   0x1_0008  KAPPA   R   [15:0] kappa, [31:16] attempts (16-bit; retry bound 814 per FIPS 204 App. C)
//   0x1_000C  ERRORS  R   [7:0] retry error, [15:8] core error, [23:16] pc
//   0x1_0010  CYCLES  R   clock cycles from LAUNCH to DONE (last job)
//   0x1_0014  MAGIC   R   0x5743_5331 ("WCS1")
//   0x1_0018  VERSION R   0x0002_0001 = SIGN + VERIFY programs
//   0x1_0040 .. 0x1_007C  rho'' seed, 16 x 32-bit words (R/W, cleared at DONE)
//   0x1_0080 .. 0x1_009C  public rho, 8 x 32-bit words (R/W)
// Scratchpad access while busy, unmapped addresses -> SLVERR.
// ============================================================================
module wepwawet_sign_axil #(
    parameter integer C_ADDR_W     = 17,
    parameter integer MAX_ATTEMPTS = 814
)(
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET aresetn" *)
    input  wire                 aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                 aresetn,
    input  wire [C_ADDR_W-1:0]  s_axi_awaddr,
    input  wire [2:0]           s_axi_awprot,
    input  wire                 s_axi_awvalid,
    output reg                  s_axi_awready,
    input  wire [31:0]          s_axi_wdata,
    input  wire [3:0]           s_axi_wstrb,
    input  wire                 s_axi_wvalid,
    output reg                  s_axi_wready,
    output reg  [1:0]           s_axi_bresp,
    output reg                  s_axi_bvalid,
    input  wire                 s_axi_bready,
    input  wire [C_ADDR_W-1:0]  s_axi_araddr,
    input  wire [2:0]           s_axi_arprot,
    input  wire                 s_axi_arvalid,
    output reg                  s_axi_arready,
    output reg  [31:0]          s_axi_rdata,
    output reg  [1:0]           s_axi_rresp,
    output reg                  s_axi_rvalid,
    input  wire                 s_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire                 irq
);
    localparam integer AW = 11, BANKS = 4;

    // ------------------------------------------------------------ core + retry
    wire start_job, job_ack, mgr_host_mode;
    wire [3:0] mgr_wr_valid; wire [43:0] mgr_wr_addr; wire [255:0] mgr_wr_data;
    wire mgr_done, mgr_success; wire [15:0] mgr_kappa, mgr_attempts; wire [7:0] mgr_error;
    wire job_busy, job_done, job_error, job_irq, reject_status, adapter_recovery_required;
    wire route_enable; wire [2:0] route_lane;
    wire [7:0] error_code, pc_status;
    wire [15:0] kappa_status, attempt_status, router_writes, ntt_starts, intt_starts;
    wire sp_init_done, sp_busy, sp_locked;

    reg  [3:0]   h_rd_req_valid, h_rd_rsp_ready;
    reg  [43:0]  h_rd_req_addr;
    wire [3:0]   h_rd_req_ready, h_rd_rsp_valid, h_wr_req_ready;
    wire [255:0] h_rd_rsp_data;
    reg  [3:0]   ps_wr_valid;
    reg  [43:0]  ps_wr_addr;
    reg  [255:0] ps_wr_data;

    reg  running;                    // retry manager owns the core
    reg  mode_r;                     // verify_v1: 1 = VERIFY job
    reg  launch_p;
    reg  [511:0] seed_rhoprime;
    reg  [255:0] public_rho;

    wire [3:0]   h_wr_req_valid = running ? mgr_wr_valid : ps_wr_valid;
    wire [43:0]  h_wr_req_addr  = running ? mgr_wr_addr  : ps_wr_addr;
    wire [255:0] h_wr_req_data  = running ? mgr_wr_data  : ps_wr_data;
    wire         host_mode      = running ? mgr_host_mode : 1'b1;

    wcore_stage19_real_ntt_dot4_intt u_core (
        .clk(aclk), .por_n(aresetn), .rst_n(aresetn),
        .start_job(start_job), .job_ack(job_ack), .soft_reset_req(1'b0), .verify_mode(mode_r),
        .job_busy(job_busy), .job_done(job_done), .job_error(job_error),
        .job_irq(job_irq), .error_code(error_code), .pc_status(pc_status),
        .kappa_status(kappa_status), .attempt_status(attempt_status),
        .reject_status(reject_status), .adapter_recovery_required(adapter_recovery_required),
        .route_enable(route_enable), .route_lane(route_lane),
        .router_writes(router_writes), .ntt_starts(ntt_starts), .intt_starts(intt_starts),
        .host_mode(host_mode),
        .h_rd_req_valid(h_rd_req_valid), .h_rd_req_ready(h_rd_req_ready),
        .h_rd_req_addr(h_rd_req_addr), .h_rd_rsp_valid(h_rd_rsp_valid),
        .h_rd_rsp_ready(h_rd_rsp_ready), .h_rd_rsp_data(h_rd_rsp_data),
        .h_wr_req_valid(h_wr_req_valid), .h_wr_req_ready(h_wr_req_ready),
        .h_wr_req_addr(h_wr_req_addr), .h_wr_req_data(h_wr_req_data),
        .sp_init_done(sp_init_done), .sp_busy(sp_busy), .sp_locked(sp_locked)
    );

    v7_registered_retry_manager #(.MAX_ATTEMPTS(MAX_ATTEMPTS)) u_retry (
        .clk(aclk), .rst_n(aresetn), .launch(launch_p), .verify_mode(mode_r),
        .seed_rhoprime(seed_rhoprime), .public_rho(public_rho),
        .job_done(job_done), .job_error(job_error), .job_busy(job_busy),
        .reject_status(reject_status), .pc_status(pc_status),
        .sp_busy(sp_busy), .sp_locked(sp_locked), .wr_ready(h_wr_req_ready),
        .start_job(start_job), .job_ack(job_ack), .host_mode(mgr_host_mode),
        .wr_valid(mgr_wr_valid), .wr_addr(mgr_wr_addr), .wr_data(mgr_wr_data),
        .done(mgr_done), .success(mgr_success), .kappa(mgr_kappa),
        .attempts(mgr_attempts), .error_code(mgr_error)
    );

    // ------------------------------------------------------------ status regs
    reg done_r, success_r, irq_r;
    reg [15:0] kappa_r, attempts_r; reg [7:0] rerr_r, cerr_r, pc_r;
    reg [31:0] cycles, cycles_r;
    reg mgr_done_q;
    assign irq = irq_r;

    // ------------------------------------------------------------ AXI-Lite FSM
    localparam [3:0] A_IDLE=0, A_WAITW=1, A_WR_SP=2, A_WR_RESP=3, A_RD_REQ=4,
                     A_RD_RSP=5, A_RD_RESP=6;
    reg [3:0] ast;
    reg [C_ADDR_W-1:0] waddr, raddr;
    reg aw_got, w_got;
    reg [31:0] wdata_q; reg [3:0] wstrb_q;
    reg [31:0] wlo [0:3];             // pending low halves per bank
    reg [1:0]  bsel;
    reg        hsel;
    reg [15:0] wdog;

    wire w_is_sp  = (waddr[16] == 1'b0);
    wire r_is_sp  = (raddr[16] == 1'b0);
    wire [7:0] w_reg = waddr[7:0];
    wire [7:0] r_reg = raddr[7:0];
    wire w_reg_ok = waddr[15:8] == 8'd0;
    wire r_reg_ok = raddr[15:8] == 8'd0;

    function [31:0] reg_read(input [7:0] a);
        begin
            reg_read = 32'd0;
            case (a)
                8'h04: reg_read = {22'd0, mode_r, irq_r, adapter_recovery_required, job_error, sp_locked,
                                   sp_busy, sp_init_done, success_r, done_r, running};
                8'h08: reg_read = {attempts_r, kappa_r};
                8'h0C: reg_read = {8'd0, pc_r, cerr_r, rerr_r};
                8'h10: reg_read = cycles_r;
                8'h14: reg_read = 32'h5743_5331;
                8'h18: reg_read = 32'h0002_0001;
                default: begin
                    if (a >= 8'h40 && a <= 8'h7C) reg_read = seed_rhoprime[(a-8'h40)*8 +: 32];
                    else if (a >= 8'h80 && a <= 8'h9C) reg_read = public_rho[(a-8'h80)*8 +: 32];
                end
            endcase
        end
    endfunction

    integer k;
    always @(posedge aclk) begin
        if (!aresetn) begin
            ast <= A_IDLE; aw_got <= 0; w_got <= 0;
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0; s_axi_bresp <= 0;
            s_axi_arready <= 0; s_axi_rvalid <= 0; s_axi_rresp <= 0; s_axi_rdata <= 0;
            h_rd_req_valid <= 0; h_rd_rsp_ready <= 0; h_rd_req_addr <= 0;
            ps_wr_valid <= 0; ps_wr_addr <= 0; ps_wr_data <= 0;
            running <= 0; launch_p <= 0; seed_rhoprime <= 0; public_rho <= 0; mode_r <= 0;
            done_r <= 0; success_r <= 0; irq_r <= 0; kappa_r <= 0; attempts_r <= 0;
            rerr_r <= 0; cerr_r <= 0; pc_r <= 0; cycles <= 0; cycles_r <= 0; mgr_done_q <= 0;
            for (k = 0; k < 4; k = k + 1) wlo[k] <= 32'd0;
            waddr <= 0; raddr <= 0; wdata_q <= 0; wstrb_q <= 0; bsel <= 0; hsel <= 0; wdog <= 0;
        end else begin
            launch_p   <= 1'b0;
            mgr_done_q <= mgr_done;
            if (running) cycles <= cycles + 1'b1;
            if (running && mgr_done && !mgr_done_q) begin       // job finished
                running    <= 1'b0;
                done_r     <= 1'b1;
                success_r  <= mgr_success;
                kappa_r    <= mgr_kappa;
                attempts_r <= mgr_attempts;
                rerr_r     <= mgr_error;
                cerr_r     <= error_code;
                pc_r       <= pc_status;
                cycles_r   <= cycles;
                irq_r      <= 1'b1;
                seed_rhoprime <= 512'd0;                        // secret seed cleared
            end

            case (ast)
                A_IDLE: begin
                    s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_arready <= 1'b0;
                    if (s_axi_awvalid || s_axi_wvalid) begin
                        if (s_axi_awvalid && !aw_got) begin
                            waddr <= s_axi_awaddr; aw_got <= 1'b1; s_axi_awready <= 1'b1;
                        end
                        if (s_axi_wvalid && !w_got) begin
                            wdata_q <= s_axi_wdata; wstrb_q <= s_axi_wstrb; w_got <= 1'b1;
                            s_axi_wready <= 1'b1;
                        end
                        ast <= A_WAITW;
                    end else if (s_axi_arvalid) begin
                        raddr <= s_axi_araddr; s_axi_arready <= 1'b1;
                        ast <= A_RD_REQ;
                    end
                end

                A_WAITW: begin
                    s_axi_awready <= 1'b0; s_axi_wready <= 1'b0;
                    if (s_axi_awvalid && !aw_got && !s_axi_awready) begin
                        waddr <= s_axi_awaddr; aw_got <= 1'b1; s_axi_awready <= 1'b1;
                    end
                    if (s_axi_wvalid && !w_got && !s_axi_wready) begin
                        wdata_q <= s_axi_wdata; wstrb_q <= s_axi_wstrb; w_got <= 1'b1;
                        s_axi_wready <= 1'b1;
                    end
                    if (aw_got && w_got) begin
                        aw_got <= 1'b0; w_got <= 1'b0;
                        s_axi_bresp <= 2'b00;
                        if (w_is_sp) begin
                            if (running || wstrb_q != 4'hF) begin
                                s_axi_bresp <= 2'b10; ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                            end else if (!waddr[2]) begin
                                wlo[waddr[15:14]] <= wdata_q;
                                ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                            end else begin
                                bsel <= waddr[15:14];
                                ps_wr_valid <= 4'b0001 << waddr[15:14];
                                ps_wr_addr  <= {4{waddr[13:3]}};
                                ps_wr_data  <= {4{wdata_q, wlo[waddr[15:14]]}};
                                wdog <= 16'hFFFF;
                                ast <= A_WR_SP;
                            end
                        end else begin
                            if (!w_reg_ok) s_axi_bresp <= 2'b10;
                            else case (w_reg)
                                8'h00: begin
                                    if (wdata_q[0] && !running && sp_init_done && !sp_locked) begin
                                        running <= 1'b1; launch_p <= 1'b1; done_r <= 1'b0; mode_r <= wdata_q[2];
                                        success_r <= 1'b0; irq_r <= 1'b0; cycles <= 32'd0;
                                    end else if (wdata_q[0]) s_axi_bresp <= 2'b10;
                                    if (wdata_q[1]) irq_r <= 1'b0;
                                end
                                default: begin
                                    if (w_reg >= 8'h40 && w_reg <= 8'h7C && !running)
                                        seed_rhoprime[(w_reg-8'h40)*8 +: 32] <= wdata_q;
                                    else if (w_reg >= 8'h80 && w_reg <= 8'h9C && !running)
                                        public_rho[(w_reg-8'h80)*8 +: 32] <= wdata_q;
                                    else s_axi_bresp <= 2'b10;
                                end
                            endcase
                            ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                        end
                    end
                end

                A_WR_SP: begin
                    if (|(ps_wr_valid & h_wr_req_ready)) begin
                        ps_wr_valid <= 4'b0000;
                        ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                    end else if (wdog == 0) begin
                        ps_wr_valid <= 4'b0000; s_axi_bresp <= 2'b10;
                        ast <= A_WR_RESP; s_axi_bvalid <= 1'b1;
                    end else wdog <= wdog - 1'b1;
                end

                A_WR_RESP: begin
                    if (s_axi_bvalid && s_axi_bready) begin s_axi_bvalid <= 1'b0; ast <= A_IDLE; end
                end

                A_RD_REQ: begin
                    s_axi_arready <= 1'b0;
                    s_axi_rresp <= 2'b00;
                    if (r_is_sp) begin
                        if (running) begin
                            s_axi_rresp <= 2'b10; s_axi_rdata <= 32'd0;
                            s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                        end else begin
                            bsel <= raddr[15:14]; hsel <= raddr[2];
                            h_rd_req_valid <= 4'b0001 << raddr[15:14];
                            h_rd_req_addr  <= {4{raddr[13:3]}};
                            wdog <= 16'hFFFF;
                            ast <= A_RD_RSP;
                        end
                    end else begin
                        if (!r_reg_ok) s_axi_rresp <= 2'b10;
                        s_axi_rdata  <= r_reg_ok ? reg_read(r_reg) : 32'd0;
                        s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                    end
                end

                A_RD_RSP: begin
                    if (|(h_rd_req_valid & h_rd_req_ready)) begin
                        h_rd_req_valid <= 4'b0000;
                        h_rd_rsp_ready <= 4'b0001 << bsel;
                    end
                    if (|(h_rd_rsp_ready & h_rd_rsp_valid)) begin
                        h_rd_rsp_ready <= 4'b0000;
                        s_axi_rdata  <= hsel ? h_rd_rsp_data[bsel*64+32 +: 32] : h_rd_rsp_data[bsel*64 +: 32];
                        s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                    end else if (wdog == 0) begin
                        h_rd_req_valid <= 4'b0000; h_rd_rsp_ready <= 4'b0000;
                        s_axi_rresp <= 2'b10; s_axi_rdata <= 32'd0;
                        s_axi_rvalid <= 1'b1; ast <= A_RD_RESP;
                    end else wdog <= wdog - 1'b1;
                end

                A_RD_RESP: begin
                    if (s_axi_rvalid && s_axi_rready) begin s_axi_rvalid <= 1'b0; ast <= A_IDLE; end
                end

                default: ast <= A_IDLE;
            endcase
        end
    end
endmodule
