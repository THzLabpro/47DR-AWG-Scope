// ------------------------------------------------------------------------------
//   (c) Copyright 2020-2021 Xilinx, Inc. All rights reserved.
// 
//   This file contains confidential and proprietary information
//   of Xilinx, Inc. and is protected under U.S. and
//   international copyright and other intellectual property
//   laws.
// 
//   DISCLAIMER
//   This disclaimer is not a license and does not grant any
//   rights to the materials distributed herewith. Except as
//   otherwise provided in a valid license issued to you by
//   Xilinx, and to the maximum extent permitted by applicable
//   law: (1) THESE MATERIALS ARE MADE AVAILABLE \"AS IS\" AND
//   WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
//   AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
//   BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
//   INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
//   (2) Xilinx shall not be liable (whether in contract or tort,
//   including negligence, or under any other theory of
//   liability) for any loss or damage of any kind or nature
//   related to, arising under or in connection with these
//   materials, including for any direct, or any indirect,
//   special, incidental, or consequential loss or damage
//   (including loss of data, profits, goodwill, or any type of
//   loss or damage suffered as a result of any action brought
//   by a third party) even if such damage or loss was
//   reasonably foreseeable or Xilinx had been advised of the
//   possibility of the same.
// 
//   CRITICAL APPLICATIONS
//   Xilinx products are not designed or intended to be fail-
//   safe, or for use in any application requiring fail-safe
//   performance, such as life-support or safety devices or
//   systems, Class III medical devices, nuclear facilities,
//   applications related to the deployment of airbags, or any
//   other applications that could lead to death, personal
//   injury, or severe property or environmental damage
//   (individually and collectively, \"Critical
//   Applications\"). Customer assumes the sole risk and
//   liability of any use of Xilinx products in Critical
//   Applications, subject only to applicable laws and
//   regulations governing limitations on product liability.
// 
//   THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
//   PART OF THIS FILE AT ALL TIMES.
//
// 
//
//       Owner:          
//       Revision:       $Id: $
//                       $Author: $
//                       $DateTime: $
//                       $Change: $
//       Description:
//
// 
////------------------------------------------------------------------------------


`timescale 1fs/1fs

(* DowngradeIPIdentifiedWarnings="yes" *)
module optical_port2_exdes
(
  input  wire gt_rxp_in_0,
  input  wire gt_rxn_in_0,
  output wire gt_txp_out_0,
  output wire gt_txn_out_0,
  input  wire gt_rxp_in_1,
  input  wire gt_rxn_in_1,
  output wire gt_txp_out_1,
  output wire gt_txn_out_1,
  input  wire gt_rxp_in_2,
  input  wire gt_rxn_in_2,
  output wire gt_txp_out_2,
  output wire gt_txn_out_2,
  input  wire gt_rxp_in_3,
  input  wire gt_rxn_in_3,
  output wire gt_txp_out_3,
  output wire gt_txn_out_3,
  input wire send_continuous_pkts_0,
  input wire internal_loopback,
  input wire external_tx_enable, input wire external_tx_valid, input wire [255:0] external_tx_data, input wire [31:0] external_tx_keep, input wire external_tx_last, input wire external_tx_user, output wire external_tx_ready, output wire external_rx_valid, output wire [255:0] external_rx_data, output wire [31:0] external_rx_keep, output wire external_rx_last, output wire external_rx_user,
    output wire       rx_gt_locked_led,
    output wire       rx_aligned_led,
    output wire [4:0] completion_status,

    input             sys_reset,
    input             restart_tx_rx,

    input             gt_refclk_p,
    input             gt_refclk_n,
    output wire       reference_clock,
    output wire       diagnostic_clock,
    output wire [15:0] diagnostic_levels,
    output wire       protocol_clock,
    output wire       protocol_reset,
    input             dclk
);

`ifdef SIM_SPEED_UP
  parameter PKT_NUM         = 20;    //// Many Internal Counters are based on PKT_NUM = 20
