`timescale 1ns / 1ps

// WEPWAWET-CORE AXI4-STREAM ADAPTER  -- rev B
//
// Rev B (on top of the rev A 64-bit two-FSM design):
//   1. A bad descriptor is a LOCAL error: it stops only its own engine.
//      Both engines stop on abort_in, on either engine's ABORT, or on an
//      RX framing error (the kernel stream is then untrustworthy).
//   2. TX/RX local FIFOs are zeroed while an engine sits in ERROR or ABORT,
//      so no polynomial data survives a fault inside the adapter.
//   3. fsm_encoding="none" on both state registers so Vivado keeps the
//      illegal-state -> ERROR recovery path.
//
// ASSUMPTION TO VERIFY: one 64-bit beat = one 64-bit scratchpad word
// (two packed coefficients). If the HLS kernels carry one coefficient per
// 64-bit beat, this adapter needs a split/merge stage.
//
// One TX: Scratchpad -> AXIS distributor
// One RX: AXIS collector -> Scratchpad
//
// 64-bit full-word transfers.
// 4 scratchpad banks, 2048 words per bank.
// Target: 333 MHz; timing not yet verified.
//
// This module does NOT control HLS ap_start.
// The CORE sequencer handles AXI-Lite, lane selection,
// kernel reset, and recovery.
//
// IMPORTANT:
// On ERROR or ABORT, the sequencer must reset the
// affected HLS kernels and invalidate/scrub partial
// scratchpad results before asserting recover_ack.

module wcore_axis_adapter #(
    parameter integer ADDR_W = 11
)(
    input  wire clk,
    input  wire rst_n,

    input  wire scratchpad_ready,
    input  wire abort_in,
    input  wire recover_ack,

    // TX descriptor
    input  wire tx_cmd_valid,
    output wire tx_cmd_ready,
    input  wire [1:0] tx_cmd_bank,
    input  wire [ADDR_W-1:0] tx_cmd_addr,
    input  wire [ADDR_W:0] tx_cmd_words,
    input  wire tx_done_ack,
    output wire tx_done,
    output wire tx_error,
    output wire tx_aborted,

    // RX descriptor
    input  wire rx_cmd_valid,
    output wire rx_cmd_ready,
    input  wire [1:0] rx_cmd_bank,
    input  wire [ADDR_W-1:0] rx_cmd_addr,
    input  wire [ADDR_W:0] rx_cmd_words,
    input  wire rx_done_ack,
    output wire rx_done,
    output wire rx_error,
    output wire rx_aborted,

    output wire recovery_required,

    // AXIS TX -> distributor
    output wire [63:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input  wire m_axis_tready,
    output wire m_axis_tlast,

    // AXIS RX <- collector
    input  wire [63:0] s_axis_tdata,
    input  wire s_axis_tvalid,
    output wire s_axis_tready,
    input  wire s_axis_tlast,

    // Scratchpad read request
    output wire [3:0] rd_req_valid,
    input  wire [3:0] rd_req_ready,
    output wire [4*ADDR_W-1:0] rd_req_addr,

    // Scratchpad read response
    input  wire [3:0] rd_rsp_valid,
    output wire [3:0] rd_rsp_ready,
    input  wire [255:0] rd_rsp_data,

    // Scratchpad write request
    output wire [3:0] wr_req_valid,
    input  wire [3:0] wr_req_ready,
    output wire [4*ADDR_W-1:0] wr_req_addr,
    output wire [255:0] wr_req_data
);

    localparam integer DEPTH = (1 << ADDR_W);

    localparam [2:0]
        IDLE   = 3'd0,
        ACTIVE = 3'd1,
        DRAIN  = 3'd2,
        DONE   = 3'd3,
        ERROR  = 3'd4,
        ABORT  = 3'd5;

    (* fsm_encoding = "none" *) reg [2:0] tx_state;
    (* fsm_encoding = "none" *) reg [2:0] rx_state;
    reg rx_framing_flag;   // RX error caused by stream framing (not descriptor)

    reg [1:0] tx_bank;
    reg [1:0] rx_bank;

    reg [ADDR_W-1:0] tx_base;
    reg [ADDR_W-1:0] rx_base;

    reg [ADDR_W:0] tx_length;
    reg [ADDR_W:0] rx_length;

    reg [ADDR_W:0] tx_issued;
    reg [ADDR_W:0] tx_received;
    reg [ADDR_W:0] tx_sent;

    reg [ADDR_W:0] rx_captured;
    reg [ADDR_W:0] rx_written;

    // Four-entry local stream buffers.
    reg [63:0] tx_fifo [0:3];
    reg [63:0] rx_fifo [0:3];

    reg [1:0] tx_head, tx_tail;
    reg [1:0] rx_head, rx_tail;

    reg [2:0] tx_count;
    reg [2:0] rx_count;

    // -----------------------------------------
    // Global recovery / command handling
    // -----------------------------------------

    assign tx_done    = (tx_state == DONE);
    assign rx_done    = (rx_state == DONE);

    assign tx_error   = (tx_state == ERROR);
    assign rx_error   = (rx_state == ERROR);

    assign tx_aborted = (tx_state == ABORT);
    assign rx_aborted = (rx_state == ABORT);

    assign recovery_required =
        tx_error || rx_error ||
        tx_aborted || rx_aborted;

    // Global stop: external abort, any ABORT, or an RX framing fault.
    // A bad descriptor (ERROR without framing) stays local to its engine.
    wire stop_all = abort_in || tx_aborted || rx_aborted || rx_framing_flag;

    wire tx_stop = stop_all || tx_error;
    wire rx_stop = stop_all || rx_error;

    assign tx_cmd_ready =
        (tx_state == IDLE) &&
        scratchpad_ready && !stop_all;   // tx_error implies tx_state != IDLE

    assign rx_cmd_ready =
        (rx_state == IDLE) &&
        scratchpad_ready && !stop_all;

    wire [ADDR_W+1:0] tx_end =
        {2'b00, tx_cmd_addr} +
        {1'b0, tx_cmd_words};

    wire [ADDR_W+1:0] rx_end =
        {2'b00, rx_cmd_addr} +
        {1'b0, rx_cmd_words};

    wire tx_bad_descriptor =
        (tx_cmd_words == 0) || (tx_end > DEPTH);

    wire rx_bad_descriptor =
        (rx_cmd_words == 0) || (rx_end > DEPTH);

    // -----------------------------------------
    // TX read credits
    // -----------------------------------------

    wire [ADDR_W:0] tx_outstanding =
        tx_issued - tx_received;

    wire [ADDR_W+1:0] tx_reserved =
        tx_outstanding + tx_count;

    wire tx_read_valid =
        (tx_state == ACTIVE) &&
        (tx_issued < tx_length) &&
        (tx_reserved < 4) &&
        !tx_stop;

    wire tx_response_ready =
        ((tx_state == ACTIVE) ||
         (tx_state == DRAIN)) &&
        (tx_count < 4) &&
        !tx_stop;

    wire [ADDR_W-1:0] tx_read_addr =
        tx_base + tx_issued[ADDR_W-1:0];

    wire [ADDR_W-1:0] rx_write_addr =
        rx_base + rx_written[ADDR_W-1:0];

    wire tx_read_fire =
        tx_read_valid && rd_req_ready[tx_bank];

    wire tx_response_fire =
        tx_response_ready && rd_rsp_valid[tx_bank];

    wire [63:0] selected_read_data =
        rd_rsp_data[tx_bank*64 +: 64];

    // -----------------------------------------
    // RX write path
    // -----------------------------------------

    wire rx_write_valid =
        ((rx_state == ACTIVE) ||
         (rx_state == DRAIN)) &&
        (rx_count != 0) &&
        !rx_stop;

    wire rx_write_fire =
        rx_write_valid && wr_req_ready[rx_bank];

    // -----------------------------------------
    // Scratchpad bank routing
    // -----------------------------------------

    genvar b;

    generate
        for (b = 0; b < 4; b = b + 1) begin : BANK_ROUTE

            assign rd_req_valid[b] =
                tx_read_valid && (tx_bank == b);

            assign rd_req_addr[b*ADDR_W +: ADDR_W] =
                tx_read_addr;

            assign rd_rsp_ready[b] =
                tx_response_ready && (tx_bank == b);

            assign wr_req_valid[b] =
                rx_write_valid && (rx_bank == b);

            assign wr_req_addr[b*ADDR_W +: ADDR_W] =
                rx_write_addr;

            assign wr_req_data[b*64 +: 64] =
                rx_fifo[rx_head];

        end
    endgenerate

    // -----------------------------------------
    // AXIS interfaces
    // -----------------------------------------

    assign m_axis_tvalid =
        ((tx_state == ACTIVE) ||
         (tx_state == DRAIN)) &&
        (tx_count != 0) &&
        !tx_stop;

    assign m_axis_tdata =
        m_axis_tvalid ? tx_fifo[tx_head] : 64'd0;

    assign m_axis_tlast =
        m_axis_tvalid &&
        (tx_sent == tx_length - 1'b1);

    wire tx_axis_fire =
        m_axis_tvalid && m_axis_tready;

    assign s_axis_tready =
        (rx_state == ACTIVE) &&
        (rx_captured < rx_length) &&
        (rx_count < 4) &&
        !rx_stop;

    wire rx_axis_fire =
        s_axis_tvalid && s_axis_tready;

    wire rx_expected_last =
        (rx_captured == rx_length - 1'b1);

    wire rx_framing_error =
        rx_axis_fire &&
        (s_axis_tlast != rx_expected_last);

    // -----------------------------------------
    // TX FSM
    // -----------------------------------------

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            tx_state    <= IDLE;
            tx_bank     <= 0;
            tx_base     <= 0;
            tx_length   <= 0;
            tx_issued   <= 0;
            tx_received <= 0;
            tx_sent     <= 0;
            tx_head     <= 0;
            tx_tail     <= 0;
            tx_count    <= 0;

        end else begin

            case (tx_state)

                IDLE: begin
                    if (tx_cmd_valid && tx_cmd_ready) begin
                        tx_bank     <= tx_cmd_bank;
                        tx_base     <= tx_cmd_addr;
                        tx_length   <= tx_cmd_words;
                        tx_issued   <= 0;
                        tx_received <= 0;
                        tx_sent     <= 0;
                        tx_head     <= 0;
                        tx_tail     <= 0;
                        tx_count    <= 0;

                        if (tx_bad_descriptor)
                            tx_state <= ERROR;
                        else
                            tx_state <= ACTIVE;
                    end
                end

                ACTIVE, DRAIN: begin

                    if (stop_all) begin
                        tx_state <= ABORT;
                        tx_count <= 0;
                        tx_head  <= 0;
                        tx_tail  <= 0;

                    end else begin

                        if (tx_read_fire) begin
                            tx_issued <= tx_issued + 1'b1;

                            if (tx_issued == tx_length - 1'b1)
                                tx_state <= DRAIN;
                        end

                        if (tx_response_fire) begin
                            tx_fifo[tx_tail] <= selected_read_data;
                            tx_tail <= tx_tail + 1'b1;
                            tx_received <= tx_received + 1'b1;
                        end

                        if (tx_axis_fire) begin
                            tx_head <= tx_head + 1'b1;
                            tx_sent <= tx_sent + 1'b1;

                            if (tx_sent == tx_length - 1'b1)
                                tx_state <= DONE;
                        end

                        case ({tx_response_fire, tx_axis_fire})
                            2'b10: tx_count <= tx_count + 1'b1;
                            2'b01: tx_count <= tx_count - 1'b1;
                            default: tx_count <= tx_count;
                        endcase
                    end
                end

                DONE: begin
                    if (tx_done_ack ||
                        (recover_ack && !abort_in))
                        tx_state <= IDLE;
                end

                ERROR, ABORT: begin
                    // Zeroize local buffer while faulted.
                    tx_fifo[0] <= 64'd0; tx_fifo[1] <= 64'd0;
                    tx_fifo[2] <= 64'd0; tx_fifo[3] <= 64'd0;
                    tx_count <= 0;
                    tx_head  <= 0;
                    tx_tail  <= 0;
                    if (recover_ack && !abort_in)
                        tx_state <= IDLE;
                end

                default: tx_state <= ERROR;

            endcase
        end
    end

    // -----------------------------------------
    // RX FSM
    // -----------------------------------------

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            rx_state    <= IDLE;
            rx_bank     <= 0;
            rx_base     <= 0;
            rx_length   <= 0;
            rx_captured <= 0;
            rx_written  <= 0;
            rx_head     <= 0;
            rx_tail     <= 0;
            rx_count    <= 0;
            rx_framing_flag <= 1'b0;

        end else begin

            case (rx_state)

                IDLE: begin
                    if (rx_cmd_valid && rx_cmd_ready) begin
                        rx_bank     <= rx_cmd_bank;
                        rx_base     <= rx_cmd_addr;
                        rx_length   <= rx_cmd_words;
                        rx_captured <= 0;
                        rx_written  <= 0;
                        rx_head     <= 0;
                        rx_tail     <= 0;
                        rx_count    <= 0;

                        if (rx_bad_descriptor)
                            rx_state <= ERROR;
                        else
                            rx_state <= ACTIVE;
                    end
                end

                ACTIVE, DRAIN: begin

                    if (stop_all) begin
                        rx_state <= ABORT;
                        rx_count <= 0;
                        rx_head  <= 0;
                        rx_tail  <= 0;

                    end else begin

                        if (rx_axis_fire) begin
                            rx_fifo[rx_tail] <= s_axis_tdata;
                            rx_tail <= rx_tail + 1'b1;
                            rx_captured <= rx_captured + 1'b1;

                            if (rx_framing_error) begin
                                rx_state        <= ERROR;
                                rx_framing_flag <= 1'b1;
                            end
                            else if (rx_expected_last)
                                rx_state <= DRAIN;
                        end

                        if (rx_write_fire) begin
                            rx_head <= rx_head + 1'b1;
                            rx_written <= rx_written + 1'b1;
                        end

                        case ({rx_axis_fire, rx_write_fire})
                            2'b10: rx_count <= rx_count + 1'b1;
                            2'b01: rx_count <= rx_count - 1'b1;
                            default: rx_count <= rx_count;
                        endcase

                        if ((rx_state == DRAIN) &&
                            (rx_count == 0) &&
                            (rx_written == rx_length))
                            rx_state <= DONE;
                    end
                end

                DONE: begin
                    if (rx_done_ack ||
                        (recover_ack && !abort_in))
                        rx_state <= IDLE;
                end

                ERROR, ABORT: begin
                    // Zeroize local buffer while faulted.
                    rx_fifo[0] <= 64'd0; rx_fifo[1] <= 64'd0;
                    rx_fifo[2] <= 64'd0; rx_fifo[3] <= 64'd0;
                    rx_count <= 0;
                    rx_head  <= 0;
                    rx_tail  <= 0;
                    if (recover_ack && !abort_in) begin
                        rx_state        <= IDLE;
                        rx_framing_flag <= 1'b0;
                    end
                end

                default: rx_state <= ERROR;

            endcase
        end
    end

endmodule
