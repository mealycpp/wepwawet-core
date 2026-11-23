`timescale 1ns / 1ps

// WEPWAWET-CORE SCRATCHPAD REV E (BRAM INFERENCE FIX)
// 4 banks x 2048 words x 64 bits = 64 KiB
// 333 MHz target. Rev D FSM/ports unchanged; verify BRAM mapping in Vivado.
// This revision is not considered accepted until XSIM 22/22 and OOC BRAM
// synthesis (16 RAMB36 equivalents) both pass on the target part.
// por_n is independent hardware POR; rst_n is synchronous soft reset.
// scrub_req and fault_in must be synchronous to clk.

module wcore_scratchpad_fsm #(
    parameter integer ADDR_W = 11,
    parameter integer PREFREEZE = 0
)(
    input wire clk,
    input wire pre_quiesce,
    input wire por_n,
    input wire rst_n,
    input wire scrub_req,
    input wire fault_in,
    output wire mem_access_en,
    output wire scrub_we,
    output wire [ADDR_W-1:0] scrub_addr,
    output wire busy,
    output wire abort,
    output wire locked,
    output reg init_done,
    output reg scrub_done,
    output reg fault_latched
);
    localparam [2:0]
        ST_INIT=3'd0, ST_READY=3'd1,
        ST_QUIESCE=3'd2, ST_SCRUB=3'd3,
        ST_LOCKED=3'd4, ST_HOLD=3'd5;

    (* fsm_encoding = "none" *) reg [2:0] state;
    reg [ADDR_W-1:0] addr;
    reg scrub_req_d;
    reg scrub_pending;

    wire scrub_edge = scrub_req && !scrub_req_d;

    assign scrub_addr = addr;
    assign scrub_we = (state == ST_INIT) || (state == ST_SCRUB);

    // V6: in integrated recovery, the sequencer asserts pre_quiesce
    // BEFORE its delayed scrub pulse. For that instance, READY access
    // is controlled entirely by registered FSM state, not by the scrub
    // edge detector or pending bit. The default standalone instance
    // retains its original immediate scrub gating.
    assign mem_access_en =
        (state == ST_READY) &&
        rst_n && !fault_in && !fault_latched &&
        ((PREFREEZE != 0) ? 1'b1 : (!scrub_pending && !scrub_edge));

    assign busy = !mem_access_en;
    assign locked = (state == ST_LOCKED);
    assign abort =
        (state == ST_QUIESCE) ||
        (state == ST_SCRUB) ||
        (state == ST_LOCKED) ||
        ((state == ST_READY) && !mem_access_en) ||
        ((PREFREEZE != 0) && (state == ST_HOLD));

    always @(posedge clk or negedge por_n) begin
        if (!por_n) begin
            state         <= ST_INIT;
            addr          <= {ADDR_W{1'b0}};
            scrub_req_d   <= 1'b0;
            scrub_pending <= 1'b0;
            init_done     <= 1'b0;
            scrub_done    <= 1'b0;
            fault_latched <= 1'b0;
        end else begin
            scrub_req_d <= scrub_req;
            scrub_done <= 1'b0;

            if (fault_in)
                fault_latched <= 1'b1;
            if (scrub_edge)
                scrub_pending <= 1'b1;

            case (state)
                ST_INIT: begin
                    if (&addr) begin
                        addr <= {ADDR_W{1'b0}};
                        init_done <= 1'b1;

                        // Fault takes priority. Initialization
                        // has already cleared every memory bank.
                        if (fault_latched || fault_in) begin
                            if (scrub_pending || scrub_edge)
                                scrub_done <= 1'b1;
                            state <= ST_LOCKED;
                        end else if (scrub_pending || scrub_edge)
                            state <= ST_QUIESCE;
                        else if (!rst_n || ((PREFREEZE != 0) && pre_quiesce))
                            state <= ST_HOLD;
                        else
                            state <= ST_READY;
                    end else
                        addr <= addr + 1'b1;
                end

                ST_READY: begin
                    if (fault_in || fault_latched ||
                        scrub_pending || scrub_edge || !rst_n)
                        state <= ST_QUIESCE;
                    else if ((PREFREEZE != 0) && pre_quiesce)
                        state <= ST_HOLD;
                end

                ST_QUIESCE: begin
                    // Consume the current request while
                    // retaining a new edge on this cycle.
                    scrub_pending <= scrub_edge;
                    addr <= {ADDR_W{1'b0}};
                    state <= ST_SCRUB;
                end

                ST_SCRUB: begin
                    if (&addr) begin
                        addr <= {ADDR_W{1'b0}};
                        scrub_done <= 1'b1;

                        // REV D: fault ALWAYS wins over
                        // further pending scrub requests.
                        if (fault_latched || fault_in)
                            state <= ST_LOCKED;
                        else if (scrub_pending || scrub_edge)
                            state <= ST_QUIESCE;
                        else if (!rst_n || ((PREFREEZE != 0) && pre_quiesce))
                            state <= ST_HOLD;
                        else
                            state <= ST_READY;
                    end else
                        addr <= addr + 1'b1;
                end

                ST_HOLD: begin
                    if (fault_latched || fault_in ||
                        scrub_pending || scrub_edge)
                        state <= ST_QUIESCE;
                    else if (rst_n && !((PREFREEZE != 0) && pre_quiesce))
                        state <= ST_READY;
                end

                ST_LOCKED: begin
                    state <= ST_LOCKED;
                end

                default: begin
                    // Illegal state: scrub before lockout.
                    fault_latched <= 1'b1;
                    addr <= {ADDR_W{1'b0}};
                    state <= ST_QUIESCE;
                end
            endcase
        end
    end
endmodule


module wcore_scratchpad #(
    parameter integer BANKS=4,
    parameter integer ADDR_W=11,
    parameter integer DATA_W=64,
    parameter integer PREFREEZE=0,
    parameter integer BUFFER_REQUESTS=0
)(
    input wire clk,
    input wire pre_quiesce,
    input wire por_n,
    input wire rst_n,
    input wire scrub_req,
    input wire fault_in,
    output wire busy,
    output wire locked,
    output wire abort,
    output wire init_done,
    output wire scrub_done,
    output wire fault_latched,
    input wire [BANKS-1:0] rd_req_valid,
    output wire [BANKS-1:0] rd_req_ready,
    input wire [BANKS*ADDR_W-1:0] rd_req_addr,
    output wire [BANKS-1:0] rd_rsp_valid,
    input wire [BANKS-1:0] rd_rsp_ready,
    output wire [BANKS*DATA_W-1:0] rd_rsp_data,
    input wire [BANKS-1:0] wr_req_valid,
    output wire [BANKS-1:0] wr_req_ready,
    input wire [BANKS*ADDR_W-1:0] wr_req_addr,
    input wire [BANKS*DATA_W-1:0] wr_req_data
);
    localparam integer DEPTH = (1 << ADDR_W);

    wire mem_access_en, scrub_we;
    wire [ADDR_W-1:0] scrub_addr;

    wcore_scratchpad_fsm #(.ADDR_W(ADDR_W), .PREFREEZE(PREFREEZE)) u_fsm (
        .clk(clk), .pre_quiesce(pre_quiesce), .por_n(por_n), .rst_n(rst_n),
        .scrub_req(scrub_req), .fault_in(fault_in),
        .mem_access_en(mem_access_en),
        .scrub_we(scrub_we), .scrub_addr(scrub_addr),
        .busy(busy), .abort(abort), .locked(locked),
        .init_done(init_done), .scrub_done(scrub_done),
        .fault_latched(fault_latched)
    );

    genvar g;
    generate
        for (g=0; g<BANKS; g=g+1) begin : BANK
            (* ram_style = "block" *)
            reg [DATA_W-1:0] mem [0:DEPTH-1];

            wire [ADDR_W-1:0] raddr =
                rd_req_addr[g*ADDR_W +: ADDR_W];
            wire [ADDR_W-1:0] waddr =
                wr_req_addr[g*ADDR_W +: ADDR_W];
            wire [DATA_W-1:0] wdata =
                wr_req_data[g*DATA_W +: DATA_W];

            reg [DATA_W-1:0] pipe_data;
            reg pipe_valid;
            reg [DATA_W-1:0] fifo_mem [0:3];
            reg [1:0] fifo_head, fifo_tail;
            reg [2:0] fifo_count;

            wire [3:0] reserved_slots =
                {1'b0,fifo_count} + {3'b000,pipe_valid};

            // V6 protocol skid buffers: end the ready->address->ready
            // feedback. A handshake captures the full request. The
            // scratchpad executes it later, preserving read ordering and
            // delaying same-address reads until the queued write commits.
            // When disabled (default), original handshake is unchanged.
            reg rd_queued, wr_queued;
            reg [ADDR_W-1:0] rd_addr_q, wr_addr_q;
            reg [DATA_W-1:0] wr_data_q;
            wire collision =
                wr_req_valid[g] && (waddr == raddr);

            assign wr_req_ready[g] = mem_access_en &&
                ((BUFFER_REQUESTS != 0) ? !wr_queued : 1'b1);
            assign rd_req_ready[g] = mem_access_en &&
                ((BUFFER_REQUESTS != 0) ? !rd_queued :
                 ((reserved_slots < 4) && !collision));

            wire wr_fire = wr_req_valid[g] && wr_req_ready[g];
            wire rd_fire = rd_req_valid[g] && rd_req_ready[g];
            wire wr_exec = (BUFFER_REQUESTS != 0) ?
                (mem_access_en && wr_queued) : wr_fire;
            wire [ADDR_W-1:0] use_raddr =
                (BUFFER_REQUESTS != 0) ? rd_addr_q : raddr;
            wire [ADDR_W-1:0] use_waddr =
                (BUFFER_REQUESTS != 0) ? wr_addr_q : waddr;
            wire [DATA_W-1:0] use_wdata =
                (BUFFER_REQUESTS != 0) ? wr_data_q : wdata;
            wire queued_collision = wr_exec && (use_waddr == use_raddr);
            wire rd_exec = (BUFFER_REQUESTS != 0) ?
                (mem_access_en && rd_queued &&
                 (reserved_slots < 4) && !queued_collision) : rd_fire;

            always @(posedge clk or negedge por_n) begin
                if (!por_n) begin
                    rd_queued <= 1'b0;
                    wr_queued <= 1'b0;
                    rd_addr_q <= {ADDR_W{1'b0}};
                    wr_addr_q <= {ADDR_W{1'b0}};
                    wr_data_q <= {DATA_W{1'b0}};
                end else if (!mem_access_en) begin
                    // Recovery invalidates all buffered, uncommitted work.
                    rd_queued <= 1'b0;
                    wr_queued <= 1'b0;
                end else if (BUFFER_REQUESTS != 0) begin
                    if (rd_fire) begin
                        rd_addr_q <= raddr;
                        rd_queued <= 1'b1;
                    end else if (rd_exec) begin
                        rd_queued <= 1'b0;
                    end
                    if (wr_fire) begin
                        wr_addr_q <= waddr;
                        wr_data_q <= wdata;
                        wr_queued <= 1'b1;
                    end else if (wr_exec) begin
                        wr_queued <= 1'b0;
                    end
                end
            end

            assign rd_rsp_valid[g] =
                mem_access_en && (fifo_count != 0);

            assign rd_rsp_data[g*DATA_W +: DATA_W] =
                rd_rsp_valid[g]
                    ? fifo_mem[fifo_head]
                    : {DATA_W{1'b0}};

            wire fifo_pop =
                rd_rsp_valid[g] && rd_rsp_ready[g];
            wire fifo_push = pipe_valid;

            // REV E: one physical write port shared by scrub and user writes.
            // The Rev D code used two separate mem[...] <= assignments with
            // different addresses. Vivado can interpret that as two write
            // ports plus the read port and map the array to distributed RAM.
            // A single write site and an independent synchronous read site
            // form a simple-dual-port BRAM-compatible inference template.
            wire mem_wr_en = scrub_we || wr_exec;
            wire [ADDR_W-1:0] mem_wr_addr =
                scrub_we ? scrub_addr : use_waddr;
            wire [DATA_W-1:0] mem_wr_data =
                scrub_we ? {DATA_W{1'b0}} : use_wdata;

            always @(posedge clk) begin
                if (mem_wr_en)
                    mem[mem_wr_addr] <= mem_wr_data;
            end

            // Preserve the existing one-cycle read pipeline and the
            // synchronous clearing of the read-data register on scrub.
            // rd_fire cannot coincide with scrub_we because access is
            // disabled in INIT and SCRUB.
            always @(posedge clk) begin
                if (rd_exec)
                    pipe_data <= mem[use_raddr];
                else if (scrub_we)
                    pipe_data <= {DATA_W{1'b0}};
            end

            // Clear response storage during scrub.
            always @(posedge clk) begin
                if (scrub_we && (scrub_addr < 4))
                    fifo_mem[scrub_addr[1:0]] <=
                        {DATA_W{1'b0}};
                else if (mem_access_en && fifo_push)
                    fifo_mem[fifo_tail] <= pipe_data;
            end

            always @(posedge clk or negedge por_n) begin
                if (!por_n) begin
                    pipe_valid <= 1'b0;
                    fifo_head <= 2'd0;
                    fifo_tail <= 2'd0;
                    fifo_count <= 3'd0;
                end else if (!mem_access_en) begin
                    pipe_valid <= 1'b0;
                    fifo_head <= 2'd0;
                    fifo_tail <= 2'd0;
                    fifo_count <= 3'd0;
                end else begin
                    pipe_valid <= rd_exec;
                    if (fifo_push)
                        fifo_tail <= fifo_tail + 1'b1;
                    if (fifo_pop)
                        fifo_head <= fifo_head + 1'b1;

                    case ({fifo_push,fifo_pop})
                        2'b10: fifo_count <= fifo_count + 1'b1;
                        2'b01: fifo_count <= fifo_count - 1'b1;
                        default: fifo_count <= fifo_count;
                    endcase
                end
            end
        end
    endgenerate
endmodule