`else
  parameter PKT_NUM         = 1000;    //// Many Internal Counters are based on PKT_NUM = 1000
`endif
  wire gt_refclk_out;
  assign reference_clock = gt_refclk_out;

  wire gtwiz_reset_tx_datapath_0; 
  wire gtwiz_reset_rx_datapath_0; 
  assign gtwiz_reset_tx_datapath_0 = 1'b0; 
  assign gtwiz_reset_rx_datapath_0 = 1'b0; 

  wire rx_core_clk_0;
  wire rx_clk_out_0;
  wire tx_clk_out_0;
  // Keep the generated GT reset controller on its proven management-reset
  // startup path. Do not gate reset release with tx_clk_out_0: that clock is
  // produced by the same GT and may not run while the GT is held in reset.
  wire sys_reset_local_0 = sys_reset;
  // Synchronize the management/VIO restart request into the 312.5 MHz
  // transceiver user-clock domain before it reaches MAC reset logic.
  (* ASYNC_REG = "TRUE" *) reg [2:0] restart_tx_rx_sync_0 = 3'b000;
  wire restart_tx_rx_local_0 = restart_tx_rx_sync_0[2];
  always @(posedge tx_clk_out_0) begin
    restart_tx_rx_sync_0 <= {restart_tx_rx_sync_0[1:0], restart_tx_rx};
  end
  // The IP associates axis_rx_0:mii_rx_0 with rx_core_clk_0.  Driving that
  // clock from tx_clk_out_0 keeps the RX AXI stream in the protocol clock
  // domain; rx_clk_out_0 remains an internally derived status clock.
  assign rx_core_clk_0 = tx_clk_out_0;

//// For other GT loopback options please change the value appropriately
//// For example, for internal loopback gt_loopback_in[2:0] = 3'b010;
//// For more information and settings on loopback, refer GT Transceivers user guide

  wire [11:0] gt_loopback_in_0;
  // VIO-controlled GTY loopback: 010 is serial near-end PCS loopback.
  assign gt_loopback_in_0 = {4{internal_loopback ? 3'b010 : 3'b000}};
//// RX_0 Signals
  wire rx_reset_0;
  wire user_rx_reset_0;

//// RX_0 User Interface Signals
  wire rx_axis_tvalid_0;
  wire [255:0] rx_axis_tdata_0;
  wire [0:0] rx_axis_tuser_0;
  wire [31:0] rx_axis_tkeep_0;
  wire rx_axis_tlast_0;
  wire [55:0] rx_preambleout_0;

//// RX_0 Control Signals
  wire ctl_rx_test_pattern_0;
  wire ctl_rx_enable_0;
  wire ctl_rx_delete_fcs_0;
  wire ctl_rx_ignore_fcs_0;
  wire [14:0] ctl_rx_max_packet_len_0;
  wire [7:0] ctl_rx_min_packet_len_0;
  wire ctl_rx_check_sfd_0;
  wire ctl_rx_check_preamble_0;
  wire ctl_rx_process_lfi_0;
  wire ctl_rx_force_resync_0;


