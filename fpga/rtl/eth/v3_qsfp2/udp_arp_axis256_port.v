`default_nettype none
`timescale 1ns/1ps

// Native 256-bit Ethernet endpoint for a four-lane 40GbE L-Ethernet MAC.
// The protocol implementation uses the well-tested 64-bit
// verilog-ethernet AXI frame interface; the two gearboxes are frame-safe and
// preserve byte order and AXI termination semantics.
module udp_arp_axis256_port #(
    parameter [47:0] LOCAL_MAC = 48'h024741000002,
    parameter [31:0] LOCAL_IP = 32'hC0A82A02,
    parameter [15:0] LOCAL_UDP_PORT = 16'd9000,
    parameter [31:0] STATIC_ARP_IP = 32'd0,
    parameter [47:0] STATIC_ARP_MAC = 48'd0
) (
    input tri0 biz_path_reset,
    input wire eth_rx_frame_event, eth_rx_error_event,
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
    input  wire         rst,
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
    output wire         m_axis_tuser
);

    wire [63:0] rx64_data;
    wire [7:0]  rx64_keep;
    wire        rx64_valid;
    wire        rx64_ready;
    wire        rx64_last;
    wire        rx64_user;

    wire [47:0] rx_dest_mac;
    wire [47:0] rx_src_mac;
    wire [15:0] rx_eth_type;
    wire        rx_eth_hdr_valid;
    wire        rx_eth_hdr_ready;
    wire [63:0] rx_payload_data;
    wire [7:0]  rx_payload_keep;
    wire        rx_payload_valid;
    wire        rx_payload_ready;
    wire        rx_payload_last;
    wire        rx_payload_user;

    wire [47:0] tx_dest_mac;
    wire [47:0] tx_src_mac;
    wire [15:0] tx_eth_type;
    wire        tx_eth_hdr_valid;
    wire        tx_eth_hdr_ready;
    wire [63:0] tx_payload_data;
    wire [7:0]  tx_payload_keep;
    wire        tx_payload_valid;
    wire        tx_payload_ready;
    wire        tx_payload_last;
    wire        tx_payload_user;

    wire [63:0] tx_raw_data;
    wire [7:0]  tx_raw_keep;
    wire        tx_raw_valid;
    wire        tx_raw_ready;
    wire        tx_raw_last;
    wire        tx_raw_user;

    wire [63:0] tx_aligned_data;
    wire [7:0]  tx_aligned_keep;
    wire        tx_aligned_valid;
    wire        tx_aligned_ready;
    wire        tx_aligned_last;
    wire        tx_aligned_user;

    // L-Ethernet presents byte lane zero first on the 256-bit AXI bus.
    axis256_to_axis64 u_rx_gearbox (
        .clk       (clk),
        .rst       (rst),
        .s_tdata   (s_axis_tdata),
        .s_tkeep   (s_axis_tkeep),
        .s_tvalid  (s_axis_tvalid),
        .s_tready  (s_axis_tready),
        .s_tlast   (s_axis_tlast),
        .s_tuser   (s_axis_tuser),
        .m_tdata   (rx64_data),
        .m_tkeep   (rx64_keep),
        .m_tvalid  (rx64_valid),
        .m_tready  (rx64_ready),
        .m_tlast   (rx64_last),
        .m_tuser   (rx64_user)
    );

    eth_axis_rx #(
        .DATA_WIDTH (64),
        .KEEP_ENABLE (1),
        .KEEP_WIDTH (8)
    ) u_eth_rx (
        .clk                            (clk),
        .rst                            (rst),
        .s_axis_tdata                   (rx64_data),
        .s_axis_tkeep                   (rx64_keep),
        .s_axis_tvalid                  (rx64_valid),
        .s_axis_tready                  (rx64_ready),
        .s_axis_tlast                   (rx64_last),
        .s_axis_tuser                   (rx64_user),
        .m_eth_hdr_valid                (rx_eth_hdr_valid),
        .m_eth_hdr_ready                (rx_eth_hdr_ready),
        .m_eth_dest_mac                 (rx_dest_mac),
        .m_eth_src_mac                  (rx_src_mac),
        .m_eth_type                     (rx_eth_type),
        .m_eth_payload_axis_tdata       (rx_payload_data),
        .m_eth_payload_axis_tkeep       (rx_payload_keep),
        .m_eth_payload_axis_tvalid      (rx_payload_valid),
        .m_eth_payload_axis_tready      (rx_payload_ready),
        .m_eth_payload_axis_tlast       (rx_payload_last),
        .m_eth_payload_axis_tuser       (rx_payload_user),
        .busy                            (),
        .error_header_early_termination  ()
    );

    udp_arp_ethernet_shell_64 #(
        .LOCAL_MAC      (LOCAL_MAC),
        .LOCAL_IP       (LOCAL_IP),
        .LOCAL_UDP_PORT (LOCAL_UDP_PORT),
        .STATIC_ARP_IP  (STATIC_ARP_IP),
        .STATIC_ARP_MAC (STATIC_ARP_MAC)
    ) u_protocol (
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
        .eth_rx_frame_event(eth_rx_frame_event), .eth_rx_error_event(eth_rx_error_event),
        .clk                    (clk),
        .rst                    (rst),
        .s_eth_hdr_valid        (rx_eth_hdr_valid),
        .s_eth_hdr_ready        (rx_eth_hdr_ready),
        .s_eth_dest_mac         (rx_dest_mac),
        .s_eth_src_mac          (rx_src_mac),
        .s_eth_type             (rx_eth_type),
        .s_eth_payload_tdata    (rx_payload_data),
        .s_eth_payload_tkeep    (rx_payload_keep),
        .s_eth_payload_tvalid   (rx_payload_valid),
        .s_eth_payload_tready   (rx_payload_ready),
        .s_eth_payload_tlast    (rx_payload_last),
        .s_eth_payload_tuser    (rx_payload_user),
        .m_eth_hdr_valid        (tx_eth_hdr_valid),
        .m_eth_hdr_ready        (tx_eth_hdr_ready),
        .m_eth_dest_mac         (tx_dest_mac),
        .m_eth_src_mac          (tx_src_mac),
        .m_eth_type             (tx_eth_type),
        .m_eth_payload_tdata    (tx_payload_data),
        .m_eth_payload_tkeep   (tx_payload_keep),
        .m_eth_payload_tvalid  (tx_payload_valid),
        .m_eth_payload_tready  (tx_payload_ready),
        .m_eth_payload_tlast   (tx_payload_last),
        .m_eth_payload_tuser   (tx_payload_user)
    );

    eth_axis_tx #(
        .DATA_WIDTH (64),
        .KEEP_ENABLE (1),
        .KEEP_WIDTH (8)
    ) u_eth_tx (
        .clk                            (clk),
        .rst                            (rst),
        .s_eth_hdr_valid                (tx_eth_hdr_valid),
        .s_eth_hdr_ready                (tx_eth_hdr_ready),
        .s_eth_dest_mac                 (tx_dest_mac),
        .s_eth_src_mac                  (tx_src_mac),
        .s_eth_type                     (tx_eth_type),
        .s_eth_payload_axis_tdata       (tx_payload_data),
        .s_eth_payload_axis_tkeep       (tx_payload_keep),
        .s_eth_payload_axis_tvalid      (tx_payload_valid),
        .s_eth_payload_axis_tready      (tx_payload_ready),
        .s_eth_payload_axis_tlast       (tx_payload_last),
        .s_eth_payload_axis_tuser       (tx_payload_user),
        .m_axis_tdata                   (tx_raw_data),
        .m_axis_tkeep                   (tx_raw_keep),
        .m_axis_tvalid                  (tx_raw_valid),
        .m_axis_tready                  (tx_raw_ready),
        .m_axis_tlast                   (tx_raw_last),
        .m_axis_tuser                   (tx_raw_user),
        .busy                            ()
    );

    // The generated L-Ethernet MAC is configured with FCS insertion and a
    // 256-bit user interface.  The registered padder enforces the 64-byte
    // minimum and 8-byte alignment while keeping padding outside the IPv4
    // and UDP length fields.
    axis_eth_frame_pad_64_registered #(
        .MIN_FRAME_BYTES (16'd64)
    ) u_tx_frame_align (
        .clk       (clk),
        .rst       (rst),
        .s_tdata   (tx_raw_data),
        .s_tkeep   (tx_raw_keep),
        .s_tvalid  (tx_raw_valid),
        .s_tready  (tx_raw_ready),
        .s_tlast   (tx_raw_last),
        .s_tuser   (tx_raw_user),
        .m_tdata   (tx_aligned_data),
        .m_tkeep   (tx_aligned_keep),
        .m_tvalid  (tx_aligned_valid),
        .m_tready  (tx_aligned_ready),
        .m_tlast   (tx_aligned_last),
        .m_tuser   (tx_aligned_user)
    );

    axis64_to_axis256 u_tx_gearbox (
        .clk       (clk),
        .rst       (rst),
        .s_tdata   (tx_aligned_data),
        .s_tkeep   (tx_aligned_keep),
        .s_tvalid  (tx_aligned_valid),
        .s_tready  (tx_aligned_ready),
        .s_tlast   (tx_aligned_last),
        .s_tuser   (tx_aligned_user),
        .m_tdata   (m_axis_tdata),
        .m_tkeep   (m_axis_tkeep),
        .m_tvalid  (m_axis_tvalid),
        .m_tready  (m_axis_tready),
        .m_tlast   (m_axis_tlast),
        .m_tuser   (m_axis_tuser)
    );

endmodule

`default_nettype wire
