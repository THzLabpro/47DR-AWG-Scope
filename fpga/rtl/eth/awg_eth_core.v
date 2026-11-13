`default_nettype none
`timescale 1ns/1ps

// =============================================================
// 模組：awg_eth_core
// 功能：QSFP2 40GbE MAC、frame FIFO 與 AWG UDP app 介面的整合頂層
// 時鐘/復位：MAC 輸出 clk_eth；rst_eth 為同步釋放的高有效復位
// 輸入：QSFP2 管腳、sys_reset 與 §4.1 UDP app TX
// 輸出：QSFP2 管腳、§4.1 UDP app RX、MAC lock/alignment 與狀態計數
// 關鍵參數：LOCAL_MAC/IP 與靜態 ARP 後備依照 doc/00_ETH_PLAN.md §3
// =============================================================
module awg_eth_core #(
    parameter [47:0] LOCAL_MAC = 48'h024741000002,
    parameter [31:0] LOCAL_IP = 32'hc0a82a02,
    parameter [31:0] STATIC_ARP_IP = 32'hc0a82a0a,
    parameter [47:0] STATIC_ARP_MAC = 48'h6cb311217d8e,
    parameter integer RX_FIFO_DEPTH = 131072,
    parameter integer TX_FIFO_DEPTH = 65536,
    parameter integer UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH = 32768
) (
    output wire       qsfp2_reset_n,
    output wire       qsfp2_lpmode,
    output wire       qsfp2_modsel_n,
    input  wire       qsfp2_refclk_p,
    input  wire       qsfp2_refclk_n,
    input  wire [3:0] qsfp2_rx_p,
    input  wire [3:0] qsfp2_rx_n,
    output wire [3:0] qsfp2_tx_p,
    output wire [3:0] qsfp2_tx_n,

    input  wire       sys_reset,
    output wire       clk_eth,
    output wire       rst_eth,

    output wire         rx_hdr_valid,
    input  wire         rx_hdr_ready,
    output wire [31:0]  rx_src_ip,
    output wire [15:0]  rx_src_port,
    output wire [15:0]  rx_length,
    output wire [63:0]  rx_payload_tdata,
    output wire [7:0]   rx_payload_tkeep,
    output wire         rx_payload_tvalid,
    input  wire         rx_payload_tready,
    output wire         rx_payload_tlast,
    output wire         rx_payload_tuser,

    input  wire         tx_hdr_valid,
    output wire         tx_hdr_ready,
    input  wire [31:0]  tx_dst_ip,
    input  wire [15:0]  tx_dst_port,
    input  wire [15:0]  tx_length,
    input  wire [63:0]  tx_payload_tdata,
    input  wire [7:0]   tx_payload_tkeep,
    input  wire         tx_payload_tvalid,
    output wire         tx_payload_tready,
    input  wire         tx_payload_tlast,
    input  wire         tx_payload_tuser,

    output wire         rx_gt_locked,
    output wire         rx_aligned,
    output wire [31:0]  rx_frames,
    output wire [31:0]  rx_udp_9100,
    output wire [31:0]  rx_udp_other,
    output wire [31:0]  rx_non_ip,
    output wire [31:0]  tx_frames
);

    localparam integer FRAME_DATA_WIDTH = 256;
    localparam integer FRAME_KEEP_WIDTH = 32;

    wire reference_clock;
    wire management_clock;
    wire management_locked;
    wire protocol_reset;

    wire [255:0] mac_rx_tdata;
    wire [31:0] mac_rx_tkeep;
    wire mac_rx_tvalid;
    wire mac_rx_tlast;
    wire mac_rx_tuser;

    wire [255:0] mac_tx_tdata;
    wire [31:0] mac_tx_tkeep;
    wire mac_tx_tvalid;
    wire mac_tx_tready;
    wire mac_tx_tlast;
    wire mac_tx_tuser;

    wire [255:0] rx_fifo_tdata;
    wire [31:0] rx_fifo_tkeep;
    wire rx_fifo_tvalid;
    wire rx_fifo_tready;
    wire rx_fifo_tlast;
    wire rx_fifo_tuser;
    wire rx_fifo_overflow;
    wire rx_fifo_bad_frame;
    wire rx_fifo_good_frame;

    wire [255:0] port_tx_tdata;
    wire [31:0] port_tx_tkeep;
    wire port_tx_tvalid;
    wire port_tx_tready;
    wire port_tx_tlast;
    wire port_tx_tuser;

    wire [255:0] tx_fifo_tdata;
    wire [31:0] tx_fifo_tkeep;
    wire tx_fifo_tvalid;
    wire tx_fifo_tready;
    wire tx_fifo_tlast;
    wire tx_fifo_tuser;
    wire tx_fifo_overflow;
    wire tx_fifo_bad_frame;
    wire tx_fifo_good_frame;

    wire eth_arst_n;
    wire [4:0] mac_completion_status;

    demo_management_clock u_management_clock (
        .clk_in1(reference_clock), .clk_out1(management_clock),
        .reset(1'b0), .locked(management_locked)
    );

    optical_port2_exdes u_qsfp2_mac (
        .gt_rxp_in_0(qsfp2_rx_p[0]), .gt_rxn_in_0(qsfp2_rx_n[0]),
        .gt_txp_out_0(qsfp2_tx_p[0]), .gt_txn_out_0(qsfp2_tx_n[0]),
        .gt_rxp_in_1(qsfp2_rx_p[1]), .gt_rxn_in_1(qsfp2_rx_n[1]),
        .gt_txp_out_1(qsfp2_tx_p[1]), .gt_txn_out_1(qsfp2_tx_n[1]),
        .gt_rxp_in_2(qsfp2_rx_p[2]), .gt_rxn_in_2(qsfp2_rx_n[2]),
        .gt_txp_out_2(qsfp2_tx_p[2]), .gt_txn_out_2(qsfp2_tx_n[2]),
        .gt_rxp_in_3(qsfp2_rx_p[3]), .gt_rxn_in_3(qsfp2_rx_n[3]),
        .gt_txp_out_3(qsfp2_tx_p[3]), .gt_txn_out_3(qsfp2_tx_n[3]),
        .send_continuous_pkts_0(1'b0), .internal_loopback(1'b0),
        .external_tx_enable(1'b1), .external_tx_valid(mac_tx_tvalid),
        .external_tx_data(mac_tx_tdata), .external_tx_keep(mac_tx_tkeep),
        .external_tx_last(mac_tx_tlast), .external_tx_user(mac_tx_tuser),
        .external_tx_ready(mac_tx_tready), .external_rx_valid(mac_rx_tvalid),
        .external_rx_data(mac_rx_tdata), .external_rx_keep(mac_rx_tkeep),
        .external_rx_last(mac_rx_tlast), .external_rx_user(mac_rx_tuser),
        .rx_gt_locked_led(rx_gt_locked), .rx_aligned_led(rx_aligned),
        .completion_status(mac_completion_status),
        .sys_reset(sys_reset || !management_locked), .restart_tx_rx(1'b0),
        .gt_refclk_p(qsfp2_refclk_p), .gt_refclk_n(qsfp2_refclk_n),
        .reference_clock(reference_clock), .diagnostic_clock(),
        .diagnostic_levels(), .protocol_clock(clk_eth),
        .protocol_reset(protocol_reset), .dclk(management_clock)
    );

    assign qsfp2_reset_n = 1'b1;
    assign qsfp2_lpmode = 1'b0;
    assign qsfp2_modsel_n = 1'b0;

    xpm_cdc_async_rst #(
        .DEST_SYNC_FF(4), .INIT_SYNC_FF(0), .RST_ACTIVE_HIGH(0)
    ) u_eth_reset (
        .dest_arst(eth_arst_n), .dest_clk(clk_eth),
        .src_arst(~(sys_reset || !management_locked || protocol_reset))
    );
    assign rst_eth = !eth_arst_n;

    axis_fifo #(
        .DEPTH(RX_FIFO_DEPTH), .DATA_WIDTH(FRAME_DATA_WIDTH),
        .KEEP_ENABLE(1), .KEEP_WIDTH(FRAME_KEEP_WIDTH), .LAST_ENABLE(1),
        .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
        .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(1),
        .DROP_WHEN_FULL(1)
    ) u_rx_frame_fifo (
        .clk(clk_eth), .rst(rst_eth),
        .s_axis_tdata(mac_rx_tdata), .s_axis_tkeep(mac_rx_tkeep),
        .s_axis_tvalid(mac_rx_tvalid), .s_axis_tready(),
        .s_axis_tlast(mac_rx_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0),
        .s_axis_tuser(mac_rx_tuser),
        .m_axis_tdata(rx_fifo_tdata), .m_axis_tkeep(rx_fifo_tkeep),
        .m_axis_tvalid(rx_fifo_tvalid), .m_axis_tready(rx_fifo_tready),
        .m_axis_tlast(rx_fifo_tlast), .m_axis_tid(), .m_axis_tdest(),
        .m_axis_tuser(rx_fifo_tuser), .pause_req(1'b0),
        .status_overflow(rx_fifo_overflow), .status_bad_frame(rx_fifo_bad_frame),
        .status_good_frame(rx_fifo_good_frame)
    );

    awg_udp_port #(
        .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP),
        .STATIC_ARP_IP(STATIC_ARP_IP), .STATIC_ARP_MAC(STATIC_ARP_MAC),
        .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH)
    ) u_udp_port (
        .clk_eth(clk_eth), .rst_eth(rst_eth),
        .s_axis_tdata(rx_fifo_tdata), .s_axis_tkeep(rx_fifo_tkeep),
        .s_axis_tvalid(rx_fifo_tvalid), .s_axis_tready(rx_fifo_tready),
        .s_axis_tlast(rx_fifo_tlast), .s_axis_tuser(rx_fifo_tuser),
        .m_axis_tdata(port_tx_tdata), .m_axis_tkeep(port_tx_tkeep),
        .m_axis_tvalid(port_tx_tvalid), .m_axis_tready(port_tx_tready),
        .m_axis_tlast(port_tx_tlast), .m_axis_tuser(port_tx_tuser),
        .rx_hdr_valid(rx_hdr_valid), .rx_hdr_ready(rx_hdr_ready),
        .rx_src_ip(rx_src_ip), .rx_src_port(rx_src_port), .rx_length(rx_length),
        .rx_payload_tdata(rx_payload_tdata), .rx_payload_tkeep(rx_payload_tkeep),
        .rx_payload_tvalid(rx_payload_tvalid),
        .rx_payload_tready(rx_payload_tready),
        .rx_payload_tlast(rx_payload_tlast), .rx_payload_tuser(rx_payload_tuser),
        .tx_hdr_valid(tx_hdr_valid), .tx_hdr_ready(tx_hdr_ready),
        .tx_dst_ip(tx_dst_ip), .tx_dst_port(tx_dst_port), .tx_length(tx_length),
        .tx_payload_tdata(tx_payload_tdata), .tx_payload_tkeep(tx_payload_tkeep),
        .tx_payload_tvalid(tx_payload_tvalid),
        .tx_payload_tready(tx_payload_tready),
        .tx_payload_tlast(tx_payload_tlast), .tx_payload_tuser(tx_payload_tuser),
        .rx_frames(rx_frames), .rx_udp_9100(rx_udp_9100),
        .rx_udp_other(rx_udp_other), .rx_non_ip(rx_non_ip), .tx_frames(tx_frames)
    );

    axis_fifo #(
        .DEPTH(TX_FIFO_DEPTH), .DATA_WIDTH(FRAME_DATA_WIDTH),
        .KEEP_ENABLE(1), .KEEP_WIDTH(FRAME_KEEP_WIDTH), .LAST_ENABLE(1),
        .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
        .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(0), .DROP_BAD_FRAME(0),
        .DROP_WHEN_FULL(0)
    ) u_tx_frame_fifo (
        .clk(clk_eth), .rst(rst_eth),
        .s_axis_tdata(port_tx_tdata), .s_axis_tkeep(port_tx_tkeep),
        .s_axis_tvalid(port_tx_tvalid), .s_axis_tready(port_tx_tready),
        .s_axis_tlast(port_tx_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0),
        .s_axis_tuser(port_tx_tuser),
        .m_axis_tdata(tx_fifo_tdata), .m_axis_tkeep(tx_fifo_tkeep),
        .m_axis_tvalid(tx_fifo_tvalid), .m_axis_tready(tx_fifo_tready),
        .m_axis_tlast(tx_fifo_tlast), .m_axis_tid(), .m_axis_tdest(),
        .m_axis_tuser(tx_fifo_tuser), .pause_req(1'b0),
        .status_overflow(tx_fifo_overflow), .status_bad_frame(tx_fifo_bad_frame),
        .status_good_frame(tx_fifo_good_frame)
    );

    assign mac_tx_tdata = tx_fifo_tdata;
    assign mac_tx_tkeep = tx_fifo_tkeep;
    assign mac_tx_tvalid = tx_fifo_tvalid;
    assign mac_tx_tlast = tx_fifo_tlast;
    assign mac_tx_tuser = tx_fifo_tuser;
    assign tx_fifo_tready = mac_tx_tready;

endmodule

`default_nettype wire