//// RX_0 Stats Signals
  wire [3:0] stat_rx_block_lock_0;
  wire stat_rx_framing_err_valid_0_0;
  wire stat_rx_framing_err_0_0;
  wire stat_rx_framing_err_valid_1_0;
  wire stat_rx_framing_err_1_0;
  wire stat_rx_framing_err_valid_2_0;
  wire stat_rx_framing_err_2_0;
  wire stat_rx_framing_err_valid_3_0;
  wire stat_rx_framing_err_3_0;
  wire [3:0] stat_rx_vl_demuxed_0;
  wire [1:0] stat_rx_vl_number_0_0;
  wire [1:0] stat_rx_vl_number_1_0;
  wire [1:0] stat_rx_vl_number_2_0;
  wire [1:0] stat_rx_vl_number_3_0;
  wire [3:0] stat_rx_synced_0;
  wire stat_rx_misaligned_0;
  wire stat_rx_aligned_err_0;
  wire [3:0] stat_rx_synced_err_0;
  wire [3:0] stat_rx_mf_len_err_0;
  wire [3:0] stat_rx_mf_repeat_err_0;
  wire [3:0] stat_rx_mf_err_0;
  wire stat_rx_bip_err_0_0;
  wire stat_rx_bip_err_1_0;
  wire stat_rx_bip_err_2_0;
  wire stat_rx_bip_err_3_0;
  wire stat_rx_aligned_0;
  wire stat_rx_hi_ber_0;
  wire stat_rx_status_0;
  wire [1:0] stat_rx_bad_code_0;
  wire [1:0] stat_rx_total_packets_0;
  wire stat_rx_total_good_packets_0;
  wire [5:0] stat_rx_total_bytes_0;
  wire [13:0] stat_rx_total_good_bytes_0;
  wire [1:0] stat_rx_packet_small_0;
  wire stat_rx_jabber_0;
  wire stat_rx_packet_large_0;
  wire stat_rx_oversize_0;
  wire [1:0] stat_rx_undersize_0;
  wire stat_rx_toolong_0;
  wire [1:0] stat_rx_fragment_0;
  wire stat_rx_packet_64_bytes_0;
  wire stat_rx_packet_65_127_bytes_0;
  wire stat_rx_packet_128_255_bytes_0;
  wire stat_rx_packet_256_511_bytes_0;
  wire stat_rx_packet_512_1023_bytes_0;
  wire stat_rx_packet_1024_1518_bytes_0;
  wire stat_rx_packet_1519_1522_bytes_0;
  wire stat_rx_packet_1523_1548_bytes_0;
  wire [1:0] stat_rx_bad_fcs_0;
  wire stat_rx_packet_bad_fcs_0;
  wire [1:0] stat_rx_stomped_fcs_0;
  wire stat_rx_packet_1549_2047_bytes_0;
  wire stat_rx_packet_2048_4095_bytes_0;
  wire stat_rx_packet_4096_8191_bytes_0;
  wire stat_rx_packet_8192_9215_bytes_0;
  wire stat_rx_unicast_0;
  wire stat_rx_multicast_0;
  wire stat_rx_broadcast_0;
  wire stat_rx_vlan_0;
  wire stat_rx_inrangeerr_0;
  wire stat_rx_bad_preamble_0;
  wire stat_rx_bad_sfd_0;
  wire stat_rx_got_signal_os_0;
  wire [1:0] stat_rx_test_pattern_mismatch_0;
  wire stat_rx_truncated_0;
  wire stat_rx_local_fault_0;
  wire stat_rx_remote_fault_0;
  wire stat_rx_internal_local_fault_0;
  wire stat_rx_received_local_fault_0;


//// TX_0 Signals
  wire tx_reset_0;
  wire user_tx_reset_0;

//// TX_0 User Interface Signals
  wire tx_axis_tready_0;
  // Native MAC TX inputs.  The generated example traffic source was removed
  // from this protocol wrapper, so keep a deterministic idle source for the
  // external_tx_enable=0 case and select the protocol stream through muxes.
  wire tx_axis_tvalid_0;
  wire [255:0] tx_axis_tdata_0;
  wire [31:0] tx_axis_tkeep_0;
  wire [0:0] tx_axis_tuser_0;
  wire tx_axis_tlast_0;
  wire tx_axis_tvalid_mux;
  wire [255:0] tx_axis_tdata_mux;
  wire [31:0] tx_axis_tkeep_mux;
  wire tx_axis_tuser_mux;
  wire tx_axis_tlast_mux;
  wire tx_unfout_0;
  wire [55:0] tx_preamblein_0;

  assign tx_axis_tvalid_0 = 1'b0;
  assign tx_axis_tdata_0  = 256'd0;
  assign tx_axis_tkeep_0  = 32'd0;
  assign tx_axis_tuser_0  = 1'b0;
  assign tx_axis_tlast_0  = 1'b0;
  assign tx_preamblein_0  = 56'd0;
  assign tx_axis_tvalid_mux = external_tx_enable ? external_tx_valid : tx_axis_tvalid_0;
  assign tx_axis_tdata_mux  = external_tx_enable ? external_tx_data  : tx_axis_tdata_0;
  assign tx_axis_tkeep_mux  = external_tx_enable ? external_tx_keep  : tx_axis_tkeep_0;
  assign tx_axis_tuser_mux  = external_tx_enable ? external_tx_user  : tx_axis_tuser_0;
  assign tx_axis_tlast_mux  = external_tx_enable ? external_tx_last  : tx_axis_tlast_0;

//// TX_0 Control Signals
  wire ctl_tx_test_pattern_0;
  wire ctl_tx_enable_0;
  wire ctl_tx_fcs_ins_enable_0;
  wire [3:0] ctl_tx_ipg_value_0;
  wire ctl_tx_send_lfi_0;
  wire ctl_tx_send_rfi_0;
  wire ctl_tx_send_idle_0;
  wire ctl_tx_custom_preamble_enable_0;
  wire ctl_tx_ignore_fcs_0;


