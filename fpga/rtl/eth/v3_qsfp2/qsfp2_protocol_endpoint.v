`default_nettype none
`timescale 1ns/1ps

// QSFP2 UDP/ARP endpoint with committed RX and TX frame FIFOs.
// The TX frame FIFO is required because the 64-to-256-bit gearbox can
// temporarily deassert TVALID while collecting the next 256-bit word.  The
// L-Ethernet MAC expects a contiguous AXI4-Stream frame and reports underflow
// when that gap cannot be hidden by its internal elastic buffer.
module qsfp2_protocol_endpoint #(
    parameter [47:0] LOCAL_MAC = 48'h024741000002,
    parameter [31:0] LOCAL_IP = 32'hc0a82a02,
    parameter [15:0] LOCAL_UDP_PORT = 16'd9000,
    parameter [31:0] STATIC_ARP_IP = 32'hc0a82a0a,
    parameter [47:0] STATIC_ARP_MAC = 48'h6cb311217d8e,
    parameter integer RX_FIFO_DEPTH = 65536,
    parameter integer TX_FIFO_DEPTH = 65536
) (
    input tri0 biz_path_reset,
    output wire [31:0] biz_tx_tdata,
    output wire biz_tx_tvalid,
    input wire biz_tx_tready,
    output wire biz_tx_tlast,
    input wire [7:0] biz_tx_free_blocks,
    input wire [31:0] biz_rx_tdata,
    input wire biz_rx_tvalid,
    output wire biz_rx_tready,
    input wire biz_rx_tlast, biz_rx_block_avail,
    input wire ctrl_biz_tx_enable, ctrl_echo_enable, ctrl_telem_enable,
    input wire [31:0] ctrl_reasm_timeout_us,
    input wire [15:0] ctrl_telem_period_ms,
    input wire ctrl_clear_stats,
    input wire [31:0] telem_tdata,
    input wire telem_tvalid,
    output wire telem_tready,
    input wire telem_tlast,
    input wire [2:0] telem_flags,
    input wire [31:0] eth_status,
    output wire [1183:0] eth_stats_vec,
    output wire [31:0] udp_rx_other_packets,
    input  wire         clk,
    input  wire         management_locked,
    input  wire         protocol_reset_raw,
    input  wire [255:0] mac_rx_tdata,
    input  wire [31:0]  mac_rx_tkeep,
    input  wire         mac_rx_tvalid,
    input  wire         mac_rx_tlast,
    input  wire         mac_rx_tuser,
    output wire [255:0] mac_tx_tdata,
    output wire [31:0]  mac_tx_tkeep,
    output wire         mac_tx_tvalid,
    input  wire         mac_tx_tready,
    output wire         mac_tx_tlast,
    output wire         mac_tx_tuser,
    output reg          rx_frame_seen,
    output reg          rx_bad_or_drop_seen,
    output reg          tx_frame_accepted_seen,
    output reg          tx_user_seen
);

    wire protocol_rst;

    wire [255:0] rx_fifo_tdata;
    wire [31:0]  rx_fifo_tkeep;
    wire         rx_fifo_tvalid;
    wire         rx_fifo_tready;
    wire         rx_fifo_tlast;
    wire         rx_fifo_tuser;
    wire         rx_fifo_overflow;
    wire         rx_fifo_bad_frame;
    wire         rx_fifo_good_frame;

    wire [255:0] proto_tx_tdata;
    wire [31:0]  proto_tx_tkeep;
    wire         proto_tx_tvalid;
    wire         proto_tx_tready;
    wire         proto_tx_tlast;
    wire         proto_tx_tuser;

    wire tx_fifo_overflow;
    wire tx_fifo_bad_frame;
    wire tx_fifo_good_frame;

    axis_reset_sync #(
        .STAGES (4)
    ) u_protocol_reset (
        .clk  (clk),
        .arst (!management_locked || protocol_reset_raw),
        .srst (protocol_rst)
    );

    // The MAC RX interface does not accept backpressure.  A committed-frame
    // FIFO decouples it from parser stalls and deliberately reports drops.
    axis_fifo #(
        .DEPTH                (RX_FIFO_DEPTH),
        .DATA_WIDTH           (256),
        .KEEP_ENABLE          (1),
        .KEEP_WIDTH           (32),
        .LAST_ENABLE          (1),
        .ID_ENABLE            (0),
        .DEST_ENABLE          (0),
        .USER_ENABLE          (1),
        .USER_WIDTH           (1),
        .FRAME_FIFO           (1),
        .DROP_OVERSIZE_FRAME  (1),
        .DROP_BAD_FRAME       (1),
        .DROP_WHEN_FULL       (1)
    ) u_rx_frame_fifo (
        .clk                 (clk),
        .rst                 (protocol_rst),
        .s_axis_tdata        (mac_rx_tdata),
        .s_axis_tkeep        (mac_rx_tkeep),
        .s_axis_tvalid       (mac_rx_tvalid),
        .s_axis_tready       (),
        .s_axis_tlast        (mac_rx_tlast),
        .s_axis_tid          (8'd0),
        .s_axis_tdest        (8'd0),
        .s_axis_tuser        (mac_rx_tuser),
        .m_axis_tdata        (rx_fifo_tdata),
        .m_axis_tkeep        (rx_fifo_tkeep),
        .m_axis_tvalid       (rx_fifo_tvalid),
        .m_axis_tready       (rx_fifo_tready),
        .m_axis_tlast        (rx_fifo_tlast),
        .m_axis_tid          (),
        .m_axis_tdest        (),
        .m_axis_tuser        (rx_fifo_tuser),
        .pause_req           (1'b0),
        .status_overflow     (rx_fifo_overflow),
        .status_bad_frame    (rx_fifo_bad_frame),
        .status_good_frame   (rx_fifo_good_frame)
    );

    udp_arp_axis256_port #(
        .LOCAL_MAC      (LOCAL_MAC),
        .LOCAL_IP       (LOCAL_IP),
        .LOCAL_UDP_PORT (LOCAL_UDP_PORT),
        .STATIC_ARP_IP  (STATIC_ARP_IP),
        .STATIC_ARP_MAC (STATIC_ARP_MAC)
    ) u_udp_arp_endpoint (
        .biz_tx_tdata(biz_tx_tdata),
        .biz_tx_tvalid(biz_tx_tvalid),
        .biz_tx_tready(biz_tx_tready),
        .biz_tx_tlast(biz_tx_tlast),
        .biz_tx_free_blocks(biz_tx_free_blocks),
        .biz_rx_tdata(biz_rx_tdata),
        .biz_rx_tvalid(biz_rx_tvalid),
        .biz_rx_tready(biz_rx_tready),
        .biz_rx_tlast(biz_rx_tlast),
        .biz_rx_block_avail(biz_rx_block_avail),
        .biz_path_reset(biz_path_reset),.ctrl_biz_tx_enable(ctrl_biz_tx_enable),
        .ctrl_echo_enable(ctrl_echo_enable),
        .ctrl_telem_enable(ctrl_telem_enable),
        .ctrl_reasm_timeout_us(ctrl_reasm_timeout_us),
        .ctrl_telem_period_ms(ctrl_telem_period_ms),
        .ctrl_clear_stats(ctrl_clear_stats),
        .telem_tdata(telem_tdata),
        .telem_tvalid(telem_tvalid),
        .telem_tready(telem_tready),
        .telem_tlast(telem_tlast),
        .telem_flags(telem_flags),
        .eth_status(eth_status),
        .eth_stats_vec(eth_stats_vec),
        .udp_rx_other_packets(udp_rx_other_packets),
        .eth_rx_frame_event(mac_rx_tvalid && mac_rx_tlast),
        .eth_rx_error_event(rx_fifo_bad_frame || rx_fifo_overflow),
        .clk                 (clk),
        .rst                 (protocol_rst),
        .s_axis_tdata        (rx_fifo_tdata),
        .s_axis_tkeep        (rx_fifo_tkeep),
        .s_axis_tvalid       (rx_fifo_tvalid),
        .s_axis_tready       (rx_fifo_tready),
        .s_axis_tlast        (rx_fifo_tlast),
        .s_axis_tuser        (rx_fifo_tuser),
        .m_axis_tdata        (proto_tx_tdata),
        .m_axis_tkeep        (proto_tx_tkeep),
        .m_axis_tvalid       (proto_tx_tvalid),
        .m_axis_tready       (proto_tx_tready),
        .m_axis_tlast        (proto_tx_tlast),
        .m_axis_tuser        (proto_tx_tuser)
    );

    // Commit an entire Ethernet frame before presenting it to the MAC.  This
    // removes the inter-word TVALID gaps created by axis64_to_axis256 while
    // still allowing normal AXI backpressure between frames.
    axis_fifo #(
        .DEPTH                (TX_FIFO_DEPTH),
        .DATA_WIDTH           (256),
        .KEEP_ENABLE          (1),
        .KEEP_WIDTH           (32),
        .LAST_ENABLE          (1),
        .ID_ENABLE            (0),
        .DEST_ENABLE          (0),
        .USER_ENABLE          (1),
        .USER_WIDTH           (1),
        .FRAME_FIFO           (1),
        .DROP_OVERSIZE_FRAME  (0),
        .DROP_BAD_FRAME       (0),
        .DROP_WHEN_FULL       (0)
    ) u_tx_frame_fifo (
        .clk                 (clk),
        .rst                 (protocol_rst),
        .s_axis_tdata        (proto_tx_tdata),
        .s_axis_tkeep        (proto_tx_tkeep),
        .s_axis_tvalid       (proto_tx_tvalid),
        .s_axis_tready       (proto_tx_tready),
        .s_axis_tlast        (proto_tx_tlast),
        .s_axis_tid          (8'd0),
        .s_axis_tdest        (8'd0),
        .s_axis_tuser        (proto_tx_tuser),
        .m_axis_tdata        (mac_tx_tdata),
        .m_axis_tkeep        (mac_tx_tkeep),
        .m_axis_tvalid       (mac_tx_tvalid),
        .m_axis_tready       (mac_tx_tready),
        .m_axis_tlast        (mac_tx_tlast),
        .m_axis_tid          (),
        .m_axis_tdest        (),
        .m_axis_tuser        (mac_tx_tuser),
        .pause_req           (1'b0),
        .status_overflow     (tx_fifo_overflow),
        .status_bad_frame    (tx_fifo_bad_frame),
        .status_good_frame   (tx_fifo_good_frame)
    );

    always @(posedge clk) begin
        if (protocol_rst) begin
            rx_frame_seen <= 1'b0;
            rx_bad_or_drop_seen <= 1'b0;
            tx_frame_accepted_seen <= 1'b0;
            tx_user_seen <= 1'b0;
        end else begin
            if (rx_fifo_good_frame) begin
                rx_frame_seen <= 1'b1;
            end
            if (rx_fifo_bad_frame || rx_fifo_overflow ||
                tx_fifo_bad_frame || tx_fifo_overflow) begin
                rx_bad_or_drop_seen <= 1'b1;
            end
            if (mac_tx_tvalid && mac_tx_tready && mac_tx_tlast) begin
                tx_frame_accepted_seen <= 1'b1;
                if (mac_tx_tuser) begin
                    tx_user_seen <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
