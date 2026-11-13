`default_nettype none
`timescale 1ns/1ps

// =============================================================
// 模块：udp_arp_axis256_port_v3
// 功能：连接 256 bit MAC AXIS、以太网解析器、UDP 栈和 RFU3 应用
// 时钟/复位：clk_eth，rst_eth 同步高有效
// 输入：MAC RX AXIS、UDP 控制、RFU3 RX 块流
// 输出：MAC TX AXIS、RFU3 TX 块流和 ETH 统计
// 关键参数：静态 ARP 192.168.42.10，UDP app 版本 v3
// 来源基线：v2 src/qsfp2/rtl/udp_arp_axis256_port.v
// =============================================================
module udp_arp_axis256_port_v3 #(
    parameter [47:0] LOCAL_MAC = 48'h024741000002,
    parameter [31:0] LOCAL_IP = 32'hc0a82a02,
    parameter [31:0] STATIC_ARP_IP = 32'hc0a82a0a,
    parameter [47:0] STATIC_ARP_MAC = 48'h6cb311217d8e,
    parameter integer INGRESS_FIFO_BYTES = 1048576
) (
    input  wire         clk_eth,
    input  wire         rst_eth,
    input  wire [255:0] s_axis_tdata,
    input  wire [31:0]  s_axis_tkeep,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,
    output wire [255:0] m_axis_tdata,
    output wire [31:0]  m_axis_tkeep,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire         m_axis_tuser,
    input  wire         ctrl_biz_tx_enable,
    input  wire         ctrl_echo_enable,
    input  wire         ctrl_telem_enable,
    input  wire [31:0]  ctrl_reasm_timeout_us,
    input  wire [15:0]  ctrl_telem_period_ms,
    input  wire         ctrl_clear_stats,
    input  wire [607:0] stats_vector,
    input  wire         rx_bad_frame_event,
    input  wire         rx_fifo_ovf_event,
    output wire [639:0] eth_stats_vector,
    output wire [31:0] ingress_buffered_bytes,
    output wire [127:0] flowctrl_stats_vector,
    output wire [63:0]  biz_tx_tdata,
    output wire [7:0]   biz_tx_tkeep,
    output wire         biz_tx_tvalid,
    input  wire         biz_tx_tready,
    input  wire [7:0]   biz_tx_free_blocks,
    output wire         biz_tx_tlast,
    input  wire [63:0]  biz_rx_tdata,
    input  wire [7:0]   biz_rx_tkeep,
    input  wire         biz_rx_tvalid,
    output wire         biz_rx_tready,
    input  wire         biz_rx_tlast
);
    wire [63:0] rx64_data;
    wire [7:0] rx64_keep;
    wire rx64_valid;
    wire rx64_ready;
    wire rx64_last;
    wire rx64_user;
    wire [47:0] rx_dest_mac;
    wire [47:0] rx_src_mac;
    wire [15:0] rx_eth_type;
    wire rx_eth_hdr_valid;
    wire rx_eth_hdr_ready;
    wire [63:0] rx_eth_data;
    wire [7:0] rx_eth_keep;
    wire rx_eth_valid;
    wire rx_eth_ready;
    wire rx_eth_last;
    wire rx_eth_user;
    wire [47:0] tx_dest_mac;
    wire [47:0] tx_src_mac;
    wire [15:0] tx_eth_type;
    wire tx_eth_hdr_valid;
    wire tx_eth_hdr_ready;
    wire [63:0] tx_eth_data;
    wire [7:0] tx_eth_keep;
    wire tx_eth_valid;
    wire tx_eth_ready;
    wire tx_eth_last;
    wire tx_eth_user;
    wire [63:0] tx_raw_data;
    wire [7:0] tx_raw_keep;
    wire tx_raw_valid;
    wire tx_raw_ready;
    wire tx_raw_last;
    wire tx_raw_user;
    wire [63:0] tx_pad_data;
    wire [7:0] tx_pad_keep;
    wire tx_pad_valid;
    wire tx_pad_ready;
    wire tx_pad_last;
    wire tx_pad_user;
    wire [31:0] udp_rx_source_ip;
    wire [31:0] udp_rx_dest_ip;
    wire [15:0] udp_rx_source_port;
    wire [15:0] udp_rx_dest_port;
    wire [15:0] udp_rx_length;
    wire [15:0] udp_rx_checksum;
    wire udp_rx_hdr_valid;
    wire udp_rx_hdr_ready;
    wire [63:0] udp_rx_data;
    wire [7:0] udp_rx_keep;
    wire udp_rx_valid;
    wire udp_rx_ready;
    wire udp_rx_last;
    wire udp_rx_user;
    wire [31:0] udp_tx_source_ip;
    wire [31:0] udp_tx_dest_ip;
    wire [15:0] udp_tx_source_port;
    wire [15:0] udp_tx_dest_port;
    wire [15:0] udp_tx_length;
    wire [15:0] udp_tx_checksum;
    wire udp_tx_hdr_valid;
    wire udp_tx_hdr_ready;
    wire [63:0] udp_tx_data;
    wire [7:0] udp_tx_keep;
    wire udp_tx_valid;
    wire udp_tx_ready;
    wire udp_tx_last;
    wire udp_tx_user;
    wire [3:0] ip_rx_errors;
    wire [1:0] udp_rx_errors;
    wire [2:0] tx_errors;
    wire [63:0] app_tx_block_data;
    wire [7:0] app_tx_block_keep;
    wire app_tx_block_valid;
    wire app_tx_block_ready;
    wire app_tx_block_last;
    wire app_rx_block_ready;
    wire app_eth_rx_event;
    wire app_eth_bad_event;
    wire app_arp_rx_event;
    wire app_arp_tx_event;

    axis256_to_axis64 u_rx_gearbox (
        .clk(clk_eth), .rst(rst_eth),
        .s_tdata(s_axis_tdata), .s_tkeep(s_axis_tkeep),
        .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
        .s_tlast(s_axis_tlast), .s_tuser(s_axis_tuser),
        .m_tdata(rx64_data), .m_tkeep(rx64_keep), .m_tvalid(rx64_valid),
        .m_tready(rx64_ready), .m_tlast(rx64_last), .m_tuser(rx64_user)
    );

    eth_axis_rx #(.DATA_WIDTH(64), .KEEP_ENABLE(1), .KEEP_WIDTH(8)) u_eth_rx (
        .clk(clk_eth), .rst(rst_eth),
        .s_axis_tdata(rx64_data), .s_axis_tkeep(rx64_keep),
        .s_axis_tvalid(rx64_valid), .s_axis_tready(rx64_ready),
        .s_axis_tlast(rx64_last), .s_axis_tuser(rx64_user),
        .m_eth_hdr_valid(rx_eth_hdr_valid), .m_eth_hdr_ready(rx_eth_hdr_ready),
        .m_eth_dest_mac(rx_dest_mac), .m_eth_src_mac(rx_src_mac), .m_eth_type(rx_eth_type),
        .m_eth_payload_axis_tdata(rx_eth_data), .m_eth_payload_axis_tkeep(rx_eth_keep),
        .m_eth_payload_axis_tvalid(rx_eth_valid), .m_eth_payload_axis_tready(rx_eth_ready),
        .m_eth_payload_axis_tlast(rx_eth_last), .m_eth_payload_axis_tuser(rx_eth_user),
        .busy(), .error_header_early_termination()
    );

    rfudp_eth_app_v3 #(.LOCAL_IP(LOCAL_IP), .INGRESS_FIFO_BYTES(INGRESS_FIFO_BYTES)) app (
        .clk_eth(clk_eth), .rst(rst_eth),
        .ctrl_biz_tx_enable(ctrl_biz_tx_enable), .ctrl_echo_enable(ctrl_echo_enable),
        .ctrl_telem_enable(ctrl_telem_enable), .ctrl_reasm_timeout_us(ctrl_reasm_timeout_us),
        .ctrl_telem_period_ms(ctrl_telem_period_ms), .ctrl_clear_stats(ctrl_clear_stats),
        .stats_vector(stats_vector), .eth_rx_event(app_eth_rx_event),
        .eth_bad_event(app_eth_bad_event), .arp_rx_event(app_arp_rx_event),
        .arp_tx_event(app_arp_tx_event), .rx_fifo_ovf_event(rx_fifo_ovf_event),
        .biz_tx_free_blocks(biz_tx_free_blocks),
        .eth_stats_vector(eth_stats_vector),
        .ingress_buffered_bytes(ingress_buffered_bytes), .flowctrl_stats_vector(flowctrl_stats_vector),
        .s_hdr_valid(udp_rx_hdr_valid), .s_hdr_ready(udp_rx_hdr_ready),
        .s_source_ip(udp_rx_source_ip), .s_dest_ip(udp_rx_dest_ip),
        .s_source_port(udp_rx_source_port), .s_dest_port(udp_rx_dest_port),
        .s_length(udp_rx_length), .s_checksum(udp_rx_checksum),
        .s_data(udp_rx_data), .s_keep(udp_rx_keep), .s_valid(udp_rx_valid),
        .s_ready(udp_rx_ready), .s_last(udp_rx_last), .s_user(udp_rx_user),
        .m_hdr_valid(udp_tx_hdr_valid), .m_hdr_ready(udp_tx_hdr_ready),
        .m_source_ip(udp_tx_source_ip), .m_dest_ip(udp_tx_dest_ip),
        .m_source_port(udp_tx_source_port), .m_dest_port(udp_tx_dest_port),
        .m_length(udp_tx_length), .m_checksum(udp_tx_checksum),
        .m_data(udp_tx_data), .m_keep(udp_tx_keep), .m_valid(udp_tx_valid),
        .m_ready(udp_tx_ready), .m_last(udp_tx_last),
        .biz_tx_tdata(app_tx_block_data), .biz_tx_tkeep(app_tx_block_keep),
        .biz_tx_tvalid(app_tx_block_valid), .biz_tx_tready(app_tx_block_ready),
        .biz_tx_tlast(app_tx_block_last), .biz_rx_tdata(biz_rx_tdata),
        .biz_rx_tkeep(biz_rx_tkeep), .biz_rx_tvalid(biz_rx_tvalid),
        .biz_rx_tready(app_rx_block_ready), .biz_rx_tlast(biz_rx_tlast)
    );
    assign biz_tx_tdata = app_tx_block_data;
    assign biz_tx_tkeep = app_tx_block_keep;
    assign biz_tx_tvalid = app_tx_block_valid;
    assign app_tx_block_ready = biz_tx_tready;
    assign biz_tx_tlast = app_tx_block_last;
    assign biz_rx_tready = app_rx_block_ready;

    assign app_eth_rx_event = s_axis_tvalid && s_axis_tready && s_axis_tlast;
    assign app_eth_bad_event = rx_bad_frame_event ||
                              (s_axis_tvalid && s_axis_tready && s_axis_tlast && s_axis_tuser);
    assign app_arp_rx_event = rx_eth_hdr_valid && rx_eth_hdr_ready && rx_eth_type == 16'h0806;
    assign app_arp_tx_event = tx_eth_hdr_valid && tx_eth_hdr_ready && tx_eth_type == 16'h0806;

    udp_complete_64 #(
        .STATIC_ARP_IP(STATIC_ARP_IP), .STATIC_ARP_MAC(STATIC_ARP_MAC)
    ) u_udp_complete (
        .clk(clk_eth), .rst(rst_eth),
        .s_eth_hdr_valid(rx_eth_hdr_valid), .s_eth_hdr_ready(rx_eth_hdr_ready),
        .s_eth_dest_mac(rx_dest_mac), .s_eth_src_mac(rx_src_mac), .s_eth_type(rx_eth_type),
        .s_eth_payload_axis_tdata(rx_eth_data), .s_eth_payload_axis_tkeep(rx_eth_keep),
        .s_eth_payload_axis_tvalid(rx_eth_valid), .s_eth_payload_axis_tready(rx_eth_ready),
        .s_eth_payload_axis_tlast(rx_eth_last), .s_eth_payload_axis_tuser(rx_eth_user),
        .m_eth_hdr_valid(tx_eth_hdr_valid), .m_eth_hdr_ready(tx_eth_hdr_ready),
        .m_eth_dest_mac(tx_dest_mac), .m_eth_src_mac(tx_src_mac), .m_eth_type(tx_eth_type),
        .m_eth_payload_axis_tdata(tx_eth_data), .m_eth_payload_axis_tkeep(tx_eth_keep),
        .m_eth_payload_axis_tvalid(tx_eth_valid), .m_eth_payload_axis_tready(tx_eth_ready),
        .m_eth_payload_axis_tlast(tx_eth_last), .m_eth_payload_axis_tuser(tx_eth_user),
        .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP), .gateway_ip(32'd0),
        .subnet_mask(32'hffffff00), .clear_arp_cache(1'b0),
        .s_udp_hdr_valid(udp_tx_hdr_valid), .s_udp_hdr_ready(udp_tx_hdr_ready),
        .s_udp_ip_dscp(6'd0), .s_udp_ip_ecn(2'd0), .s_udp_ip_ttl(8'd64),
        .s_udp_ip_source_ip(udp_tx_source_ip), .s_udp_ip_dest_ip(udp_tx_dest_ip),
        .s_udp_source_port(udp_tx_source_port), .s_udp_dest_port(udp_tx_dest_port),
        .s_udp_length(udp_tx_length), .s_udp_checksum(udp_tx_checksum),
        .s_udp_payload_axis_tdata(udp_tx_data), .s_udp_payload_axis_tkeep(udp_tx_keep),
        .s_udp_payload_axis_tvalid(udp_tx_valid), .s_udp_payload_axis_tready(udp_tx_ready),
        .s_udp_payload_axis_tlast(udp_tx_last), .s_udp_payload_axis_tuser(1'b0),
        .m_udp_hdr_valid(udp_rx_hdr_valid), .m_udp_hdr_ready(udp_rx_hdr_ready),
        .m_udp_ip_dscp(), .m_udp_ip_ecn(), .m_udp_ip_ttl(),
        .m_udp_ip_source_ip(udp_rx_source_ip), .m_udp_ip_dest_ip(udp_rx_dest_ip),
        .m_udp_source_port(udp_rx_source_port), .m_udp_dest_port(udp_rx_dest_port),
        .m_udp_length(udp_rx_length), .m_udp_checksum(udp_rx_checksum),
        .m_udp_payload_axis_tdata(udp_rx_data), .m_udp_payload_axis_tkeep(udp_rx_keep),
        .m_udp_payload_axis_tvalid(udp_rx_valid), .m_udp_payload_axis_tready(udp_rx_ready),
        .m_udp_payload_axis_tlast(udp_rx_last), .m_udp_payload_axis_tuser(udp_rx_user),
        .s_ip_hdr_valid(1'b0), .m_ip_hdr_ready(1'b1), .m_ip_payload_axis_tready(1'b1),
        .ip_rx_error_header_early_termination(ip_rx_errors[0]),
        .ip_rx_error_payload_early_termination(ip_rx_errors[1]),
        .ip_rx_error_invalid_header(ip_rx_errors[2]),
        .ip_rx_error_invalid_checksum(ip_rx_errors[3]),
        .udp_rx_error_header_early_termination(udp_rx_errors[0]),
        .udp_rx_error_payload_early_termination(udp_rx_errors[1]),
        .ip_tx_error_payload_early_termination(tx_errors[0]),
        .ip_tx_error_arp_failed(tx_errors[1]),
        .udp_tx_error_payload_early_termination(tx_errors[2])
    );

    eth_axis_tx #(.DATA_WIDTH(64), .KEEP_ENABLE(1), .KEEP_WIDTH(8)) u_eth_tx (
        .clk(clk_eth), .rst(rst_eth),
        .s_eth_hdr_valid(tx_eth_hdr_valid), .s_eth_hdr_ready(tx_eth_hdr_ready),
        .s_eth_dest_mac(tx_dest_mac), .s_eth_src_mac(tx_src_mac), .s_eth_type(tx_eth_type),
        .s_eth_payload_axis_tdata(tx_eth_data), .s_eth_payload_axis_tkeep(tx_eth_keep),
        .s_eth_payload_axis_tvalid(tx_eth_valid), .s_eth_payload_axis_tready(tx_eth_ready),
        .s_eth_payload_axis_tlast(tx_eth_last), .s_eth_payload_axis_tuser(tx_eth_user),
        .m_axis_tdata(tx_raw_data), .m_axis_tkeep(tx_raw_keep),
        .m_axis_tvalid(tx_raw_valid), .m_axis_tready(tx_raw_ready),
        .m_axis_tlast(tx_raw_last), .m_axis_tuser(tx_raw_user), .busy()
    );

    axis_eth_frame_pad_64_registered #(.MIN_FRAME_BYTES(16'd60)) u_tx_pad (
        .clk(clk_eth), .rst(rst_eth),
        .s_tdata(tx_raw_data), .s_tkeep(tx_raw_keep), .s_tvalid(tx_raw_valid),
        .s_tready(tx_raw_ready), .s_tlast(tx_raw_last), .s_tuser(tx_raw_user),
        .m_tdata(tx_pad_data), .m_tkeep(tx_pad_keep), .m_tvalid(tx_pad_valid),
        .m_tready(tx_pad_ready), .m_tlast(tx_pad_last), .m_tuser(tx_pad_user)
    );

    axis64_to_axis256 u_tx_gearbox (
        .clk(clk_eth), .rst(rst_eth),
        .s_tdata(tx_pad_data), .s_tkeep(tx_pad_keep), .s_tvalid(tx_pad_valid),
        .s_tready(tx_pad_ready), .s_tlast(tx_pad_last), .s_tuser(tx_pad_user),
        .m_tdata(m_axis_tdata), .m_tkeep(m_axis_tkeep), .m_tvalid(m_axis_tvalid),
        .m_tready(m_axis_tready), .m_tlast(m_axis_tlast), .m_tuser(m_axis_tuser)
    );
endmodule

`default_nettype wire
