`timescale 1ns/1ps
// WEPWAWET: generalized REGISTERED retry policy overlay for the frozen V7 core.
// sign_v4: 16-bit attempt counter so the FIPS 204 Appendix C minimum bound (814) is representable.
// Inputs/outputs are the existing SIMULATION-ONLY WCORE test-harness ABI.
// This is NOT a production scratchpad port, secure key vault or FPGA bitstream.
// NO frozen V7 files are modified. V7 controller/seed/scratchpad integration
// will require separate board-level timing and security validation.
module v7_registered_retry_manager #(
    parameter integer MAX_ATTEMPTS = 814, // FIPS 204 App. C: a bound, if any, must be >= 814
    parameter integer WAIT_TIMEOUT_CYCLES = 1000000  // per run / idle / write handshake
) (
    input wire clk, input wire rst_n, input wire launch,
    input wire verify_mode,   // verify_v1: single pass, no retry; OK at PC234, z-reject at PC235
    input wire [511:0] seed_rhoprime,
    input wire [255:0] public_rho,
    input wire job_done, input wire job_error, input wire job_busy,
    input wire reject_status, input wire [7:0] pc_status,
    input wire sp_busy, input wire sp_locked,
    input wire [3:0] wr_ready,
    output reg start_job, output reg job_ack, output reg host_mode,
    output reg [3:0] wr_valid,
    output reg [43:0] wr_addr,
    output reg [255:0] wr_data,
    output reg done, output reg success,
    output reg [15:0] kappa, output reg [15:0] attempts,
    output reg [7:0] error_code
);
    // Errors: 01=core/locked, 02=invalid core PC/status,
    // 03=retry exhausted, 04=handshake watchdog, 05=kappa overflow.
    localparam [3:0] S_IDLE=0,S_START=1,S_RUN=2,S_ACK_REJ=3,
      S_WAIT_IDLE=4,S_PREP_WRITE=5,S_WAIT_WRITE=6,S_NEXT_START=7,
      S_ACK_OK=8,S_WAIT_OK=9,S_FINISH=10,S_FAIL=11,
      S_ACK_EXHAUST=12,S_WAIT_EXHAUST=13;
    localparam integer WATCHDOG_BITS = (WAIT_TIMEOUT_CYCLES < 2) ? 1 : $clog2(WAIT_TIMEOUT_CYCLES+1);
    reg [3:0] state;
    reg [WATCHDOG_BITS-1:0] watchdog;
    reg [5:0] word_idx;       // 0..35 mask seed/nonce; 36..39 public rho
    reg [3:0] word_in_poly;   // eight seed words, then nonce
    reg [1:0] poly_idx;
    reg [511:0] seed_rotate;
    reg [255:0] rho_rotate;
    reg [15:0] next_kappa;

`ifndef SYNTHESIS
    initial begin
        if (MAX_ATTEMPTS<1 || MAX_ATTEMPTS>16384)
            $fatal(1,"RETRY_BAD_MAX_ATTEMPTS=%0d",MAX_ATTEMPTS);
        if (WAIT_TIMEOUT_CYCLES<2)
            $fatal(1,"RETRY_BAD_WATCHDOG=%0d",WAIT_TIMEOUT_CYCLES);
    end
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; watchdog<=0;
            start_job<=0; job_ack<=0; host_mode<=1;
            wr_valid<=0; wr_addr<=0; wr_data<=0;
            done<=0; success<=0; kappa<=0; attempts<=0;
            seed_rotate<=0; rho_rotate<=0; next_kappa<=0;
            word_idx<=0; word_in_poly<=0; poly_idx<=0;
            error_code<=0;
        end else begin
            // Watchdog is local to the overlay; never drives WCORE combinationally.
            if (state==S_RUN || state==S_WAIT_IDLE || state==S_WAIT_WRITE ||
                state==S_WAIT_OK || state==S_WAIT_EXHAUST) begin
                if (watchdog < WAIT_TIMEOUT_CYCLES)
                    watchdog<=watchdog+1'b1;
            end else begin
                watchdog<=0;
            end
            if ((state==S_RUN || state==S_WAIT_IDLE || state==S_WAIT_WRITE ||
                 state==S_WAIT_OK || state==S_WAIT_EXHAUST) &&
                 watchdog >= WAIT_TIMEOUT_CYCLES-1) begin
                error_code<=8'h04;
                state<=S_FAIL;
            end else begin
                case(state)
                S_IDLE: if (launch) begin
                    done<=0; success<=0; kappa<=0; attempts<=0;
                    error_code<=0; host_mode<=0;
                    start_job<=0; job_ack<=0; wr_valid<=0;
                    seed_rotate<=seed_rhoprime;
                    rho_rotate<=public_rho;
                    state<=S_START;
                end
                S_START: begin
                    start_job<=1;
                    state<=S_RUN;
                end
                S_RUN: begin
                    start_job<=0;
                    if (job_error || sp_locked) begin
                        error_code<=8'h01;
                        state<=S_FAIL;
                    end else if (job_done) begin
                        attempts<=attempts+16'd1;
                        if (verify_mode) begin
                            if (!reject_status && pc_status==8'd234) state<=S_ACK_OK;
                            else if (reject_status && pc_status==8'd235) begin
                                error_code<=8'h06;          // verify: ||z|| >= gamma1-beta
                                state<=S_ACK_EXHAUST;
                            end else begin
                                error_code<=8'h02; state<=S_FAIL;
                            end
                        end else if (!reject_status && pc_status==8'd146) begin
                            state<=S_ACK_OK;
                        end else if (reject_status && pc_status==8'd148) begin
                            if (attempts >= MAX_ATTEMPTS-1) begin
                                error_code<=8'h03;
                                state<=S_ACK_EXHAUST;
                            end else if (kappa > 16'hfffb) begin
                                error_code<=8'h05;
                                state<=S_FAIL;
                            end else begin
                                next_kappa<=kappa+16'd4;
                                state<=S_ACK_REJ;
                            end
                        end else begin
                            error_code<=8'h02;
                            state<=S_FAIL;
                        end
                    end
                end
                S_ACK_REJ: begin
                    job_ack<=1;
                    state<=S_WAIT_IDLE;
                end
                S_WAIT_IDLE: begin
                    job_ack<=0;
                    if (!job_done && !job_busy && !sp_busy) begin
                        host_mode<=1;
                        kappa<=next_kappa;
                        word_idx<=0;
                        word_in_poly<=0;
                        poly_idx<=0;
                        state<=S_PREP_WRITE;
                    end
                end
                S_PREP_WRITE: begin
                    // Registered write boundary: 40 words, *not* 40-wide mux.
                    // Rewrite entire mask seed+nonce region and public rho.
                    // Both regions are overwritten by V7 during each attempt.
                    if (word_idx>=6'd36) begin
                        wr_addr[2*11+:11]<=11'd512+{9'd0,word_idx[1:0]};
                        wr_data[2*64+:64]<=rho_rotate[63:0];
                    end else begin
                        wr_addr[2*11+:11]<={5'd0,word_idx};
                        if (word_in_poly==4'd8)
                            wr_data[2*64+:64]<={48'd0,(next_kappa+{14'd0,poly_idx})};
                        else
                            wr_data[2*64+:64]<=seed_rotate[63:0];
                    end
                    wr_valid[2]<=1'b1;
                    state<=S_WAIT_WRITE;
                end
                S_WAIT_WRITE: if (wr_ready[2]) begin
                    wr_valid[2]<=0;
                    if (word_idx>=6'd36)
                        rho_rotate<={rho_rotate[63:0],rho_rotate[255:64]};
                    else if (word_in_poly==4'd8) begin
                        word_in_poly<=0;
                        poly_idx<=poly_idx+1'b1;
                    end else begin
                        word_in_poly<=word_in_poly+1'b1;
                        seed_rotate<={seed_rotate[63:0],seed_rotate[511:64]};
                    end
                    if (word_idx==6'd39)
                        state<=S_NEXT_START;
                    else begin
                        word_idx<=word_idx+1'b1;
                        state<=S_PREP_WRITE;
                    end
                end
                S_NEXT_START: begin
                    host_mode<=0;
                    state<=S_START;
                end
                S_ACK_OK: begin
                    job_ack<=1;
                    state<=S_WAIT_OK;
                end
                S_WAIT_OK: begin
                    job_ack<=0;
                    if (!job_done && !job_busy && !sp_busy) begin
                        host_mode<=1;
                        success<=1;
                        done<=1;
                        state<=S_FINISH;
                    end
                end
                S_ACK_EXHAUST: begin
                    job_ack<=1;
                    state<=S_WAIT_EXHAUST;
                end
                S_WAIT_EXHAUST: begin
                    job_ack<=0;
                    if (!job_done && !job_busy && !sp_busy) begin
                        host_mode<=1;
                        success<=0;
                        done<=1;
                        state<=S_FINISH;
                    end
                end
                S_FAIL: begin
                    wr_valid<=0; start_job<=0; job_ack<=0;
                    done<=1; success<=0;
                    state<=S_FINISH;
                end
                S_FINISH: begin
                    // Clear local seed registers after completion. This is not
                    // a complete zeroization of the V7 scratchpad or HLS RAM.
                    seed_rotate<=0; rho_rotate<=0;
                    if (!launch) state<=S_IDLE;
                end
                default: begin error_code<=8'hff; state<=S_FAIL; end
                endcase
            end
        end
    end
endmodule