//// TX_0 Stats Signals
  wire stat_tx_underflow_err_0;
  wire stat_tx_overflow_err_0;
  wire stat_tx_total_packets_0;
  wire [4:0] stat_tx_total_bytes_0;
  wire stat_tx_total_good_packets_0;
  wire [13:0] stat_tx_total_good_bytes_0;
  wire stat_tx_packet_64_bytes_0;
  wire stat_tx_packet_65_127_bytes_0;
  wire stat_tx_packet_128_255_bytes_0;
  wire stat_tx_packet_256_511_bytes_0;
  wire stat_tx_packet_512_1023_bytes_0;
  wire stat_tx_packet_1024_1518_bytes_0;
  wire stat_tx_packet_1519_1522_bytes_0;
  wire stat_tx_packet_1523_1548_bytes_0;
  wire stat_tx_packet_small_0;
  wire stat_tx_packet_large_0;
  wire stat_tx_packet_1549_2047_bytes_0;
  wire stat_tx_packet_2048_4095_bytes_0;
  wire stat_tx_packet_4096_8191_bytes_0;
  wire stat_tx_packet_8192_9215_bytes_0;
  wire stat_tx_unicast_0;
  wire stat_tx_multicast_0;
  wire stat_tx_broadcast_0;
  wire stat_tx_vlan_0;
  wire stat_tx_bad_fcs_0;
  wire stat_tx_frame_error_0;
  wire stat_tx_local_fault_0;





  wire [3:0] rxrecclkout_0;
  wire [3:0] gtpowergood_out_0;
  wire [11:0] txoutclksel_in_0;
  wire [11:0] rxoutclksel_in_0;
  assign txoutclksel_in_0 = {4{3'b101}};     // This value should not be changed as per gtwizard 
  assign rxoutclksel_in_0 = {4{3'b101}};    // This value should not be changed as per gtwizard


  wire usr_fsm_clk;
  assign diagnostic_clock = usr_fsm_clk;
  assign protocol_clock = tx_clk_out_0;
  assign protocol_reset = user_tx_reset_0 | user_rx_reset_0;

  // Slow status snapshot for VIO: power-good, block lock, lane sync,
  // PCS aligned/status flags, and a heartbeat from the MAC clock domain.
  // RX packet indication is supplied by the protocol-domain frame FIFO in
  // optical_loopback_top; do not sample the RX statistic pulse in TX clock.
  reg [25:0] diagnostic_counter = 26'd0;
  reg diagnostic_tx_seen = 1'b0;
  reg diagnostic_tx_underflow_seen = 1'b0;
  reg diagnostic_tx_frame_error_seen = 1'b0;
  always @(posedge tx_clk_out_0) begin
    diagnostic_counter <= diagnostic_counter + 26'd1;
    if (restart_tx_rx_local_0) begin
      diagnostic_counter <= 26'd0;
      diagnostic_tx_seen <= 1'b0;
      diagnostic_tx_underflow_seen <= 1'b0;
      diagnostic_tx_frame_error_seen <= 1'b0;
    end else begin
      if (stat_tx_total_good_packets_0)
        diagnostic_tx_seen <= 1'b1;
      if (stat_tx_underflow_err_0)
        diagnostic_tx_underflow_seen <= 1'b1;
      if (stat_tx_frame_error_0)
        diagnostic_tx_frame_error_seen <= 1'b1;
    end
  end
  
optical_port1_clk_wiz_0 i_CLK_GEN_0
   (
   //// Clock in ports
    .clk_in1    (dclk), 
    .clk_out1   (usr_fsm_clk),
    .reset      (1'b0),
    .locked     ()
 );
optical_port2 DUT
(
  
    .gt_rxp_in_0 (gt_rxp_in_0),
    .gt_rxn_in_0 (gt_rxn_in_0),
    .gt_txp_out_0 (gt_txp_out_0),
    .gt_txn_out_0 (gt_txn_out_0),
    .gt_rxp_in_1 (gt_rxp_in_1),
    .gt_rxn_in_1 (gt_rxn_in_1),
    .gt_txp_out_1 (gt_txp_out_1),
    .gt_txn_out_1 (gt_txn_out_1),
    .gt_rxp_in_2 (gt_rxp_in_2),
    .gt_rxn_in_2 (gt_rxn_in_2),
    .gt_txp_out_2 (gt_txp_out_2),
    .gt_txn_out_2 (gt_txn_out_2),
    .gt_rxp_in_3 (gt_rxp_in_3),
    .gt_rxn_in_3 (gt_rxn_in_3),
    .gt_txp_out_3 (gt_txp_out_3),
    .gt_txn_out_3 (gt_txn_out_3),

    .tx_clk_out_0 (tx_clk_out_0),
    .rx_core_clk_0 (rx_core_clk_0),
    .rx_clk_out_0 (rx_clk_out_0),
    .rxrecclkout_0 (rxrecclkout_0),

    .gt_loopback_in_0 (gt_loopback_in_0),
    .rx_reset_0 (rx_reset_0),
    .user_rx_reset_0 (user_rx_reset_0),
  
    
//// RX User Interface Signals
    .rx_axis_tvalid_0 (rx_axis_tvalid_0),
    .rx_axis_tdata_0 (rx_axis_tdata_0),
    .rx_axis_tuser_0 (rx_axis_tuser_0),
    .rx_axis_tkeep_0 (rx_axis_tkeep_0),
    .rx_axis_tlast_0 (rx_axis_tlast_0),
    .rx_preambleout_0 (rx_preambleout_0),


//// RX Control Signals
    .ctl_rx_test_pattern_0 (ctl_rx_test_pattern_0),
    .ctl_rx_enable_0 (ctl_rx_enable_0),
    .ctl_rx_delete_fcs_0 (ctl_rx_delete_fcs_0),
    .ctl_rx_ignore_fcs_0 (ctl_rx_ignore_fcs_0),
    .ctl_rx_max_packet_len_0 (ctl_rx_max_packet_len_0),
    .ctl_rx_min_packet_len_0 (ctl_rx_min_packet_len_0),
    .ctl_rx_custom_preamble_enable_0 (ctl_rx_custom_preamble_enable_0),
    .ctl_rx_check_sfd_0 (ctl_rx_check_sfd_0),
    .ctl_rx_check_preamble_0 (ctl_rx_check_preamble_0),
    .ctl_rx_process_lfi_0 (ctl_rx_process_lfi_0),
    .ctl_rx_force_resync_0 (ctl_rx_force_resync_0),



//// RX Stats Signals
    .stat_rx_block_lock_0 (stat_rx_block_lock_0),
    .stat_rx_framing_err_valid_0_0 (stat_rx_framing_err_valid_0_0),
    .stat_rx_framing_err_0_0 (stat_rx_framing_err_0_0),
    .stat_rx_framing_err_valid_1_0 (stat_rx_framing_err_valid_1_0),
    .stat_rx_framing_err_1_0 (stat_rx_framing_err_1_0),
    .stat_rx_framing_err_valid_2_0 (stat_rx_framing_err_valid_2_0),
    .stat_rx_framing_err_2_0 (stat_rx_framing_err_2_0),
    .stat_rx_framing_err_valid_3_0 (stat_rx_framing_err_valid_3_0),
    .stat_rx_framing_err_3_0 (stat_rx_framing_err_3_0),
    .stat_rx_vl_demuxed_0 (stat_rx_vl_demuxed_0),
    .stat_rx_vl_number_0_0 (stat_rx_vl_number_0_0),
    .stat_rx_vl_number_1_0 (stat_rx_vl_number_1_0),
    .stat_rx_vl_number_2_0 (stat_rx_vl_number_2_0),
    .stat_rx_vl_number_3_0 (stat_rx_vl_number_3_0),
    .stat_rx_synced_0 (stat_rx_synced_0),
    .stat_rx_misaligned_0 (stat_rx_misaligned_0),
    .stat_rx_aligned_err_0 (stat_rx_aligned_err_0),
    .stat_rx_synced_err_0 (stat_rx_synced_err_0),
    .stat_rx_mf_len_err_0 (stat_rx_mf_len_err_0),
    .stat_rx_mf_repeat_err_0 (stat_rx_mf_repeat_err_0),
    .stat_rx_mf_err_0 (stat_rx_mf_err_0),
    .stat_rx_bip_err_0_0 (stat_rx_bip_err_0_0),
    .stat_rx_bip_err_1_0 (stat_rx_bip_err_1_0),
    .stat_rx_bip_err_2_0 (stat_rx_bip_err_2_0),
    .stat_rx_bip_err_3_0 (stat_rx_bip_err_3_0),
    .stat_rx_aligned_0 (stat_rx_aligned_0),
    .stat_rx_hi_ber_0 (stat_rx_hi_ber_0),
    .stat_rx_status_0 (stat_rx_status_0),
    .stat_rx_bad_code_0 (stat_rx_bad_code_0),
    .stat_rx_total_packets_0 (stat_rx_total_packets_0),
    .stat_rx_total_good_packets_0 (stat_rx_total_good_packets_0),
    .stat_rx_total_bytes_0 (stat_rx_total_bytes_0),
    .stat_rx_total_good_bytes_0 (stat_rx_total_good_bytes_0),
    .stat_rx_packet_small_0 (stat_rx_packet_small_0),
    .stat_rx_jabber_0 (stat_rx_jabber_0),
    .stat_rx_packet_large_0 (stat_rx_packet_large_0),
    .stat_rx_oversize_0 (stat_rx_oversize_0),
    .stat_rx_undersize_0 (stat_rx_undersize_0),
    .stat_rx_toolong_0 (stat_rx_toolong_0),
    .stat_rx_fragment_0 (stat_rx_fragment_0),
    .stat_rx_packet_64_bytes_0 (stat_rx_packet_64_bytes_0),
    .stat_rx_packet_65_127_bytes_0 (stat_rx_packet_65_127_bytes_0),
    .stat_rx_packet_128_255_bytes_0 (stat_rx_packet_128_255_bytes_0),
    .stat_rx_packet_256_511_bytes_0 (stat_rx_packet_256_511_bytes_0),
    .stat_rx_packet_512_1023_bytes_0 (stat_rx_packet_512_1023_bytes_0),
    .stat_rx_packet_1024_1518_bytes_0 (stat_rx_packet_1024_1518_bytes_0),
    .stat_rx_packet_1519_1522_bytes_0 (stat_rx_packet_1519_1522_bytes_0),
    .stat_rx_packet_1523_1548_bytes_0 (stat_rx_packet_1523_1548_bytes_0),
    .stat_rx_bad_fcs_0 (stat_rx_bad_fcs_0),
    .stat_rx_packet_bad_fcs_0 (stat_rx_packet_bad_fcs_0),
    .stat_rx_stomped_fcs_0 (stat_rx_stomped_fcs_0),
    .stat_rx_packet_1549_2047_bytes_0 (stat_rx_packet_1549_2047_bytes_0),
    .stat_rx_packet_2048_4095_bytes_0 (stat_rx_packet_2048_4095_bytes_0),
    .stat_rx_packet_4096_8191_bytes_0 (stat_rx_packet_4096_8191_bytes_0),
    .stat_rx_packet_8192_9215_bytes_0 (stat_rx_packet_8192_9215_bytes_0),
    .stat_rx_unicast_0 (stat_rx_unicast_0),
    .stat_rx_multicast_0 (stat_rx_multicast_0),
    .stat_rx_broadcast_0 (stat_rx_broadcast_0),
    .stat_rx_vlan_0 (stat_rx_vlan_0),
    .stat_rx_inrangeerr_0 (stat_rx_inrangeerr_0),
    .stat_rx_bad_preamble_0 (stat_rx_bad_preamble_0),
    .stat_rx_bad_sfd_0 (stat_rx_bad_sfd_0),
    .stat_rx_got_signal_os_0 (stat_rx_got_signal_os_0),
    .stat_rx_test_pattern_mismatch_0 (stat_rx_test_pattern_mismatch_0),
    .stat_rx_truncated_0 (stat_rx_truncated_0),
    .stat_rx_local_fault_0 (stat_rx_local_fault_0),
    .stat_rx_remote_fault_0 (stat_rx_remote_fault_0),
    .stat_rx_internal_local_fault_0 (stat_rx_internal_local_fault_0),
    .stat_rx_received_local_fault_0 (stat_rx_received_local_fault_0),



    .tx_reset_0 (tx_reset_0),
    .user_tx_reset_0 (user_tx_reset_0),
//// TX User Interface Signals
    .tx_axis_tready_0 (tx_axis_tready_0),
    .tx_axis_tvalid_0 (tx_axis_tvalid_mux),
    .tx_axis_tdata_0 (tx_axis_tdata_mux),
    .tx_axis_tuser_0 (tx_axis_tuser_mux),
    .tx_unfout_0 (tx_unfout_0),
    .tx_axis_tkeep_0 (tx_axis_tkeep_mux),
    .tx_axis_tlast_0 (tx_axis_tlast_mux),
    .tx_preamblein_0 (tx_preamblein_0),


//// TX Control Signals
    .ctl_tx_test_pattern_0 (ctl_tx_test_pattern_0),
    .ctl_tx_enable_0 (ctl_tx_enable_0),
    .ctl_tx_fcs_ins_enable_0 (ctl_tx_fcs_ins_enable_0),
    .ctl_tx_ipg_value_0 (ctl_tx_ipg_value_0),
    .ctl_tx_send_lfi_0 (ctl_tx_send_lfi_0),
    .ctl_tx_send_rfi_0 (ctl_tx_send_rfi_0),
    .ctl_tx_send_idle_0 (ctl_tx_send_idle_0),
    .ctl_tx_custom_preamble_enable_0 (ctl_tx_custom_preamble_enable_0),
    .ctl_tx_ignore_fcs_0 (ctl_tx_ignore_fcs_0),


//// TX Stats Signals
    .stat_tx_underflow_err_0 (stat_tx_underflow_err_0),
    .stat_tx_overflow_err_0 (stat_tx_overflow_err_0),
    .stat_tx_total_packets_0 (stat_tx_total_packets_0),
    .stat_tx_total_bytes_0 (stat_tx_total_bytes_0),
    .stat_tx_total_good_packets_0 (stat_tx_total_good_packets_0),
    .stat_tx_total_good_bytes_0 (stat_tx_total_good_bytes_0),
    .stat_tx_packet_64_bytes_0 (stat_tx_packet_64_bytes_0),
    .stat_tx_packet_65_127_bytes_0 (stat_tx_packet_65_127_bytes_0),
    .stat_tx_packet_128_255_bytes_0 (stat_tx_packet_128_255_bytes_0),
    .stat_tx_packet_256_511_bytes_0 (stat_tx_packet_256_511_bytes_0),
    .stat_tx_packet_512_1023_bytes_0 (stat_tx_packet_512_1023_bytes_0),
    .stat_tx_packet_1024_1518_bytes_0 (stat_tx_packet_1024_1518_bytes_0),
    .stat_tx_packet_1519_1522_bytes_0 (stat_tx_packet_1519_1522_bytes_0),
    .stat_tx_packet_1523_1548_bytes_0 (stat_tx_packet_1523_1548_bytes_0),
    .stat_tx_packet_small_0 (stat_tx_packet_small_0),
    .stat_tx_packet_large_0 (stat_tx_packet_large_0),
    .stat_tx_packet_1549_2047_bytes_0 (stat_tx_packet_1549_2047_bytes_0),
    .stat_tx_packet_2048_4095_bytes_0 (stat_tx_packet_2048_4095_bytes_0),
    .stat_tx_packet_4096_8191_bytes_0 (stat_tx_packet_4096_8191_bytes_0),
    .stat_tx_packet_8192_9215_bytes_0 (stat_tx_packet_8192_9215_bytes_0),
    .stat_tx_unicast_0 (stat_tx_unicast_0),
    .stat_tx_multicast_0 (stat_tx_multicast_0),
    .stat_tx_broadcast_0 (stat_tx_broadcast_0),
    .stat_tx_vlan_0 (stat_tx_vlan_0),
    .stat_tx_bad_fcs_0 (stat_tx_bad_fcs_0),
    .stat_tx_frame_error_0 (stat_tx_frame_error_0),
    .stat_tx_local_fault_0 (stat_tx_local_fault_0),




    .gtwiz_reset_tx_datapath_0 (gtwiz_reset_tx_datapath_0),
    .gtwiz_reset_rx_datapath_0 (gtwiz_reset_rx_datapath_0),
    .gtpowergood_out_0 (gtpowergood_out_0),
    .txoutclksel_in_0 (txoutclksel_in_0),
    .rxoutclksel_in_0 (rxoutclksel_in_0),
    .gt_refclk_p(gt_refclk_p),
    .gt_refclk_n(gt_refclk_n),
    .gt_refclk_out(gt_refclk_out),
    .sys_reset (sys_reset_local_0),
    .dclk (dclk)
);


// Deterministic MAC control defaults for protocol-only wrapper.
// Preserve the reset/restart behavior of the generated example design.  The
// protocol wrapper removed the packet-generator FSM, but the GT/MAC reset
// inputs must still be asserted at startup and on a VIO restart request.
// The generated L-Ethernet core synchronizes sys_reset internally.  Keep the
// dedicated MAC reset pins inactive here; routing the management/VIO restart
// signal into RX/TX reset creates a management_clock-to-GTY recovery path and
// can hold the 40G PCS in reset while the protocol clock is starting.
assign rx_reset_0 = 1'b0;
assign tx_reset_0 = 1'b0;
assign ctl_rx_test_pattern_0=1'b0; assign ctl_rx_enable_0=1'b1;
// Keep the MAC's RX contract identical to the known-good Ethernet reference
// demo: remove the wire FCS before the protocol path.
assign ctl_rx_delete_fcs_0 = 1'b1;
assign ctl_rx_ignore_fcs_0 = 1'b0;
assign ctl_rx_custom_preamble_enable_0 = 1'b0;
// E5 (2026-11-12): accept jumbo frames up to 9600 bytes (PC MTU 9000 gives 9018-byte
// frames) so one AWG request can carry the protocol maximum of 2048 words (8216-byte
// UDP payload). With 1518 the board dropped every request above 350 words.
assign ctl_rx_max_packet_len_0 = 15'd9600;
assign ctl_rx_min_packet_len_0 = 8'd64;
assign ctl_rx_check_sfd_0=1'b1; assign ctl_rx_check_preamble_0=1'b1;
assign ctl_rx_process_lfi_0=1'b0; assign ctl_rx_force_resync_0=1'b0;
assign ctl_tx_test_pattern_0=1'b0; assign ctl_tx_enable_0=1'b1;
assign ctl_tx_fcs_ins_enable_0=1'b1; assign ctl_tx_ipg_value_0=4'd12;
assign ctl_tx_send_lfi_0=1'b0; assign ctl_tx_send_rfi_0=1'b0; assign ctl_tx_send_idle_0=1'b0;
assign ctl_tx_custom_preamble_enable_0=1'b0; assign ctl_tx_ignore_fcs_0=1'b0;

wire [6:0] rx_link_status_async = {
    &stat_rx_block_lock_0,
    stat_rx_local_fault_0,
    stat_rx_status_0,
    stat_rx_aligned_0,
    stat_rx_synced_0[0],
    stat_rx_block_lock_0[0],
    stat_rx_aligned_0
};
wire [6:0] rx_link_status_protocol;
xpm_cdc_array_single #(
    .DEST_SYNC_FF(4), .SRC_INPUT_REG(1), .INIT_SYNC_FF(1), .WIDTH(7)
) u_rx_link_status_to_protocol (
    .src_clk(rx_clk_out_0),
    .src_in(rx_link_status_async),
    .dest_clk(tx_clk_out_0),
    .dest_out(rx_link_status_protocol)
);
assign rx_gt_locked_led = rx_link_status_protocol[6];
assign completion_status = rx_link_status_protocol[5:1];
assign rx_aligned_led = rx_link_status_protocol[0];

assign external_tx_ready = tx_axis_tready_0;
  assign external_rx_valid = rx_axis_tvalid_0; assign external_rx_data = rx_axis_tdata_0; assign external_rx_keep = rx_axis_tkeep_0; assign external_rx_last = rx_axis_tlast_0; assign external_rx_user = rx_axis_tuser_0;

  // Synchronize TX-domain diagnostics and RX-domain link status separately.
  // The previous single bus sampled RX signals with a TX-domain source
  // register, which is not a valid CDC structure.
  wire [2:0] diagnostic_tx_sync;
  wire [12:0] diagnostic_rx_sync;
  xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .INIT_SYNC_FF(1), .WIDTH(3)) u_diagnostic_tx_levels (
    .src_clk(tx_clk_out_0),
    .src_in({diagnostic_tx_frame_error_seen, diagnostic_tx_underflow_seen, diagnostic_tx_seen}),
    .dest_clk(dclk),
    .dest_out(diagnostic_tx_sync)
  );
  xpm_cdc_array_single #(.DEST_SYNC_FF(3), .SRC_INPUT_REG(1), .INIT_SYNC_FF(1), .WIDTH(13)) u_diagnostic_rx_levels (
    .src_clk(rx_clk_out_0),
    .src_in({stat_rx_aligned_0, stat_rx_synced_0, stat_rx_block_lock_0,
        gtpowergood_out_0}),
    .dest_clk(dclk),
    .dest_out(diagnostic_rx_sync)
  );
  assign diagnostic_levels = {diagnostic_tx_sync, diagnostic_rx_sync};
endmodule
