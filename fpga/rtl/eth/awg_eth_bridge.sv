`timescale 1ns/1ps
`default_nettype none

// =============================================================
// Module: awg_eth_bridge
// Function: UDP application bridge with CDC packet FIFOs and a
//           single-outstanding AXI4-Lite master command engine.
// Clocks/resets: clk_eth/rst_eth synchronous active-high;
//                host_clk/host_resetn synchronous active-low.
// =============================================================
module awg_eth_bridge #(
    parameter integer MAX_WORDS = 2048,
    parameter [31:0] BUILD_ID = 32'h0001_0000,
    parameter integer AXI_TIMEOUT_CYCLES = 4096,
    parameter integer RX_FIFO_DEPTH = 131072,
    parameter integer TX_FIFO_DEPTH = 32768
) (
    input  wire        clk_eth,
    input  wire        rst_eth,
    input  wire        rx_hdr_valid,
    output wire        rx_hdr_ready,
    input  wire [31:0] rx_src_ip,
    input  wire [15:0] rx_src_port,
    input  wire [15:0] rx_length,
    input  wire [63:0] rx_payload_tdata,
    input  wire [7:0]  rx_payload_tkeep,
    input  wire        rx_payload_tvalid,
    output wire        rx_payload_tready,
    input  wire        rx_payload_tlast,
    input  wire        rx_payload_tuser,
    output wire        tx_hdr_valid,
    input  wire        tx_hdr_ready,
    output wire [31:0] tx_dst_ip,
    output wire [15:0] tx_dst_port,
    output wire [15:0] tx_length,
    output wire [63:0] tx_payload_tdata,
    output wire [7:0]  tx_payload_tkeep,
    output wire        tx_payload_tvalid,
    input  wire        tx_payload_tready,
    output wire        tx_payload_tlast,
    output wire        tx_payload_tuser,
    input  wire        host_clk,
    input  wire        host_resetn,
    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready
);

    localparam integer MAX_BYTES = 24 + 4*MAX_WORDS;
    localparam integer MAX_FRAME_BEATS = 1 + ((MAX_BYTES + 7) / 8);
    localparam integer MAX_FRAME_FIFO_BYTES = MAX_FRAME_BEATS * 16;
    localparam integer RESP_WORDS = MAX_WORDS < 16 ? 16 : MAX_WORDS;
    localparam integer RX_STATUS_WIDTH = $clog2(RX_FIFO_DEPTH) + 1;
    localparam integer TX_STATUS_WIDTH = $clog2(TX_FIFO_DEPTH) + 1;
    localparam [15:0] UDP_PORT = 16'd9100;
    localparam [15:0] MAGIC = 16'hA7E1;

    generate
        if ((TX_FIFO_DEPTH / 16) < MAX_FRAME_BEATS) begin : g_tx_fifo_too_small
            initial $error("TX_FIFO_DEPTH=%0d bytes cannot hold maximum frame; need at least %0d bytes",
                           TX_FIFO_DEPTH, MAX_FRAME_FIFO_BYTES);
        end
        if ((RX_FIFO_DEPTH / 16) < MAX_FRAME_BEATS) begin : g_rx_fifo_too_small
            initial $error("RX_FIFO_DEPTH=%0d bytes cannot hold maximum request; need at least %0d bytes",
                           RX_FIFO_DEPTH, MAX_FRAME_FIFO_BYTES);
        end
    endgenerate

    /* RX frame FIFO: metadata is the first 64-bit word, followed by payload. */
    wire [127:0] rx_fifo_s_data;
    wire [15:0] rx_fifo_s_keep;
    wire         rx_fifo_s_valid;
    wire         rx_fifo_s_ready;
    wire         rx_fifo_s_last;
    wire         rx_fifo_s_user;
    wire [127:0] rx_fifo_m_data;
    wire [15:0]  rx_fifo_m_keep;
    wire         rx_fifo_m_valid;
    wire         rx_fifo_m_ready;
    wire         rx_fifo_m_last;
    wire         rx_fifo_m_user;
    wire         rx_fifo_s_overflow;
    wire         rx_fifo_s_bad_frame;
    wire [RX_STATUS_WIDTH-1:0]  rx_fifo_s_depth;
    wire [RX_STATUS_WIDTH-1:0]  rx_fifo_s_depth_commit;
    wire [RX_STATUS_WIDTH-1:0]  rx_fifo_m_depth;
    wire [RX_STATUS_WIDTH-1:0]  rx_fifo_m_depth_commit;
    wire         rx_fifo_m_overflow;
    wire         rx_fifo_m_bad_frame;
    wire         rx_fifo_m_good_frame;
    reg          rx_header_sent;
    reg [31:0]   rx_drop_count_eth;
    reg [31:0]   rx_drop_gray_eth;
    wire         rx_drop_event_eth = rx_fifo_s_overflow || rx_fifo_s_bad_frame;
    wire [31:0]  rx_drop_count_next = rx_drop_count_eth == 32'hffff_ffff ?
                                      32'hffff_ffff : rx_drop_count_eth + 1'b1;
    wire [31:0]  rx_drop_gray_next = rx_drop_count_next ^ (rx_drop_count_next >> 1);

    assign rx_fifo_s_data = rx_header_sent ? {64'd0, rx_payload_tdata} :
                            {63'd0, 1'b1, rx_length, rx_src_port, rx_src_ip};
    assign rx_fifo_s_keep = rx_header_sent ? {8'd0, rx_payload_tkeep} : 16'h00ff;
    assign rx_fifo_s_valid = rx_header_sent ? rx_payload_tvalid : rx_hdr_valid;
    assign rx_fifo_s_last = rx_header_sent ? rx_payload_tlast : 1'b0;
    assign rx_fifo_s_user = rx_header_sent ? rx_payload_tuser : 1'b0;
    assign rx_hdr_ready = !rx_header_sent && rx_fifo_s_ready && !rst_eth;
    assign rx_payload_tready = rx_header_sent && rx_fifo_s_ready && !rst_eth;

    // AXI-stream frame FIFOs require the metadata beat and payload beats to
    // remain in one frame; a one-cycle delayed header release preserves that
    // ordering while allowing the UDP source to present the header first.

    always @(posedge clk_eth) begin
        if (rst_eth) begin
            rx_header_sent <= 1'b0;
            rx_drop_count_eth <= 32'd0;
            rx_drop_gray_eth <= 32'd0;
        end else begin
            if (rx_hdr_valid && rx_hdr_ready)
                rx_header_sent <= 1'b1;
            if (rx_header_sent && rx_payload_tvalid && rx_payload_tready && rx_payload_tlast)
                rx_header_sent <= 1'b0;
            if (rx_drop_event_eth) begin
                rx_drop_count_eth <= rx_drop_count_next;
                rx_drop_gray_eth <= rx_drop_gray_next;
            end
        end
    end

    axis_async_fifo #(
        .DEPTH(RX_FIFO_DEPTH),
        .DATA_WIDTH(128),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH(16),
        .LAST_ENABLE(1),
        .USER_ENABLE(1),
        .USER_WIDTH(1),
        .RAM_PIPELINE(1),
        .FRAME_FIFO(1),
        .DROP_OVERSIZE_FRAME(1),
        .DROP_BAD_FRAME(1),
        .DROP_WHEN_FULL(1),
        .FRAME_PAUSE(1)
    ) u_rx_fifo (
        .s_clk(clk_eth),
        .s_rst(rst_eth),
        .s_axis_tdata(rx_fifo_s_data),
        .s_axis_tkeep(rx_fifo_s_keep),
        .s_axis_tvalid(rx_fifo_s_valid),
        .s_axis_tready(rx_fifo_s_ready),
        .s_axis_tlast(rx_fifo_s_last),
        .s_axis_tid(8'd0),
        .s_axis_tdest(8'd0),
        .s_axis_tuser(rx_fifo_s_user),
        .m_clk(host_clk),
        .m_rst(!host_resetn),
        .m_axis_tdata(rx_fifo_m_data),
        .m_axis_tkeep(rx_fifo_m_keep),
        .m_axis_tvalid(rx_fifo_m_valid),
        .m_axis_tready(rx_fifo_m_ready),
        .m_axis_tlast(rx_fifo_m_last),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(rx_fifo_m_user),
        .s_pause_req(1'b0),
        .s_pause_ack(),
        .m_pause_req(1'b0),
        .m_pause_ack(),
        .s_status_depth(rx_fifo_s_depth),
        .s_status_depth_commit(rx_fifo_s_depth_commit),
        .s_status_overflow(rx_fifo_s_overflow),
        .s_status_bad_frame(rx_fifo_s_bad_frame),
        .s_status_good_frame(),
        .m_status_depth(rx_fifo_m_depth),
        .m_status_depth_commit(rx_fifo_m_depth_commit),
        .m_status_overflow(rx_fifo_m_overflow),
        .m_status_bad_frame(rx_fifo_m_bad_frame),
        .m_status_good_frame(rx_fifo_m_good_frame)
    );

    /* TX frame FIFO: host creates a metadata word then a 64-bit UDP payload. */
    reg  [127:0] tx_fifo_s_data;
    reg  [15:0]  tx_fifo_s_keep;
    wire         tx_fifo_s_valid;
    wire         tx_fifo_s_ready;
    reg          tx_fifo_s_last;
    wire         tx_fifo_s_user;
    wire [127:0] tx_fifo_m_data;
    wire [15:0]  tx_fifo_m_keep;
    wire         tx_fifo_m_valid;
    wire         tx_fifo_m_ready;
    wire         tx_fifo_m_last;
    wire         tx_fifo_m_user;
    wire [TX_STATUS_WIDTH-1:0]  tx_fifo_s_depth;
    wire [TX_STATUS_WIDTH-1:0]  tx_fifo_s_depth_commit;
    wire [TX_STATUS_WIDTH-1:0]  tx_fifo_m_depth;
    wire [TX_STATUS_WIDTH-1:0]  tx_fifo_m_depth_commit;

    axis_async_fifo #(
        .DEPTH(TX_FIFO_DEPTH),
        .DATA_WIDTH(128),
        .KEEP_ENABLE(1),
        .KEEP_WIDTH(16),
        .LAST_ENABLE(1),
        .USER_ENABLE(1),
        .USER_WIDTH(1),
        .RAM_PIPELINE(1),
        .FRAME_FIFO(1),
        .DROP_OVERSIZE_FRAME(1),
        .DROP_BAD_FRAME(0),
        .DROP_WHEN_FULL(0),
        .FRAME_PAUSE(1)
    ) u_tx_fifo (
        .s_clk(host_clk),
        .s_rst(!host_resetn),
        .s_axis_tdata(tx_fifo_s_data),
        .s_axis_tkeep(tx_fifo_s_keep),
        .s_axis_tvalid(tx_fifo_s_valid),
        .s_axis_tready(tx_fifo_s_ready),
        .s_axis_tlast(tx_fifo_s_last),
        .s_axis_tid(8'd0),
        .s_axis_tdest(8'd0),
        .s_axis_tuser(tx_fifo_s_user),
        .m_clk(clk_eth),
        .m_rst(rst_eth),
        .m_axis_tdata(tx_fifo_m_data),
        .m_axis_tkeep(tx_fifo_m_keep),
        .m_axis_tvalid(tx_fifo_m_valid),
        .m_axis_tready(tx_fifo_m_ready),
        .m_axis_tlast(tx_fifo_m_last),
        .m_axis_tid(),
        .m_axis_tdest(),
        .m_axis_tuser(tx_fifo_m_user),
        .s_pause_req(1'b0),
        .s_pause_ack(),
        .m_pause_req(1'b0),
        .m_pause_ack(),
        .s_status_depth(tx_fifo_s_depth),
        .s_status_depth_commit(tx_fifo_s_depth_commit),
        .s_status_overflow(),
        .s_status_bad_frame(),
        .s_status_good_frame(),
        .m_status_depth(tx_fifo_m_depth),
        .m_status_depth_commit(tx_fifo_m_depth_commit),
        .m_status_overflow(),
        .m_status_bad_frame(),
        .m_status_good_frame()
    );

    /* Ethernet-side TX adapter. */
    localparam [1:0] ETH_TX_META = 2'd0;
    localparam [1:0] ETH_TX_DATA = 2'd1;
    reg [1:0] eth_tx_state;
    assign tx_hdr_valid = eth_tx_state == ETH_TX_META && tx_fifo_m_valid && tx_fifo_m_data[64];
    assign tx_dst_ip = tx_fifo_m_data[31:0];
    assign tx_dst_port = tx_fifo_m_data[47:32];
    assign tx_length = tx_fifo_m_data[63:48];
    assign tx_payload_tvalid = eth_tx_state == ETH_TX_DATA && tx_fifo_m_valid;
    assign tx_payload_tdata = tx_fifo_m_data[63:0];
    assign tx_payload_tkeep = tx_fifo_m_keep[7:0];
    assign tx_payload_tlast = tx_fifo_m_last;
    assign tx_payload_tuser = tx_fifo_m_user;
    assign tx_fifo_m_ready = (eth_tx_state == ETH_TX_META) ?
                             (tx_hdr_ready && tx_fifo_m_valid && tx_fifo_m_data[64]) :
                             (eth_tx_state == ETH_TX_DATA ? tx_payload_tready : 1'b0);

    always @(posedge clk_eth) begin
        if (rst_eth) begin
            eth_tx_state <= ETH_TX_META;
        end else if (tx_fifo_m_valid && tx_fifo_m_ready) begin
            if (eth_tx_state == ETH_TX_META)
                eth_tx_state <= ETH_TX_DATA;
            else if (tx_fifo_m_last)
                eth_tx_state <= ETH_TX_META;
        end
    end

    /* Host-domain packet storage and protocol state. */
    localparam integer PAYLOAD_QWORDS = (MAX_WORDS + 1) / 2;
    localparam integer RESP_QWORDS = PAYLOAD_QWORDS < 8 ? 8 : PAYLOAD_QWORDS;
    localparam integer PAYLOAD_ADDR_WIDTH = PAYLOAD_QWORDS <= 1 ? 1 : $clog2(PAYLOAD_QWORDS);
    localparam integer RESP_ADDR_WIDTH = RESP_QWORDS <= 1 ? 1 : $clog2(RESP_QWORDS);

    (* ram_style = "block" *) reg [63:0] payload_mem [0:PAYLOAD_QWORDS-1];
    (* ram_style = "block" *) reg [63:0] response_mem [0:RESP_QWORDS-1];
    reg [63:0] payload_rd_data;
    reg [63:0] response_rd_data;
    reg [RESP_ADDR_WIDTH-1:0] response_wr_addr;
    reg [63:0] response_wr_data;
    reg response_wr_en;

    reg [63:0] request_header_0;
    reg [63:0] request_header_1;
    reg [63:0] request_header_2;
    reg [15:0] rx_beat_count;
    reg [15:0] packet_bytes;
    reg [15:0] rx_length_meta;
    reg [31:0] rx_src_ip_meta;
    reg [15:0] rx_src_port_meta;
    reg packet_overflow;

    function automatic [3:0] keep_byte_count(input [7:0] keep);
        integer ki;
        begin
            keep_byte_count = 0;
            for (ki = 0; ki < 8; ki = ki + 1)
                keep_byte_count = keep_byte_count + keep[ki];
        end
    endfunction

    function automatic [31:0] sat_inc(input [31:0] value);
        begin
            sat_inc = value == 32'hffff_ffff ? 32'hffff_ffff : value + 1'b1;
        end
    endfunction

    function automatic [31:0] sat_add(input [31:0] value, input [31:0] addend);
        reg [32:0] sum;
        begin
            sum = {1'b0, value} + {1'b0, addend};
            sat_add = sum[32] ? 32'hffff_ffff : sum[31:0];
        end
    endfunction

    function automatic [31:0] gray_to_bin(input [31:0] gray);
        integer gi;
        begin
            gray_to_bin[31] = gray[31];
            for (gi = 30; gi >= 0; gi = gi - 1)
                gray_to_bin[gi] = gray_to_bin[gi+1] ^ gray[gi];
        end
    endfunction

    localparam [3:0] ST_RX_META       = 4'd0;
    localparam [3:0] ST_RX_DATA       = 4'd1;
    localparam [3:0] ST_PARSE         = 4'd2;
    localparam [3:0] ST_EXEC          = 4'd3;
    localparam [3:0] ST_PAYLOAD_WAIT  = 4'd4;
    localparam [3:0] ST_AXI_WRITE     = 4'd5;
    localparam [3:0] ST_AXI_READ      = 4'd6;
    localparam [3:0] ST_INFO_FILL     = 4'd7;
    localparam [3:0] ST_TX_META       = 4'd8;
    localparam [3:0] ST_TX_HEADER     = 4'd9;
    localparam [3:0] ST_TX_READ_REQ   = 4'd10;
    localparam [3:0] ST_TX_READ_WAIT  = 4'd11;
    localparam [3:0] ST_TX_PAYLOAD    = 4'd12;
    reg [3:0] state;
    assign rx_fifo_m_ready = (state == ST_RX_META) || (state == ST_RX_DATA);

    wire [15:0] request_magic = request_header_0[15:0];
    wire [7:0] request_version = request_header_0[23:16];
    wire [7:0] request_opcode = request_header_0[31:24];
    wire [31:0] request_seq = request_header_0[63:32];
    wire [31:0] request_addr = request_header_1[31:0];
    wire [15:0] request_count = request_header_1[47:32];
    wire [15:0] request_flags = request_header_1[63:48];
    wire [31:0] request_status_error = request_header_2[31:0];
    wire [31:0] request_reserved = request_header_2[63:32];

    reg [7:0] cmd_opcode;
    reg [31:0] cmd_seq;
    reg [31:0] cmd_addr;
    reg [15:0] cmd_count;
    reg [15:0] cmd_flags;
    reg [15:0] exec_index;
    reg [15:0] done_count;
    reg [15:0] cmd_status;
    reg [15:0] cmd_error_index;
    reg [31:0] axi_addr_reg;
    reg [31:0] axi_wdata_reg;
    reg axi_aw_pending;
    reg axi_w_pending;
    reg axi_ar_pending;
    reg axi_b_wait;
    reg axi_r_wait;
    reg [31:0] axi_wait_count;
    reg [31:0] pending_read_low;
    wire [15:0] next_exec_index = exec_index + 1'b1;

    reg [31:0] resp_dst_ip;
    reg [15:0] resp_dst_port;
    reg [7:0] resp_opcode;
    reg [31:0] resp_seq;
    reg [31:0] resp_addr;
    reg [15:0] resp_count;
    reg [15:0] resp_status;
    reg [15:0] resp_error_index;
    reg [15:0] resp_payload_words;
    reg [15:0] info_word_index;
    reg [31:0] info_words [0:15];

    reg [15:0] tx_header_index;
    reg [15:0] tx_qword_index;
    reg [63:0] tx_skid_data;
    reg tx_skid_valid;

    reg last_write_valid;
    reg [31:0] last_write_seq;
    reg [31:0] last_write_addr;
    reg [15:0] last_write_count;
    reg [15:0] last_write_status;
    reg [15:0] last_write_error;

    reg [31:0] rx_ok_count;
    reg [31:0] rx_bad_req_count;
    reg [31:0] rx_dropped_count;
    reg [31:0] tx_reply_count;
    reg [31:0] dup_write_count;
    reg [31:0] axi_error_count;
    reg [31:0] axi_timeout_count;
    reg [31:0] axi_word_count;

    (* ASYNC_REG = "TRUE" *) reg [31:0] drop_gray_meta;
    (* ASYNC_REG = "TRUE" *) reg [31:0] drop_gray_sync1;
    (* ASYNC_REG = "TRUE" *) reg [31:0] drop_gray_sync2;
    reg [31:0] drop_bin_seen;
    wire [31:0] drop_bin_sync = gray_to_bin(drop_gray_sync2);

    wire payload_wr_en = state == ST_RX_DATA && rx_fifo_m_valid &&
                         rx_fifo_m_ready && rx_beat_count >= 3 &&
                         (rx_beat_count - 16'd3) < PAYLOAD_QWORDS;
    wire [PAYLOAD_ADDR_WIDTH-1:0] payload_wr_addr = rx_beat_count - 16'd3;
    wire payload_initial_read = state == ST_EXEC && cmd_status == 0 &&
                                exec_index < cmd_count && cmd_opcode == 8'd2;
    wire payload_prefetch_read = state == ST_AXI_WRITE && axi_w_pending &&
                                 m_wready && exec_index[0] &&
                                 next_exec_index < cmd_count;
    wire payload_rd_en = payload_initial_read || payload_prefetch_read;
    wire [PAYLOAD_ADDR_WIDTH-1:0] payload_rd_addr = payload_prefetch_read ?
        (next_exec_index >> 1) : (exec_index >> 1);
    wire response_rd_en = state == ST_TX_READ_REQ;
    wire [15:0] response_qword_count = (resp_payload_words + 16'd1) >> 1;
    wire response_pair_write = state == ST_AXI_READ && axi_r_wait &&
                               m_rvalid && m_rready && m_rresp == 0 &&
                               exec_index[0];
    wire response_partial_write = state == ST_EXEC &&
                                  (cmd_status != 0 || exec_index >= cmd_count) &&
                                  cmd_opcode == 8'd1 && done_count[0];
    wire response_info_write = state == ST_INFO_FILL;

    always @* begin
        response_wr_en = 1'b0;
        response_wr_addr = 0;
        response_wr_data = 0;
        if (response_info_write) begin
            response_wr_en = 1'b1;
            response_wr_addr = info_word_index >> 1;
            response_wr_data = {info_words[info_word_index + 1'b1], info_words[info_word_index]};
        end else if (response_pair_write) begin
            response_wr_en = 1'b1;
            response_wr_addr = exec_index >> 1;
            response_wr_data = {m_rdata, pending_read_low};
        end else if (response_partial_write) begin
            response_wr_en = 1'b1;
            response_wr_addr = done_count >> 1;
            response_wr_data = {32'd0, pending_read_low};
        end
    end

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            payload_rd_data <= 0;
        end else begin
            if (payload_wr_en)
                payload_mem[payload_wr_addr] <= rx_fifo_m_data[63:0];
            if (payload_rd_en)
                payload_rd_data <= payload_mem[payload_rd_addr];
        end
    end

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            response_rd_data <= 0;
        end else begin
            if (response_wr_en)
                response_mem[response_wr_addr] <= response_wr_data;
            if (response_rd_en)
                response_rd_data <= response_mem[tx_qword_index[RESP_ADDR_WIDTH-1:0]];
        end
    end

    wire bad_header_drop = state == ST_PARSE &&
                           (rx_length_meta < 24 || packet_bytes < 24 ||
                            request_magic != MAGIC || request_version != 8'd1);
    wire [31:0] rx_drop_delta = drop_bin_sync - drop_bin_seen;
    wire [32:0] rx_drop_increment = {1'b0, rx_drop_delta} + bad_header_drop;
    wire [31:0] rx_drop_next = rx_drop_increment[32] ? 32'hffff_ffff :
                                sat_add(rx_dropped_count, rx_drop_increment[31:0]);

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            drop_gray_meta <= 0;
            drop_gray_sync1 <= 0;
            drop_gray_sync2 <= 0;
            drop_bin_seen <= 0;
            rx_dropped_count <= 0;
        end else begin
            drop_gray_meta <= rx_drop_gray_eth;
            drop_gray_sync1 <= drop_gray_meta;
            drop_gray_sync2 <= drop_gray_sync1;
            drop_bin_seen <= drop_bin_sync;
            if (rx_drop_increment != 0)
                rx_dropped_count <= rx_drop_next;
        end
    end

    assign m_awaddr = axi_addr_reg;
    assign m_awvalid = state == ST_AXI_WRITE && axi_aw_pending;
    assign m_wdata = axi_wdata_reg;
    assign m_wstrb = 4'hf;
    assign m_wvalid = state == ST_AXI_WRITE && axi_w_pending;
    assign m_bready = state == ST_AXI_WRITE && axi_b_wait;
    assign m_araddr = axi_addr_reg;
    assign m_arvalid = state == ST_AXI_READ && axi_ar_pending;
    assign m_rready = state == ST_AXI_READ && axi_r_wait;

    assign tx_fifo_s_valid = state == ST_TX_META || state == ST_TX_HEADER ||
                             (state == ST_TX_PAYLOAD && tx_skid_valid);
    always @* begin
        tx_fifo_s_data = 128'd0;
        tx_fifo_s_keep = 16'h00ff;
        tx_fifo_s_last = 1'b0;
        if (state == ST_TX_META) begin
            tx_fifo_s_data = {63'd0, 1'b1, (16'd24 + (resp_payload_words << 2)),
                              resp_dst_port, resp_dst_ip};
        end else if (state == ST_TX_HEADER) begin
            case (tx_header_index)
                0: tx_fifo_s_data[63:0] = {resp_seq, resp_opcode, 8'd1, MAGIC};
                1: tx_fifo_s_data[63:0] = {16'd0, resp_count, resp_addr};
                default: tx_fifo_s_data[63:0] = {32'd0, resp_error_index, resp_status};
            endcase
            tx_fifo_s_last = tx_header_index == 2 && resp_payload_words == 0;
        end else if (state == ST_TX_PAYLOAD) begin
            tx_fifo_s_data[63:0] = tx_skid_data;
            if (resp_payload_words[0] && tx_qword_index == response_qword_count - 1'b1)
                tx_fifo_s_keep = 16'h000f;
            tx_fifo_s_last = tx_qword_index == response_qword_count - 1'b1;
        end
    end
    assign tx_fifo_s_user = 1'b0;

    integer info_reset_index;
    always @(posedge host_clk) begin
        if (!host_resetn) begin
            state <= ST_RX_META;
            request_header_0 <= 0;
            request_header_1 <= 0;
            request_header_2 <= 0;
            rx_beat_count <= 0;
            packet_bytes <= 0;
            rx_length_meta <= 0;
            rx_src_ip_meta <= 0;
            rx_src_port_meta <= 0;
            packet_overflow <= 0;
            cmd_opcode <= 0;
            cmd_seq <= 0;
            cmd_addr <= 0;
            cmd_count <= 0;
            cmd_flags <= 0;
            exec_index <= 0;
            done_count <= 0;
            cmd_status <= 0;
            cmd_error_index <= 0;
            axi_addr_reg <= 0;
            axi_wdata_reg <= 0;
            axi_aw_pending <= 0;
            axi_w_pending <= 0;
            axi_ar_pending <= 0;
            axi_b_wait <= 0;
            axi_r_wait <= 0;
            axi_wait_count <= 0;
            pending_read_low <= 0;
            resp_dst_ip <= 0;
            resp_dst_port <= 0;
            resp_opcode <= 0;
            resp_seq <= 0;
            resp_addr <= 0;
            resp_count <= 0;
            resp_status <= 0;
            resp_error_index <= 0;
            resp_payload_words <= 0;
            info_word_index <= 0;
            tx_header_index <= 0;
            tx_qword_index <= 0;
            tx_skid_data <= 0;
            tx_skid_valid <= 0;
            last_write_valid <= 0;
            last_write_seq <= 0;
            last_write_addr <= 0;
            last_write_count <= 0;
            last_write_status <= 0;
            last_write_error <= 0;
            rx_ok_count <= 0;
            rx_bad_req_count <= 0;
            tx_reply_count <= 0;
            dup_write_count <= 0;
            axi_error_count <= 0;
            axi_timeout_count <= 0;
            axi_word_count <= 0;
            for (info_reset_index = 0; info_reset_index < 16; info_reset_index = info_reset_index + 1)
                info_words[info_reset_index] <= 0;
        end else begin
            case (state)
                ST_RX_META: begin
                    if (rx_fifo_m_valid && rx_fifo_m_ready) begin
                        rx_src_ip_meta <= rx_fifo_m_data[31:0];
                        rx_src_port_meta <= rx_fifo_m_data[47:32];
                        rx_length_meta <= rx_fifo_m_data[63:48];
                        packet_bytes <= 0;
                        rx_beat_count <= 0;
                        packet_overflow <= 0;
                        state <= ST_RX_DATA;
                    end
                end
                ST_RX_DATA: begin
                    if (rx_fifo_m_valid && rx_fifo_m_ready) begin
                        case (rx_beat_count)
                            0: request_header_0 <= rx_fifo_m_data[63:0];
                            1: request_header_1 <= rx_fifo_m_data[63:0];
                            2: request_header_2 <= rx_fifo_m_data[63:0];
                            default: begin end
                        endcase
                        packet_bytes <= packet_bytes + keep_byte_count(rx_fifo_m_keep[7:0]);
                        if (rx_beat_count >= (3 + PAYLOAD_QWORDS) ||
                            packet_bytes + keep_byte_count(rx_fifo_m_keep[7:0]) > MAX_BYTES)
                            packet_overflow <= 1'b1;
                        rx_beat_count <= rx_beat_count + 1'b1;
                        if (rx_fifo_m_last)
                            state <= ST_PARSE;
                    end
                end
                ST_PARSE: begin
                    resp_dst_ip <= rx_src_ip_meta;
                    resp_dst_port <= rx_src_port_meta;
                    resp_opcode <= request_opcode | 8'h80;
                    resp_seq <= request_seq;
                    resp_addr <= request_addr;
                    resp_count <= 0;
                    resp_status <= 0;
                    resp_error_index <= 0;
                    resp_payload_words <= 0;
                    if (bad_header_drop) begin
                        state <= ST_RX_META;
                    end else begin
                        cmd_opcode <= request_opcode;
                        cmd_seq <= request_seq;
                        cmd_addr <= request_addr;
                        cmd_count <= request_count;
                        cmd_flags <= request_flags;
                        if (request_opcode != 8'd1 && request_opcode != 8'd2 &&
                            request_opcode != 8'd3 && request_opcode != 8'd4) begin
                            rx_bad_req_count <= sat_inc(rx_bad_req_count);
                            resp_status <= 16'd2;
                            state <= ST_TX_META;
                        end else if ((request_flags & 16'hfffe) != 0 ||
                                     request_status_error != 0 || request_reserved != 0 ||
                                     (request_addr & 32'h0000_0003) != 0) begin
                            rx_bad_req_count <= sat_inc(rx_bad_req_count);
                            resp_status <= 16'd2;
                            state <= ST_TX_META;
                        end else if ((request_opcode == 8'd1 || request_opcode == 8'd2) &&
                                     (request_count == 0 || request_count > MAX_WORDS)) begin
                            rx_bad_req_count <= sat_inc(rx_bad_req_count);
                            resp_status <= 16'd2;
                            state <= ST_TX_META;
                        end else if ((request_opcode == 8'd3 || request_opcode == 8'd4) &&
                                     request_count != 0) begin
                            rx_bad_req_count <= sat_inc(rx_bad_req_count);
                            resp_status <= 16'd2;
                            state <= ST_TX_META;
                        end else if ((request_opcode == 8'd2 &&
                                      rx_length_meta != 24 + (request_count << 2)) ||
                                     (request_opcode != 8'd2 && rx_length_meta != 24) ||
                                     packet_overflow || packet_bytes != rx_length_meta) begin
                            rx_bad_req_count <= sat_inc(rx_bad_req_count);
                            resp_status <= 16'd2;
                            state <= ST_TX_META;
                        end else if (request_opcode == 8'd4) begin
                            rx_ok_count <= sat_inc(rx_ok_count);
                            state <= ST_TX_META;
                        end else if (request_opcode == 8'd3) begin
                            rx_ok_count <= sat_inc(rx_ok_count);
                            resp_count <= 16'd16;
                            resp_payload_words <= 16'd16;
                            info_words[0] <= 32'h4157_4531;
                            info_words[1] <= 32'd1;
                            info_words[2] <= MAX_WORDS;
                            info_words[3] <= BUILD_ID;
                            info_words[4] <= rx_ok_count;
                            info_words[5] <= rx_bad_req_count;
                            info_words[6] <= rx_dropped_count;
                            info_words[7] <= tx_reply_count;
                            info_words[8] <= dup_write_count;
                            info_words[9] <= axi_error_count;
                            info_words[10] <= axi_timeout_count;
                            info_words[11] <= axi_word_count;
                            info_words[12] <= 0;
                            info_words[13] <= 0;
                            info_words[14] <= 0;
                            info_words[15] <= 0;
                            info_word_index <= 0;
                            state <= ST_INFO_FILL;
                        end else if (request_opcode == 8'd2 &&
                                     last_write_valid && request_seq == last_write_seq) begin
                            rx_ok_count <= sat_inc(rx_ok_count);
                            dup_write_count <= sat_inc(dup_write_count);
                            resp_addr <= last_write_addr;
                            resp_count <= last_write_count;
                            resp_status <= last_write_status;
                            resp_error_index <= last_write_error;
                            state <= ST_TX_META;
                        end else begin
                            rx_ok_count <= sat_inc(rx_ok_count);
                            exec_index <= 0;
                            done_count <= 0;
                            cmd_status <= 0;
                            cmd_error_index <= 0;
                            pending_read_low <= 0;
                            state <= ST_EXEC;
                        end
                    end
                end
                ST_EXEC: begin
                    if (cmd_status != 0 || exec_index >= cmd_count) begin
                        resp_count <= done_count;
                        resp_status <= cmd_status;
                        resp_error_index <= cmd_error_index;
                        resp_payload_words <= cmd_opcode == 8'd1 ? done_count : 16'd0;
                        if (cmd_opcode == 8'd2) begin
                            last_write_valid <= 1'b1;
                            last_write_seq <= cmd_seq;
                            last_write_addr <= cmd_addr;
                            last_write_count <= done_count;
                            last_write_status <= cmd_status;
                            last_write_error <= cmd_error_index;
                        end
                        state <= ST_TX_META;
                    end else begin
                        axi_addr_reg <= cmd_addr + (cmd_flags[0] ? 0 : (exec_index << 2));
                        axi_wait_count <= 0;
                        if (cmd_opcode == 8'd2) begin
                            state <= ST_PAYLOAD_WAIT;
                        end else begin
                            axi_ar_pending <= 1'b1;
                            axi_r_wait <= 1'b0;
                            state <= ST_AXI_READ;
                        end
                    end
                end
                ST_PAYLOAD_WAIT: begin
                    axi_wdata_reg <= exec_index[0] ? payload_rd_data[63:32] :
                                                    payload_rd_data[31:0];
                    axi_aw_pending <= 1'b1;
                    axi_w_pending <= 1'b1;
                    axi_b_wait <= 1'b0;
                    state <= ST_AXI_WRITE;
                end
                ST_AXI_WRITE: begin
                    if (axi_aw_pending && m_awready)
                        axi_aw_pending <= 1'b0;
                    if (axi_w_pending && m_wready)
                        axi_w_pending <= 1'b0;
                    if ((!axi_aw_pending || m_awready) &&
                        (!axi_w_pending || m_wready) && !axi_b_wait)
                        axi_b_wait <= 1'b1;
                    if (axi_b_wait && m_bvalid && m_bready) begin
                        axi_b_wait <= 0;
                        axi_word_count <= sat_inc(axi_word_count);
                        if (m_bresp != 0) begin
                            axi_error_count <= sat_inc(axi_error_count);
                            cmd_status <= 16'd1;
                            cmd_error_index <= exec_index;
                            state <= ST_EXEC;
                        end else begin
                            done_count <= done_count + 1'b1;
                            exec_index <= exec_index + 1'b1;
                            if (next_exec_index < cmd_count) begin
                                // The next qword was prefetched during the current
                                // odd-index word's W handshake.
                                axi_addr_reg <= cmd_addr +
                                    (cmd_flags[0] ? 0 : (next_exec_index << 2));
                                axi_wdata_reg <= next_exec_index[0] ?
                                    payload_rd_data[63:32] : payload_rd_data[31:0];
                                axi_aw_pending <= 1'b1;
                                axi_w_pending <= 1'b1;
                                axi_b_wait <= 1'b0;
                                axi_wait_count <= 0;
                                state <= ST_AXI_WRITE;
                            end else begin
                                state <= ST_EXEC;
                            end
                        end
                    end else if (axi_wait_count >= AXI_TIMEOUT_CYCLES-1) begin
                        axi_aw_pending <= 0;
                        axi_w_pending <= 0;
                        axi_b_wait <= 0;
                        axi_timeout_count <= sat_inc(axi_timeout_count);
                        cmd_status <= 16'd3;
                        cmd_error_index <= exec_index;
                        state <= ST_EXEC;
                    end else begin
                        axi_wait_count <= axi_wait_count + 1'b1;
                    end
                end
                ST_AXI_READ: begin
                    if (axi_ar_pending && m_arready) begin
                        axi_ar_pending <= 0;
                        axi_r_wait <= 1'b1;
                    end
                    if (axi_r_wait && m_rvalid && m_rready) begin
                        axi_r_wait <= 0;
                        axi_word_count <= sat_inc(axi_word_count);
                        if (m_rresp != 0) begin
                            axi_error_count <= sat_inc(axi_error_count);
                            cmd_status <= 16'd1;
                            cmd_error_index <= exec_index;
                            state <= ST_EXEC;
                        end else begin
                            if (!exec_index[0])
                                pending_read_low <= m_rdata;
                            done_count <= done_count + 1'b1;
                            exec_index <= exec_index + 1'b1;
                            if (next_exec_index < cmd_count) begin
                                axi_addr_reg <= cmd_addr +
                                    (cmd_flags[0] ? 0 : (next_exec_index << 2));
                                axi_ar_pending <= 1'b1;
                                axi_r_wait <= 1'b0;
                                axi_wait_count <= 0;
                                state <= ST_AXI_READ;
                            end else begin
                                state <= ST_EXEC;
                            end
                        end
                    end else if (axi_wait_count >= AXI_TIMEOUT_CYCLES-1) begin
                        axi_ar_pending <= 0;
                        axi_r_wait <= 0;
                        axi_timeout_count <= sat_inc(axi_timeout_count);
                        cmd_status <= 16'd3;
                        cmd_error_index <= exec_index;
                        state <= ST_EXEC;
                    end else begin
                        axi_wait_count <= axi_wait_count + 1'b1;
                    end
                end
                ST_INFO_FILL: begin
                    if (info_word_index == 14) begin
                        state <= ST_TX_META;
                    end else begin
                        info_word_index <= info_word_index + 2;
                    end
                end
                ST_TX_META: begin
                    if (tx_fifo_s_ready) begin
                        tx_header_index <= 0;
                        tx_skid_valid <= 0;
                        state <= ST_TX_HEADER;
                    end
                end
                ST_TX_HEADER: begin
                    if (tx_fifo_s_ready) begin
                        if (tx_header_index == 2) begin
                            if (resp_payload_words == 0) begin
                                tx_reply_count <= sat_inc(tx_reply_count);
                                state <= ST_RX_META;
                            end else begin
                                tx_qword_index <= 0;
                                state <= ST_TX_READ_REQ;
                            end
                        end else begin
                            tx_header_index <= tx_header_index + 1'b1;
                        end
                    end
                end
                ST_TX_READ_REQ: begin
                    state <= ST_TX_READ_WAIT;
                end
                ST_TX_READ_WAIT: begin
                    tx_skid_data <= response_rd_data;
                    tx_skid_valid <= 1'b1;
                    state <= ST_TX_PAYLOAD;
                end
                ST_TX_PAYLOAD: begin
                    if (tx_skid_valid && tx_fifo_s_ready) begin
                        tx_skid_valid <= 1'b0;
                        if (tx_qword_index + 1'b1 == response_qword_count) begin
                            tx_reply_count <= sat_inc(tx_reply_count);
                            state <= ST_RX_META;
                        end else begin
                            tx_qword_index <= tx_qword_index + 1'b1;
                            state <= ST_TX_READ_REQ;
                        end
                    end
                end
                default: begin
                    state <= ST_RX_META;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
