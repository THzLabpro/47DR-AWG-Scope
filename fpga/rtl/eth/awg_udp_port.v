`default_nettype none
`timescale 1ns/1ps

// =============================================================
// 模組：awg_udp_port
// 功能：256-bit MAC AXIS 與 64-bit UDP app 介面的精簡協定橋接
// 時鐘/復位：clk_eth，rst_eth 同步高有效
// 輸入：Ethernet RX frame AXIS、9100 UDP app TX header/payload
// 輸出：Ethernet TX frame AXIS、9100 UDP app RX header/payload
// 關鍵參數：預設身份與靜態 ARP 後備依照 doc/00_ETH_PLAN.md §3
// =============================================================
module awg_udp_port #(
    parameter [47:0] LOCAL_MAC = 48'h024741000002,
    parameter [31:0] LOCAL_IP = 32'hc0a82a02,
    parameter [31:0] STATIC_ARP_IP = 32'hc0a82a0a,
    parameter [47:0] STATIC_ARP_MAC = 48'h6cb311217d8e,
    parameter integer UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH = 32768
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

    output reg  [31:0]  rx_frames,
    output reg  [31:0]  rx_udp_9100,
    output reg  [31:0]  rx_udp_other,
    output reg  [31:0]  rx_non_ip,
    output reg  [31:0]  tx_frames
);

    localparam [15:0] ETH_TYPE_IPV4 = 16'h0800;
    localparam [15:0] UDP_APP_PORT = 16'd9100;
    localparam [31:0] GATEWAY_IP = 32'd0;
    localparam [31:0] SUBNET_MASK = 32'hffffff00;
    localparam [15:0] UDP_HEADER_BYTES = 16'd8;

    function [31:0] saturating_increment;
        input [31:0] value;
        begin
            saturating_increment = (value == 32'hffffffff) ? value : value + 1'b1;
        end
    endfunction

    wire [63:0] rx64_data;
    wire [7:0] rx64_keep;
    wire rx64_valid;
    wire rx64_ready;
    wire rx64_last;
    wire rx64_user;

    wire [47:0] rx_eth_dest_mac;
    wire [47:0] rx_eth_src_mac;
    wire [15:0] rx_eth_type;
    wire rx_eth_hdr_valid;
    wire rx_eth_hdr_ready;
    wire [63:0] rx_eth_payload_data;
    wire [7:0] rx_eth_payload_keep;
    wire rx_eth_payload_valid;
    wire rx_eth_payload_ready;
    wire rx_eth_payload_last;
    wire rx_eth_payload_user;

    wire udp_rx_hdr_valid;
    wire udp_rx_hdr_ready;
    wire [31:0] udp_rx_src_ip;
    wire [31:0] udp_rx_dst_ip;
    wire [15:0] udp_rx_src_port;
    wire [15:0] udp_rx_dst_port;
    wire [15:0] udp_rx_length;
    wire [15:0] udp_rx_checksum;
    wire [63:0] udp_rx_data;
    wire [7:0] udp_rx_keep;
    wire udp_rx_valid;
    wire udp_rx_ready;
    wire udp_rx_last;
    wire udp_rx_user;
    reg udp_rx_forward_reg;

    wire udp_tx_hdr_valid;
    wire udp_tx_hdr_ready;
    wire [63:0] udp_tx_data;
    wire [7:0] udp_tx_keep;
    wire udp_tx_valid;
    wire udp_tx_ready;
    wire udp_tx_last;
    wire udp_tx_user;

    wire [47:0] tx_eth_dest_mac;
    wire [47:0] tx_eth_src_mac;
    wire [15:0] tx_eth_type;
    wire tx_eth_hdr_valid;
    wire tx_eth_hdr_ready;
    wire [63:0] tx_eth_payload_data;
    wire [7:0] tx_eth_payload_keep;
    wire tx_eth_payload_valid;
    wire tx_eth_payload_ready;
    wire tx_eth_payload_last;
    wire tx_eth_payload_user;

    wire [63:0] tx_raw_data;
    wire [7:0] tx_raw_keep;
    wire tx_raw_valid;
    wire tx_raw_ready;
    wire tx_raw_last;
    wire tx_raw_user;

    wire [63:0] tx_padded_data;
    wire [7:0] tx_padded_keep;
    wire tx_padded_valid;
    wire tx_padded_ready;
    wire tx_padded_last;
    wire tx_padded_user;

    wire udp_rx_is_app = (udp_rx_dst_ip == LOCAL_IP) && (udp_rx_dst_port == UDP_APP_PORT);
    wire rx_frame_fire = s_axis_tvalid && s_axis_tready;
    wire rx_eth_hdr_fire = rx_eth_hdr_valid && rx_eth_hdr_ready;
    wire udp_rx_hdr_fire = udp_rx_hdr_valid && udp_rx_hdr_ready;
    wire tx_frame_fire = m_axis_tvalid && m_axis_tready;

    assign rx_hdr_valid = udp_rx_hdr_valid && udp_rx_is_app;
    assign rx_src_ip = udp_rx_src_ip;
    assign rx_src_port = udp_rx_src_port;
    assign rx_length = udp_rx_length - UDP_HEADER_BYTES;
    assign udp_rx_hdr_ready = udp_rx_is_app ? rx_hdr_ready : 1'b1;

    assign rx_payload_tdata = udp_rx_data;
    assign rx_payload_tkeep = udp_rx_keep;
    assign rx_payload_tvalid = udp_rx_valid && udp_rx_forward_reg;
    assign rx_payload_tlast = udp_rx_last;
    assign rx_payload_tuser = udp_rx_user;
    assign udp_rx_ready = udp_rx_forward_reg ? rx_payload_tready : 1'b1;

    assign udp_tx_hdr_valid = tx_hdr_valid;
    assign tx_hdr_ready = udp_tx_hdr_ready;
    assign tx_payload_tready = udp_tx_ready;
    assign udp_tx_data = tx_payload_tdata;
    assign udp_tx_keep = tx_payload_tkeep;
    assign udp_tx_valid = tx_payload_tvalid;
    assign udp_tx_last = tx_payload_tlast;
    assign udp_tx_user = tx_payload_tuser;

    axis256_to_axis64 u_rx_gearbox (
        .clk(clk_eth), .rst(rst_eth),
        .s_tdata(s_axis_tdata), .s_tkeep(s_axis_tkeep),
        .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
        .s_tlast(s_axis_tlast), .s_tuser(s_axis_tuser),
        .m_tdata(rx64_data), .m_tkeep(rx64_keep),
        .m_tvalid(rx64_valid), .m_tready(rx64_ready),
        .m_tlast(rx64_last), .m_tuser(rx64_user)
    );

    eth_axis_rx #(
        .DATA_WIDTH(64), .KEEP_ENABLE(1), .KEEP_WIDTH(8)
    ) u_eth_rx (
        .clk(clk_eth), .rst(rst_eth),
        .s_axis_tdata(rx64_data), .s_axis_tkeep(rx64_keep),
        .s_axis_tvalid(rx64_valid), .s_axis_tready(rx64_ready),
        .s_axis_tlast(rx64_last), .s_axis_tuser(rx64_user),
        .m_eth_hdr_valid(rx_eth_hdr_valid), .m_eth_hdr_ready(rx_eth_hdr_ready),
        .m_eth_dest_mac(rx_eth_dest_mac), .m_eth_src_mac(rx_eth_src_mac),
        .m_eth_type(rx_eth_type),
        .m_eth_payload_axis_tdata(rx_eth_payload_data),
        .m_eth_payload_axis_tkeep(rx_eth_payload_keep),
        .m_eth_payload_axis_tvalid(rx_eth_payload_valid),
        .m_eth_payload_axis_tready(rx_eth_payload_ready),
        .m_eth_payload_axis_tlast(rx_eth_payload_last),
        .m_eth_payload_axis_tuser(rx_eth_payload_user),
        .busy(), .error_header_early_termination()
    );

    udp_complete_64 #(
        .UDP_CHECKSUM_GEN_ENABLE(1),
        .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH),
        .STATIC_ARP_IP(STATIC_ARP_IP),
        .STATIC_ARP_MAC(STATIC_ARP_MAC)
    ) u_udp_complete (
        .clk(clk_eth), .rst(rst_eth),
        .s_eth_hdr_valid(rx_eth_hdr_valid), .s_eth_hdr_ready(rx_eth_hdr_ready),
        .s_eth_dest_mac(rx_eth_dest_mac), .s_eth_src_mac(rx_eth_src_mac),
        .s_eth_type(rx_eth_type),
        .s_eth_payload_axis_tdata(rx_eth_payload_data),
        .s_eth_payload_axis_tkeep(rx_eth_payload_keep),
        .s_eth_payload_axis_tvalid(rx_eth_payload_valid),
        .s_eth_payload_axis_tready(rx_eth_payload_ready),
        .s_eth_payload_axis_tlast(rx_eth_payload_last),
        .s_eth_payload_axis_tuser(rx_eth_payload_user),
        .m_eth_hdr_valid(tx_eth_hdr_valid), .m_eth_hdr_ready(tx_eth_hdr_ready),
        .m_eth_dest_mac(tx_eth_dest_mac), .m_eth_src_mac(tx_eth_src_mac),
        .m_eth_type(tx_eth_type),
        .m_eth_payload_axis_tdata(tx_eth_payload_data),
        .m_eth_payload_axis_tkeep(tx_eth_payload_keep),
        .m_eth_payload_axis_tvalid(tx_eth_payload_valid),
        .m_eth_payload_axis_tready(tx_eth_payload_ready),
        .m_eth_payload_axis_tlast(tx_eth_payload_last),
        .m_eth_payload_axis_tuser(tx_eth_payload_user),

        .s_ip_hdr_valid(1'b0), .s_ip_hdr_ready(),
        .s_ip_dscp(6'd0), .s_ip_ecn(2'd0), .s_ip_length(16'd0),
        .s_ip_ttl(8'd0), .s_ip_protocol(8'd0),
        .s_ip_source_ip(32'd0), .s_ip_dest_ip(32'd0),
        .s_ip_payload_axis_tdata(64'd0), .s_ip_payload_axis_tkeep(8'd0),
        .s_ip_payload_axis_tvalid(1'b0), .s_ip_payload_axis_tready(),
        .s_ip_payload_axis_tlast(1'b0), .s_ip_payload_axis_tuser(1'b0),
        .m_ip_hdr_valid(), .m_ip_hdr_ready(1'b1),
        .m_ip_eth_dest_mac(), .m_ip_eth_src_mac(), .m_ip_eth_type(),
        .m_ip_version(), .m_ip_ihl(), .m_ip_dscp(), .m_ip_ecn(),
        .m_ip_length(), .m_ip_identification(), .m_ip_flags(),
        .m_ip_fragment_offset(), .m_ip_ttl(), .m_ip_protocol(),
        .m_ip_header_checksum(), .m_ip_source_ip(), .m_ip_dest_ip(),
        .m_ip_payload_axis_tdata(), .m_ip_payload_axis_tkeep(),
        .m_ip_payload_axis_tvalid(), .m_ip_payload_axis_tready(1'b1),
        .m_ip_payload_axis_tlast(), .m_ip_payload_axis_tuser(),

        .s_udp_hdr_valid(udp_tx_hdr_valid), .s_udp_hdr_ready(udp_tx_hdr_ready),
        .s_udp_ip_dscp(6'd0), .s_udp_ip_ecn(2'd0), .s_udp_ip_ttl(8'd64),
        .s_udp_ip_source_ip(LOCAL_IP), .s_udp_ip_dest_ip(tx_dst_ip),
        .s_udp_source_port(UDP_APP_PORT), .s_udp_dest_port(tx_dst_port),
        .s_udp_length(tx_length + UDP_HEADER_BYTES), .s_udp_checksum(16'd0),
        .s_udp_payload_axis_tdata(udp_tx_data),
        .s_udp_payload_axis_tkeep(udp_tx_keep),
        .s_udp_payload_axis_tvalid(udp_tx_valid),
        .s_udp_payload_axis_tready(udp_tx_ready),
        .s_udp_payload_axis_tlast(udp_tx_last),
        .s_udp_payload_axis_tuser(udp_tx_user),
        .m_udp_hdr_valid(udp_rx_hdr_valid), .m_udp_hdr_ready(udp_rx_hdr_ready),
        .m_udp_eth_dest_mac(), .m_udp_eth_src_mac(), .m_udp_eth_type(),
        .m_udp_ip_version(), .m_udp_ip_ihl(), .m_udp_ip_dscp(), .m_udp_ip_ecn(),
        .m_udp_ip_length(), .m_udp_ip_identification(), .m_udp_ip_flags(),
        .m_udp_ip_fragment_offset(), .m_udp_ip_ttl(), .m_udp_ip_protocol(),
        .m_udp_ip_header_checksum(), .m_udp_ip_source_ip(udp_rx_src_ip),
        .m_udp_ip_dest_ip(udp_rx_dst_ip), .m_udp_source_port(udp_rx_src_port),
        .m_udp_dest_port(udp_rx_dst_port), .m_udp_length(udp_rx_length),
        .m_udp_checksum(udp_rx_checksum),
        .m_udp_payload_axis_tdata(udp_rx_data),
        .m_udp_payload_axis_tkeep(udp_rx_keep),
        .m_udp_payload_axis_tvalid(udp_rx_valid),
        .m_udp_payload_axis_tready(udp_rx_ready),
        .m_udp_payload_axis_tlast(udp_rx_last),
        .m_udp_payload_axis_tuser(udp_rx_user),
        .ip_rx_busy(), .ip_tx_busy(), .udp_rx_busy(), .udp_tx_busy(),
        .ip_rx_error_header_early_termination(),
        .ip_rx_error_payload_early_termination(), .ip_rx_error_invalid_header(),
        .ip_rx_error_invalid_checksum(), .ip_tx_error_payload_early_termination(),
        .ip_tx_error_arp_failed(), .udp_rx_error_header_early_termination(),
        .udp_rx_error_payload_early_termination(),
        .udp_tx_error_payload_early_termination(),
        .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP),
        .gateway_ip(GATEWAY_IP), .subnet_mask(SUBNET_MASK),
        .clear_arp_cache(1'b0)
    );

    eth_axis_tx #(
        .DATA_WIDTH(64), .KEEP_ENABLE(1), .KEEP_WIDTH(8)
    ) u_eth_tx (
        .clk(clk_eth), .rst(rst_eth),
        .s_eth_hdr_valid(tx_eth_hdr_valid), .s_eth_hdr_ready(tx_eth_hdr_ready),
        .s_eth_dest_mac(tx_eth_dest_mac), .s_eth_src_mac(tx_eth_src_mac),
        .s_eth_type(tx_eth_type),
        .s_eth_payload_axis_tdata(tx_eth_payload_data),
        .s_eth_payload_axis_tkeep(tx_eth_payload_keep),
        .s_eth_payload_axis_tvalid(tx_eth_payload_valid),
        .s_eth_payload_axis_tready(tx_eth_payload_ready),
        .s_eth_payload_axis_tlast(tx_eth_payload_last),
        .s_eth_payload_axis_tuser(tx_eth_payload_user),
        .m_axis_tdata(tx_raw_data), .m_axis_tkeep(tx_raw_keep),
        .m_axis_tvalid(tx_raw_valid), .m_axis_tready(tx_raw_ready),
        .m_axis_tlast(tx_raw_last), .m_axis_tuser(tx_raw_user), .busy()
    );

    awg_eth_frame_pad u_tx_frame_align_pad (
        .clk_eth(clk_eth), .rst_eth(rst_eth),
        .s_tdata(tx_raw_data), .s_tkeep(tx_raw_keep),
        .s_tvalid(tx_raw_valid), .s_tready(tx_raw_ready),
        .s_tlast(tx_raw_last), .s_tuser(tx_raw_user),
        .m_tdata(tx_padded_data), .m_tkeep(tx_padded_keep),
        .m_tvalid(tx_padded_valid), .m_tready(tx_padded_ready),
        .m_tlast(tx_padded_last), .m_tuser(tx_padded_user)
    );

    axis64_to_axis256 u_tx_gearbox (
        .clk(clk_eth), .rst(rst_eth),
        .s_tdata(tx_padded_data), .s_tkeep(tx_padded_keep),
        .s_tvalid(tx_padded_valid), .s_tready(tx_padded_ready),
        .s_tlast(tx_padded_last), .s_tuser(tx_padded_user),
        .m_tdata(m_axis_tdata), .m_tkeep(m_axis_tkeep),
        .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready),
        .m_tlast(m_axis_tlast), .m_tuser(m_axis_tuser)
    );

    always @(posedge clk_eth) begin
        if (rst_eth) begin
            udp_rx_forward_reg <= 1'b0;
            rx_frames <= 32'd0;
            rx_udp_9100 <= 32'd0;
            rx_udp_other <= 32'd0;
            rx_non_ip <= 32'd0;
            tx_frames <= 32'd0;
        end else begin
            if (rx_frame_fire && s_axis_tlast)
                rx_frames <= saturating_increment(rx_frames);

            if (rx_eth_hdr_fire && rx_eth_type != ETH_TYPE_IPV4)
                rx_non_ip <= saturating_increment(rx_non_ip);

            if (udp_rx_hdr_fire) begin
                if (udp_rx_is_app) begin
                    rx_udp_9100 <= saturating_increment(rx_udp_9100);
                    udp_rx_forward_reg <= (udp_rx_length != UDP_HEADER_BYTES);
                end else begin
                    if (udp_rx_dst_ip == LOCAL_IP)
                        rx_udp_other <= saturating_increment(rx_udp_other);
                    udp_rx_forward_reg <= 1'b0;
                end
            end

            if (udp_rx_forward_reg && udp_rx_valid && udp_rx_ready && udp_rx_last)
                udp_rx_forward_reg <= 1'b0;

            if (tx_frame_fire && m_axis_tlast)
                tx_frames <= saturating_increment(tx_frames);
        end
    end

endmodule

`default_nettype wire
