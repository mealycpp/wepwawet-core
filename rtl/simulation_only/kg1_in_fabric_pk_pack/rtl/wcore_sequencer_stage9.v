`timescale 1ns / 1ps
// STAGE9 AUX DISPATCH TEST CANDIDATE - NOT FIPS 204 SIGN/VERIFY.
// Candidate is named separately; NEVER replace verified Stage8 in-place.
// WEPWAWET-CORE ROM-driven microsequencer (integration candidate)
// Verilog-2005. No fabricated HLS register offsets.
// Production: connect rom_data to immutable, synchronous 64-bit ROM.
// CFG executor, DMA engine, scalar-write arbiter and aux kernels are external.
// All request/response inputs must be synchronous to clk.
// Trusted por_n is not a software-controlled reset.

module wcore_sequencer_stage9 #(
    parameter integer ADDR_W = 11,
    parameter integer CFG_TIMEOUT = 1024,
    parameter integer KERNEL_TIMEOUT = 200000,
    parameter integer DMA_TIMEOUT = 200000,
    parameter integer AUX_TIMEOUT = 200000,
    parameter integer SCRUB_TIMEOUT = 8192,
    parameter integer ATTEMPT_BOUND = 814,
    parameter integer ENFORCE_BOUND = 1
)(
    input wire clk,
    input wire por_n,
    input wire start_job,
    // verify_v1: ROM entry point latched at START (0 = SIGN, 150 = VERIFY).
    input wire [8:0] start_pc,   // keygen: 9-bit ROM/PC (512 slots)
    input wire job_ack,
    input wire soft_reset_req,
    output wire job_busy,
    output wire job_done,
    output wire job_error,
    output wire job_locked,
    output wire job_irq,
    output reg [7:0] error_code,
    output wire [15:0] kappa_status,
    output wire [15:0] attempt_status,
    output wire reject_status,
    output wire [8:0] pc_status,

    // One-cycle synchronous ROM. rom_data must be valid after one clock
    // with rom_addr stable. ROM is immutable in production.
    output reg [8:0] rom_addr,
    input wire [63:0] rom_data,

    // Trusted configuration table. cfg_meta is synchronous (1 clock).
    // The CFG executor performs map-specific AXI-Lite transactions.
    output reg [6:0] cfg_index,
    output reg [2:0] cfg_lane,
    output reg cfg_phase,       // 0: configure, 1: ap_start
    input wire [7:0] cfg_meta, // bit0 skip_start, bit1 tx_only,
                                // bit2 aux_route, bit4 require_kernel_idle
    output wire cfg_valid,
    input wire cfg_ready,
    input wire cfg_done,
    input wire cfg_error,

    // AXIS adapter commands, identical widths to existing adapter.
    output wire tx_cmd_valid,
    input wire tx_cmd_ready,
    output reg [1:0] tx_cmd_bank,
    output reg [ADDR_W-1:0] tx_cmd_addr,
    output reg [ADDR_W:0] tx_cmd_words,
    input wire tx_done,
    output wire tx_done_ack,
    output wire rx_cmd_valid,
    input wire rx_cmd_ready,
    output reg [1:0] rx_cmd_bank,
    output reg [ADDR_W-1:0] rx_cmd_addr,
    output reg [ADDR_W:0] rx_cmd_words,
    input wire rx_done,
    output wire rx_done_ack,
    input wire adapter_recovery_required,
    output wire recover_ack,

    // Route selection for external distributor/collector and DMA muxes.
    output wire route_enable,
    output wire [2:0] route_lane,
    output wire route_aux,
    output wire route_dma_load,
    output wire route_dma_store,
    input wire kernel_idle,
    input wire aux_reject_set,

    // New FPGA-only AUX datapath handshake; never CPU-executed.
    output wire aux_valid,
    input wire aux_ready,
    output reg [7:0] aux_op,
    output reg [1:0] aux_src_bank,
    output reg [1:0] aux_dst_bank,
    output reg [ADDR_W-1:0] aux_src_addr,
    output reg [ADDR_W-1:0] aux_dst_addr,
    output reg [ADDR_W:0] aux_words,
    input wire aux_done,
    input wire aux_error,

    // External DMA executor, with trusted CFG for 64-bit DDR address.
    output wire dma_valid,
    input wire dma_ready,
    output reg dma_store,
    output reg [1:0] dma_bank,
    output reg [ADDR_W-1:0] dma_addr,
    output reg [ADDR_W:0] dma_words,
    output reg [6:0] dma_cfg_index,
    input wire dma_authorized,
    input wire dma_done,
    input wire dma_error,

    // Scalar write to scratchpad through an external write arbiter.
    output wire scalar_valid,
    input wire scalar_ready,
    output reg [1:0] scalar_bank,
    output reg [ADDR_W-1:0] scalar_addr,
    output reg [63:0] scalar_data,

    // Scratchpad and secure recovery.
    input wire sp_busy,
    input wire sp_abort,
    input wire sp_scrub_done,
    input wire sp_fault_latched,
    input wire sp_locked,
    output wire sp_scrub_req,
    output wire kernel_reset_n
);
    localparam [3:0]
        OP_KERNEL=4'h0, OP_LOAD=4'h1, OP_STORE=4'h2,
        OP_BRANCH=4'h3, OP_INC=4'h4, OP_SET=4'h5,
        OP_WRITE_REG=4'h6, OP_HALT=4'h7, OP_AUX=4'h8;
    localparam [2:0] REG_KAPPA=0, REG_ATTEMPT=1, REG_FLAGS=2;
    localparam [2:0] COND_ALWAYS=0, COND_REJECT=1, COND_LIMIT=2;
    localparam [7:0]
        E_NONE=8'h00, E_OPCODE=8'h01, E_DESCRIPTOR=8'h02,
        E_CFG=8'h03, E_CFG_TIMEOUT=8'h04, E_KERNEL=8'h05,
        E_DMA=8'h06, E_DMA_TIMEOUT=8'h07, E_ABORT=8'h08,
        E_FAULT=8'h09, E_BOUND=8'h0A, E_NONCE=8'h0B,
        E_SCRUB_TIMEOUT=8'h0C, E_AUX=8'h0D,
        E_AUX_TIMEOUT=8'h0E;

    localparam [5:0]
        ST_IDLE=0, ST_FETCH_REQ=1, ST_FETCH_WAIT=2,
        ST_FETCH_LATCH=3, ST_DECODE=4,
        ST_CFG_ADDR=5, ST_CFG_WAIT_META=6, ST_CFG_LATCH=7,
        ST_CFG_REQ=8, ST_CFG_WAIT=9, ST_ARM_RX=10,
        ST_START_REQ=11, ST_START_WAIT=12, ST_ARM_TX=13,
        ST_KERNEL_WAIT=14, ST_KERNEL_ACK=15,
        ST_DMA_REQ=16, ST_DMA_WAIT=17, ST_SCALAR_REQ=18,
        ST_JOB_DONE=19, ST_REC_ASSERT=20, ST_REC_SCRUB=21,
        ST_REC_WAIT=22, ST_REC_CHECK=23, ST_REC_ACK=24,
        ST_REPORT_ERROR=25, ST_LOCKED=26, ST_DMA_AUTH_WAIT=27,
        ST_AUX_REQ=28, ST_AUX_WAIT=29;

    (* fsm_encoding = "none" *) reg [5:0] state;
    reg [8:0] pc;
    reg [63:0] instr;
    reg [15:0] kappa;
    reg [15:0] attempts;
    reg reject_flag;
    reg [7:0] meta_latched;
    reg [31:0] watchdog;
    reg [2:0] active_lane;

    wire [3:0] opcode = instr[63:60];
    wire [2:0] reg_id = instr[59:57];
    wire [15:0] imm16 = instr[56:41];
    wire [16:0] kappa_result = (opcode == OP_INC) ?
        ({1'b0,kappa} + {1'b0,imm16}) : {1'b0,imm16};
    wire [15:0] nonce1 = kappa + 16'd1;
    wire [15:0] nonce2 = kappa + 16'd2;
    wire [15:0] nonce3 = kappa + 16'd3;
    wire [2:0] condition = instr[59:57];
    // keygen: 9-bit BRANCH target = {instr[48], instr[56:49]}: the v7/v8 8-bit field [56:49] is unchanged and the
    // new MSB is the former zero bit 48, so every existing BRANCH encoding decodes to the same target.
    wire [8:0] branch_target = {instr[48], instr[56:49]};
    wire [ADDR_W+1:0] tx_end = {2'b00, instr[52:42]} + {1'b0, instr[30:19]};
    wire [ADDR_W+1:0] rx_end = {2'b00, instr[41:31]} + {1'b0, instr[18:7]};
    wire [ADDR_W+1:0] dma_end = {2'b00, instr[57:47]} + {1'b0, instr[46:35]};
    wire bad_kernel = (instr[59:57] > 3'd5) ||
         ((instr[30:19] == 0) && (instr[18:7] == 0)) ||
         ((instr[30:19] != 0) && (tx_end > (1 << ADDR_W))) ||
         ((instr[18:7] != 0) && (rx_end > (1 << ADDR_W)));
    wire bad_dma = (instr[46:35] == 0) || (dma_end > (1 << ADDR_W));

    // AUX: [63:60]=8 [59:52]=op [51:50]=src bank
    // [49:48]=dst bank [47:37]=src offset [36:26]=dst offset
    // [25:14]=words [13:0]=zero, 64-bit scratchpad words.
    wire [ADDR_W+1:0] aux_src_end =
        {2'b00,instr[47:37]} + {1'b0,instr[25:14]};
    wire [ADDR_W+1:0] aux_dst_end =
        {2'b00,instr[36:26]} + {1'b0,instr[25:14]};
    wire bad_aux = (instr[25:14] == 0) || (instr[13:0] != 0) ||
                   (aux_src_end > (1 << ADDR_W)) ||
                   (aux_dst_end > (1 << ADDR_W));
    wire execution_state = ((state >= ST_FETCH_REQ && state <= ST_SCALAR_REQ) ||
                            (state == ST_DMA_AUTH_WAIT) ||
                            (state == ST_AUX_REQ) || (state == ST_AUX_WAIT));
    wire in_recovery = (state >= ST_REC_ASSERT && state <= ST_REC_ACK);
    wire fault_now = sp_fault_latched || sp_locked;
    wire abort_now = sp_abort || soft_reset_req || adapter_recovery_required;

    assign job_busy = execution_state || in_recovery;
    assign job_done = (state == ST_JOB_DONE);
    assign job_error = (state == ST_REPORT_ERROR) || (state == ST_LOCKED);
    assign job_locked = (state == ST_LOCKED);
    assign job_irq = job_done || job_error;
    assign kappa_status = kappa;
    assign attempt_status = attempts;
    assign reject_status = reject_flag;
    assign pc_status = pc;

    assign cfg_valid = (state == ST_CFG_REQ) || (state == ST_START_REQ);
    assign tx_cmd_valid = (state == ST_ARM_TX) && (tx_cmd_words != 0);
    assign rx_cmd_valid = (state == ST_ARM_RX) && (rx_cmd_words != 0);
    assign tx_done_ack = (state == ST_KERNEL_ACK);
    assign rx_done_ack = (state == ST_KERNEL_ACK);
    assign dma_valid = (state == ST_DMA_REQ) && dma_authorized;
    assign scalar_valid = (state == ST_SCALAR_REQ);
    assign aux_valid = (state == ST_AUX_REQ) && !fault_now && !abort_now;
    assign recover_ack = (state == ST_REC_ACK);
    assign sp_scrub_req = (state == ST_REC_SCRUB);
    assign kernel_reset_n = !in_recovery && (state != ST_LOCKED);

    assign route_enable = (state == ST_ARM_RX) ||
                          (state == ST_START_REQ) ||
                          (state == ST_START_WAIT) ||
                          (state == ST_ARM_TX) ||
                          (state == ST_KERNEL_WAIT) ||
                          (state == ST_KERNEL_ACK);
    assign route_lane = active_lane;
    assign route_aux = (active_lane == 3'd5) || meta_latched[2];
    assign route_dma_load = (state == ST_DMA_REQ || state == ST_DMA_WAIT) && !dma_store;
    assign route_dma_store = (state == ST_DMA_REQ || state == ST_DMA_WAIT) && dma_store;

    always @(posedge clk or negedge por_n) begin
        if (!por_n) begin
            state <= ST_IDLE;
            pc <= 0;
            rom_addr <= 0;
            instr <= 0;
            kappa <= 0;
            attempts <= 0;
            reject_flag <= 0;
            error_code <= E_NONE;
            watchdog <= 0;
            active_lane <= 0;
            cfg_index <= 0;
            cfg_lane <= 0;
            cfg_phase <= 0;
            meta_latched <= 0;
            tx_cmd_bank <= 0; tx_cmd_addr <= 0; tx_cmd_words <= 0;
            rx_cmd_bank <= 0; rx_cmd_addr <= 0; rx_cmd_words <= 0;
            dma_store <= 0; dma_bank <= 0; dma_addr <= 0;
            dma_words <= 0; dma_cfg_index <= 0;
            scalar_bank <= 0; scalar_addr <= 0; scalar_data <= 0;
            aux_op <= 0; aux_src_bank <= 0; aux_dst_bank <= 0;
            aux_src_addr <= 0; aux_dst_addr <= 0; aux_words <= 0;
        end else begin
            // Auxiliary rejection is sticky until the ROM clears FLAGS.
            if (aux_reject_set && execution_state)
                reject_flag <= 1'b1;

            // Fault and abort priority applies to every execution state,
            // including CONFIGURE. Recovery ignores scrub-generated abort.
            if (execution_state && fault_now) begin
                error_code <= E_FAULT;
                state <= ST_REC_ASSERT;
                watchdog <= 0;
            end else if (execution_state && abort_now) begin
                error_code <= E_ABORT;
                state <= ST_REC_ASSERT;
                watchdog <= 0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (sp_locked) begin
                            error_code <= E_FAULT;
                            state <= ST_LOCKED;
                        end else if (sp_fault_latched) begin
                            error_code <= E_FAULT;
                            state <= ST_REC_ASSERT;
                        end else if (start_job && !sp_busy && !sp_abort) begin
                            pc <= start_pc;
                            kappa <= 0;
                            attempts <= 0;
                            reject_flag <= 0;
                            error_code <= E_NONE;
                            state <= ST_FETCH_REQ;
                        end
                    end
                    ST_FETCH_REQ: begin
                        rom_addr <= pc;
                        state <= ST_FETCH_WAIT;
                    end
                    ST_FETCH_WAIT: state <= ST_FETCH_LATCH;
                    ST_FETCH_LATCH: begin
                        instr <= rom_data;
                        state <= ST_DECODE;
                    end
                    ST_DECODE: begin
                        case (opcode)
                            OP_KERNEL: begin
                                if (bad_kernel) begin
                                    error_code <= E_DESCRIPTOR;
                                    state <= ST_REC_ASSERT;
                                end else begin
                                    active_lane <= instr[59:57];
                                    cfg_lane <= instr[59:57];
                                    cfg_index <= instr[6:0];
                                    cfg_phase <= 1'b0;
                                    tx_cmd_bank <= instr[56:55];
                                    rx_cmd_bank <= instr[54:53];
                                    tx_cmd_addr <= instr[52:42];
                                    rx_cmd_addr <= instr[41:31];
                                    tx_cmd_words <= instr[30:19];
                                    rx_cmd_words <= instr[18:7];
                                    state <= ST_CFG_ADDR;
                                end
                            end
                            OP_LOAD, OP_STORE: begin
                                if (bad_dma) begin
                                    error_code <= E_DESCRIPTOR;
                                    state <= ST_REC_ASSERT;
                                end else begin
                                    dma_store <= (opcode == OP_STORE);
                                    dma_bank <= instr[59:58];
                                    dma_addr <= instr[57:47];
                                    dma_words <= instr[46:35];
                                    dma_cfg_index <= instr[34:28];
                                    watchdog <= 0;
                                    state <= ST_DMA_AUTH_WAIT;
                                end
                            end
                            OP_BRANCH: begin
                                if (condition == COND_ALWAYS ||
                                    (condition == COND_REJECT && reject_flag)) begin
                                    pc <= branch_target;
                                    state <= ST_FETCH_REQ;
                                end else if (condition == COND_LIMIT &&
                                             ENFORCE_BOUND != 0 &&
                                             attempts >= ATTEMPT_BOUND) begin
                                    error_code <= E_BOUND;
                                    state <= ST_REC_ASSERT;
                                end else if (condition == COND_REJECT ||
                                             condition == COND_LIMIT) begin
                                    pc <= pc + 1'b1;
                                    state <= ST_FETCH_REQ;
                                end else begin
                                    error_code <= E_OPCODE;
                                    state <= ST_REC_ASSERT;
                                end
                            end
                            OP_INC, OP_SET: begin
                                case (reg_id)
                                    REG_KAPPA: begin
                                        if (kappa_result > 17'd65532) begin
                                            error_code <= E_NONCE;
                                            state <= ST_REC_ASSERT;
                                        end else begin
                                            kappa <= kappa_result[15:0];
                                            pc <= pc + 1'b1;
                                            state <= ST_FETCH_REQ;
                                        end
                                    end
                                    REG_ATTEMPT: begin
                                        attempts <= (opcode == OP_INC) ?
                                            attempts + imm16 : imm16;
                                        pc <= pc + 1'b1;
                                        state <= ST_FETCH_REQ;
                                    end
                                    REG_FLAGS: begin
                                        if (opcode == OP_SET) begin
                                            reject_flag <= imm16[0];
                                            pc <= pc + 1'b1;
                                            state <= ST_FETCH_REQ;
                                        end else begin
                                            error_code <= E_OPCODE;
                                            state <= ST_REC_ASSERT;
                                        end
                                    end
                                    default: begin
                                        error_code <= E_OPCODE;
                                        state <= ST_REC_ASSERT;
                                    end
                                endcase
                            end
                            OP_WRITE_REG: begin
                                watchdog <= 0;
                                scalar_bank <= instr[56:55];
                                scalar_addr <= instr[54:44];
                                case (reg_id)
                                    REG_KAPPA: begin
                                        scalar_data <= {nonce3,nonce2,nonce1,kappa};
                                        state <= ST_SCALAR_REQ;
                                    end
                                    REG_ATTEMPT: begin
                                        scalar_data <= {48'd0,attempts};
                                        state <= ST_SCALAR_REQ;
                                    end
                                    REG_FLAGS: begin
                                        scalar_data <= {63'd0,reject_flag};
                                        state <= ST_SCALAR_REQ;
                                    end
                                    default: begin
                                        error_code <= E_OPCODE;
                                        state <= ST_REC_ASSERT;
                                    end
                                endcase
                            end
                            OP_AUX: begin
                                if (bad_aux) begin
                                    error_code <= E_DESCRIPTOR;
                                    state <= ST_REC_ASSERT;
                                end else begin
                                    aux_op <= instr[59:52];
                                    aux_src_bank <= instr[51:50];
                                    aux_dst_bank <= instr[49:48];
                                    aux_src_addr <= instr[47:37];
                                    aux_dst_addr <= instr[36:26];
                                    aux_words <= instr[25:14];
                                    watchdog <= 0;
                                    state <= ST_AUX_REQ;
                                end
                            end
                            OP_HALT: state <= ST_JOB_DONE;
                            default: begin
                                error_code <= E_OPCODE;
                                state <= ST_REC_ASSERT;
                            end
                        endcase
                    end
                    // Synchronous trusted CFG metadata lookup.
                    ST_CFG_ADDR: state <= ST_CFG_WAIT_META;
                    ST_CFG_WAIT_META: state <= ST_CFG_LATCH;
                    ST_CFG_LATCH: begin
                        meta_latched <= cfg_meta;
                        if (cfg_meta[1] && (rx_cmd_words != 0)) begin
                            error_code <= E_DESCRIPTOR;
                            state <= ST_REC_ASSERT;
                        end else begin
                            watchdog <= 0;
                            state <= ST_CFG_REQ;
                        end
                    end
                    ST_CFG_REQ: begin
                        if (cfg_ready) begin
                            watchdog <= 0;
                            state <= ST_CFG_WAIT;
                        end else if (watchdog >= CFG_TIMEOUT-1) begin
                            error_code <= E_CFG_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_CFG_WAIT: begin
                        if (cfg_error) begin
                            error_code <= E_CFG;
                            state <= ST_REC_ASSERT;
                        end else if (cfg_done) begin
                            watchdog <= 0;
                            state <= ST_ARM_RX;
                        end else if (watchdog >= CFG_TIMEOUT-1) begin
                            error_code <= E_CFG_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_ARM_RX: begin
                        if (rx_cmd_words == 0 || rx_cmd_ready) begin
                            cfg_phase <= 1'b1;
                            watchdog <= 0;
                            if (meta_latched[0]) state <= ST_ARM_TX;
                            else state <= ST_START_REQ;
                        end else if (watchdog >= CFG_TIMEOUT-1) begin
                            error_code <= E_KERNEL;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_START_REQ: begin
                        if (cfg_ready) begin
                            watchdog <= 0;
                            state <= ST_START_WAIT;
                        end else if (watchdog >= CFG_TIMEOUT-1) begin
                            error_code <= E_CFG_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_START_WAIT: begin
                        if (cfg_error) begin
                            error_code <= E_CFG;
                            state <= ST_REC_ASSERT;
                        end else if (cfg_done) begin
                            watchdog <= 0;
                            state <= ST_ARM_TX;
                        end else if (watchdog >= CFG_TIMEOUT-1) begin
                            error_code <= E_CFG_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_ARM_TX: begin
                        if (tx_cmd_words == 0 || tx_cmd_ready) begin
                            watchdog <= 0;
                            state <= ST_KERNEL_WAIT;
                        end else if (watchdog >= CFG_TIMEOUT-1) begin
                            error_code <= E_KERNEL;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_KERNEL_WAIT: begin
                        if ((tx_cmd_words == 0 || tx_done) &&
                            (rx_cmd_words == 0 || rx_done) &&
                            (!meta_latched[4] || kernel_idle)) begin
                            state <= ST_KERNEL_ACK;
                        end else if (watchdog >= KERNEL_TIMEOUT-1) begin
                            error_code <= E_KERNEL;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_KERNEL_ACK: begin
                        pc <= pc + 1'b1;
                        state <= ST_FETCH_REQ;
                    end
                    // Allow a synchronous trusted DMA-CFG lookup to settle.
                    ST_DMA_AUTH_WAIT: state <= ST_DMA_REQ;
                    ST_DMA_REQ: begin
                        if (!dma_authorized) begin
                            error_code <= E_DMA;
                            state <= ST_REC_ASSERT;
                        end else if (dma_ready) begin
                            watchdog <= 0;
                            state <= ST_DMA_WAIT;
                        end else if (watchdog >= DMA_TIMEOUT-1) begin
                            error_code <= E_DMA_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_DMA_WAIT: begin
                        if (dma_error) begin
                            error_code <= E_DMA;
                            state <= ST_REC_ASSERT;
                        end else if (dma_done) begin
                            pc <= pc + 1'b1;
                            state <= ST_FETCH_REQ;
                        end else if (watchdog >= DMA_TIMEOUT-1) begin
                            error_code <= E_DMA_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_SCALAR_REQ: begin
                        if (scalar_ready) begin
                            pc <= pc + 1'b1;
                            state <= ST_FETCH_REQ;
                        end else if (watchdog >= CFG_TIMEOUT-1) begin
                            error_code <= E_CFG_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_AUX_REQ: begin
                        if (aux_ready) begin
                            watchdog <= 0;
                            state <= ST_AUX_WAIT;
                        end else if (watchdog >= AUX_TIMEOUT-1) begin
                            error_code <= E_AUX_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_AUX_WAIT: begin
                        if (aux_error) begin
                            error_code <= E_AUX;
                            state <= ST_REC_ASSERT;
                        end else if (aux_done) begin
                            pc <= pc + 1'b1;
                            watchdog <= 0;
                            state <= ST_FETCH_REQ;
                        end else if (watchdog >= AUX_TIMEOUT-1) begin
                            error_code <= E_AUX_TIMEOUT;
                            state <= ST_REC_ASSERT;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_JOB_DONE: begin
                        if (sp_fault_latched || sp_locked) begin
                            error_code <= E_FAULT;
                            state <= ST_REC_ASSERT;
                        end else if (sp_abort || soft_reset_req) begin
                            error_code <= E_ABORT;
                            state <= ST_REC_ASSERT;
                        end else if (job_ack) state <= ST_IDLE;
                    end
                    // Abort from every operational state enters here.
                    ST_REC_ASSERT: begin
                        watchdog <= 0;
                        state <= ST_REC_SCRUB;
                    end
                    ST_REC_SCRUB: begin
                        watchdog <= 0;
                        state <= ST_REC_WAIT;
                    end
                    ST_REC_WAIT: begin
                        if (sp_locked || sp_scrub_done) begin
                            state <= ST_REC_CHECK;
                        end else if (watchdog >= SCRUB_TIMEOUT-1) begin
                            error_code <= E_SCRUB_TIMEOUT;
                            state <= ST_LOCKED;
                        end else watchdog <= watchdog + 1'b1;
                    end
                    ST_REC_CHECK: begin
                        if (sp_fault_latched || sp_locked)
                            state <= ST_LOCKED;
                        else
                            state <= ST_REC_ACK;
                    end
                    ST_REC_ACK: state <= ST_REPORT_ERROR;
                    ST_REPORT_ERROR: begin
                        if (sp_locked) state <= ST_LOCKED;
                        else if (job_ack) state <= ST_IDLE;
                    end
                    ST_LOCKED: state <= ST_LOCKED;
                    default: begin
                        error_code <= E_OPCODE;
                        state <= ST_REC_ASSERT;
                    end
                endcase
            end
        end
    end
endmodule
