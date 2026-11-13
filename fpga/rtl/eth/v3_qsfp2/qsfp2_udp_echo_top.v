`default_nettype none
`timescale 1ns/1ps

// QSFP2-only 40GbE ARP/IPv4/UDP echo endpoint.
// All management logic is clocked from the QSFP2 reference clock so the
// active port cannot be held in reset by an unused QSFP1 reference.
module qsfp2_udp_echo_top (
    output wire       qsfp2_reset_n,
    output wire       qsfp2_lpmode,
    output wire       qsfp2_modsel_n,
    input  wire       qsfp2_refclk_p,
    input  wire       qsfp2_refclk_n,
    input  wire [3:0] qsfp2_rx_p,
    input  wire [3:0] qsfp2_rx_n,
    output wire [3:0] qsfp2_tx_p,
    output wire [3:0] qsfp2_tx_n
);

    wire qsfp2_reference_clock;
    wire management_clock;
    wire management_locked;
    wire manual_reset;
    wire restart_tx_rx;
    wire internal_loopback;
    wire continuous_test;
    wire system_reset;

    wire [15:0] qsfp2_mac_status;
    wire [3:0]  qsfp2_endpoint_status;
    wire [3:0]  qsfp2_endpoint_status_sync;
    wire [6:0]  qsfp2_vio_status;

    wire qsfp2_protocol_clk;
    wire qsfp2_protocol_reset;
    wire [255:0] qsfp2_tx_tdata;
    wire [31:0]  qsfp2_tx_tkeep;
    wire         qsfp2_tx_tvalid;
    wire         qsfp2_tx_tready;
    wire         qsfp2_tx_tlast;
    wire         qsfp2_tx_tuser;
    wire [255:0] qsfp2_rx_tdata;
    wire [31:0]  qsfp2_rx_tkeep;
    wire         qsfp2_rx_tvalid;
    wire         qsfp2_rx_tlast;
    wire         qsfp2_rx_tuser;

    assign qsfp2_reset_n = 1'b1;
    assign qsfp2_lpmode = 1'b0;
    assign qsfp2_modsel_n = 1'b0;

    demo_management_clock u_management_clock (
        .clk_in1  (qsfp2_reference_clock),
        .clk_out1 (management_clock),
        .reset    (1'b0),
        .locked   (management_locked)
    );

    assign system_reset = !management_locked || manual_reset;

    demo_control u_demo_control (
        .clk          (management_clock),
        .probe_in0    ({management_locked, qsfp2_vio_status}),
        .probe_out0   (manual_reset),
        .probe_out1   (restart_tx_rx),
        .probe_in1    (qsfp2_mac_status),
        .probe_in2    (16'd0),
        .probe_out3   (internal_loopback),
        .probe_out2   (continuous_test)
    );

    optical_port2_exdes u_qsfp2_mac (
        .gt_rxp_in_0 (qsfp2_rx_p[0]),
        .gt_rxn_in_0 (qsfp2_rx_n[0]),
        .gt_txp_out_0 (qsfp2_tx_p[0]),
        .gt_txn_out_0 (qsfp2_tx_n[0]),
        .gt_rxp_in_1 (qsfp2_rx_p[1]),
        .gt_rxn_in_1 (qsfp2_rx_n[1]),
        .gt_txp_out_1 (qsfp2_tx_p[1]),
        .gt_txn_out_1 (qsfp2_tx_n[1]),
        .gt_rxp_in_2 (qsfp2_rx_p[2]),
        .gt_rxn_in_2 (qsfp2_rx_n[2]),
        .gt_txp_out_2 (qsfp2_tx_p[2]),
        .gt_txn_out_2 (qsfp2_tx_n[2]),
        .gt_rxp_in_3 (qsfp2_rx_p[3]),
        .gt_rxn_in_3 (qsfp2_rx_n[3]),
        .gt_txp_out_3 (qsfp2_tx_p[3]),
        .gt_txn_out_3 (qsfp2_tx_n[3]),
        .send_continuous_pkts_0 (continuous_test),
        .internal_loopback (internal_loopback),
        .rx_gt_locked_led (),
        .rx_aligned_led (),
        .completion_status (),
        .sys_reset (system_reset),
        .restart_tx_rx (restart_tx_rx),
        .gt_refclk_p (qsfp2_refclk_p),
        .gt_refclk_n (qsfp2_refclk_n),
        .reference_clock (qsfp2_reference_clock),
        .diagnostic_clock (),
        .diagnostic_levels (qsfp2_mac_status),
        .protocol_clock (qsfp2_protocol_clk),
        .protocol_reset (qsfp2_protocol_reset),
        .external_tx_enable (1'b1),
        .external_tx_valid (qsfp2_tx_tvalid),
        .external_tx_data (qsfp2_tx_tdata),
        .external_tx_keep (qsfp2_tx_tkeep),
        .external_tx_last (qsfp2_tx_tlast),
        .external_tx_user (qsfp2_tx_tuser),
        .external_tx_ready (qsfp2_tx_tready),
        .external_rx_valid (qsfp2_rx_tvalid),
        .external_rx_data (qsfp2_rx_tdata),
        .external_rx_keep (qsfp2_rx_tkeep),
        .external_rx_last (qsfp2_rx_tlast),
        .external_rx_user (qsfp2_rx_tuser),
        .dclk (management_clock)
    );

    qsfp2_protocol_endpoint #(
        .LOCAL_MAC      (48'h024741000002),
        .LOCAL_IP       (32'hc0a82a02),
        .LOCAL_UDP_PORT (16'd9000),
        .STATIC_ARP_IP  (32'hc0a82a0a),
        .STATIC_ARP_MAC (48'h6cb311217d8e),
        .RX_FIFO_DEPTH  (65536),
        .TX_FIFO_DEPTH  (65536)
    ) u_qsfp2_endpoint (
        .clk                    (qsfp2_protocol_clk),
        .management_locked     (management_locked),
        .protocol_reset_raw    (qsfp2_protocol_reset),
        .mac_rx_tdata          (qsfp2_rx_tdata),
        .mac_rx_tkeep          (qsfp2_rx_tkeep),
        .mac_rx_tvalid         (qsfp2_rx_tvalid),
        .mac_rx_tlast          (qsfp2_rx_tlast),
        .mac_rx_tuser          (qsfp2_rx_tuser),
        .mac_tx_tdata          (qsfp2_tx_tdata),
        .mac_tx_tkeep          (qsfp2_tx_tkeep),
        .mac_tx_tvalid         (qsfp2_tx_tvalid),
        .mac_tx_tready         (qsfp2_tx_tready),
        .mac_tx_tlast          (qsfp2_tx_tlast),
        .mac_tx_tuser          (qsfp2_tx_tuser),
        .rx_frame_seen         (qsfp2_endpoint_status[0]),
        .rx_bad_or_drop_seen   (qsfp2_endpoint_status[1]),
        .tx_frame_accepted_seen(qsfp2_endpoint_status[2]),
        .tx_user_seen          (qsfp2_endpoint_status[3])
    );

    xpm_cdc_array_single #(
        .DEST_SYNC_FF  (3),
        .SRC_INPUT_REG (1),
        .INIT_SYNC_FF  (1),
        .WIDTH         (4)
    ) u_qsfp2_status_cdc (
        .src_clk  (qsfp2_protocol_clk),
        .src_in   (qsfp2_endpoint_status),
        .dest_clk (management_clock),
        .dest_out (qsfp2_endpoint_status_sync)
    );

    assign qsfp2_vio_status = {
        qsfp2_mac_status[12],
        qsfp2_mac_status[11],
        qsfp2_mac_status[7],
        qsfp2_endpoint_status_sync
    };

endmodule

`default_nettype wire
