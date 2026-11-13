-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2025.2 (win64) Build 6299465 Fri Nov 14 19:35:11 GMT 2025
-- Date        : Thu Nov 12 05:20:15 2026
-- Host        : DESKTOP-CLMQL7K running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               d:/ClaudeProject/47DR_DAAD/rf_awg_eth_v1/build/D3C_IMPL/vivado/d0_clock_probe.gen/sources_1/ip/optical_port2/optical_port2_stub.vhdl
-- Design      : optical_port2
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xczu47dr-fsve1156-2-i
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity optical_port2 is
  Port ( 
    gt_rxp_in_0 : in STD_LOGIC;
    gt_rxn_in_0 : in STD_LOGIC;
    gt_txp_out_0 : out STD_LOGIC;
    gt_txn_out_0 : out STD_LOGIC;
    gt_rxp_in_1 : in STD_LOGIC;
    gt_rxn_in_1 : in STD_LOGIC;
    gt_txp_out_1 : out STD_LOGIC;
    gt_txn_out_1 : out STD_LOGIC;
    gt_rxp_in_2 : in STD_LOGIC;
    gt_rxn_in_2 : in STD_LOGIC;
    gt_txp_out_2 : out STD_LOGIC;
    gt_txn_out_2 : out STD_LOGIC;
    gt_rxp_in_3 : in STD_LOGIC;
    gt_rxn_in_3 : in STD_LOGIC;
    gt_txp_out_3 : out STD_LOGIC;
    gt_txn_out_3 : out STD_LOGIC;
    tx_clk_out_0 : out STD_LOGIC;
    rx_core_clk_0 : in STD_LOGIC;
    rx_clk_out_0 : out STD_LOGIC;
    rxrecclkout_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    gtwiz_reset_tx_datapath_0 : in STD_LOGIC;
    gtwiz_reset_rx_datapath_0 : in STD_LOGIC;
    gt_loopback_in_0 : in STD_LOGIC_VECTOR ( 11 downto 0 );
    rx_reset_0 : in STD_LOGIC;
    user_rx_reset_0 : out STD_LOGIC;
    rx_axis_tvalid_0 : out STD_LOGIC;
    rx_axis_tdata_0 : out STD_LOGIC_VECTOR ( 255 downto 0 );
    rx_axis_tkeep_0 : out STD_LOGIC_VECTOR ( 31 downto 0 );
    rx_axis_tuser_0 : out STD_LOGIC;
    rx_axis_tlast_0 : out STD_LOGIC;
    rx_preambleout_0 : out STD_LOGIC_VECTOR ( 55 downto 0 );
    ctl_rx_test_pattern_0 : in STD_LOGIC;
    ctl_rx_enable_0 : in STD_LOGIC;
    ctl_rx_delete_fcs_0 : in STD_LOGIC;
    ctl_rx_ignore_fcs_0 : in STD_LOGIC;
    ctl_rx_max_packet_len_0 : in STD_LOGIC_VECTOR ( 14 downto 0 );
    ctl_rx_min_packet_len_0 : in STD_LOGIC_VECTOR ( 7 downto 0 );
    ctl_rx_custom_preamble_enable_0 : in STD_LOGIC;
    ctl_rx_check_sfd_0 : in STD_LOGIC;
    ctl_rx_check_preamble_0 : in STD_LOGIC;
    ctl_rx_process_lfi_0 : in STD_LOGIC;
    ctl_rx_force_resync_0 : in STD_LOGIC;
    stat_rx_block_lock_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    stat_rx_framing_err_valid_0_0 : out STD_LOGIC;
    stat_rx_framing_err_0_0 : out STD_LOGIC;
    stat_rx_framing_err_valid_1_0 : out STD_LOGIC;
    stat_rx_framing_err_1_0 : out STD_LOGIC;
    stat_rx_framing_err_valid_2_0 : out STD_LOGIC;
    stat_rx_framing_err_2_0 : out STD_LOGIC;
    stat_rx_framing_err_valid_3_0 : out STD_LOGIC;
    stat_rx_framing_err_3_0 : out STD_LOGIC;
    stat_rx_vl_demuxed_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    stat_rx_vl_number_0_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_vl_number_1_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_vl_number_2_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_vl_number_3_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_synced_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    stat_rx_misaligned_0 : out STD_LOGIC;
    stat_rx_aligned_err_0 : out STD_LOGIC;
    stat_rx_synced_err_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    stat_rx_mf_len_err_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    stat_rx_mf_repeat_err_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    stat_rx_mf_err_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    stat_rx_bip_err_0_0 : out STD_LOGIC;
    stat_rx_bip_err_1_0 : out STD_LOGIC;
    stat_rx_bip_err_2_0 : out STD_LOGIC;
    stat_rx_bip_err_3_0 : out STD_LOGIC;
    stat_rx_aligned_0 : out STD_LOGIC;
    stat_rx_hi_ber_0 : out STD_LOGIC;
    stat_rx_status_0 : out STD_LOGIC;
    stat_rx_bad_code_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_total_packets_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_total_good_packets_0 : out STD_LOGIC;
    stat_rx_total_bytes_0 : out STD_LOGIC_VECTOR ( 5 downto 0 );
    stat_rx_total_good_bytes_0 : out STD_LOGIC_VECTOR ( 13 downto 0 );
    stat_rx_packet_small_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_jabber_0 : out STD_LOGIC;
    stat_rx_packet_large_0 : out STD_LOGIC;
    stat_rx_oversize_0 : out STD_LOGIC;
    stat_rx_undersize_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_toolong_0 : out STD_LOGIC;
    stat_rx_fragment_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_packet_64_bytes_0 : out STD_LOGIC;
    stat_rx_packet_65_127_bytes_0 : out STD_LOGIC;
    stat_rx_packet_128_255_bytes_0 : out STD_LOGIC;
    stat_rx_packet_256_511_bytes_0 : out STD_LOGIC;
    stat_rx_packet_512_1023_bytes_0 : out STD_LOGIC;
    stat_rx_packet_1024_1518_bytes_0 : out STD_LOGIC;
    stat_rx_packet_1519_1522_bytes_0 : out STD_LOGIC;
    stat_rx_packet_1523_1548_bytes_0 : out STD_LOGIC;
    stat_rx_bad_fcs_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_packet_bad_fcs_0 : out STD_LOGIC;
    stat_rx_stomped_fcs_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_packet_1549_2047_bytes_0 : out STD_LOGIC;
    stat_rx_packet_2048_4095_bytes_0 : out STD_LOGIC;
    stat_rx_packet_4096_8191_bytes_0 : out STD_LOGIC;
    stat_rx_packet_8192_9215_bytes_0 : out STD_LOGIC;
    stat_rx_unicast_0 : out STD_LOGIC;
    stat_rx_multicast_0 : out STD_LOGIC;
    stat_rx_broadcast_0 : out STD_LOGIC;
    stat_rx_vlan_0 : out STD_LOGIC;
    stat_rx_inrangeerr_0 : out STD_LOGIC;
    stat_rx_bad_preamble_0 : out STD_LOGIC;
    stat_rx_bad_sfd_0 : out STD_LOGIC;
    stat_rx_got_signal_os_0 : out STD_LOGIC;
    stat_rx_test_pattern_mismatch_0 : out STD_LOGIC_VECTOR ( 1 downto 0 );
    stat_rx_truncated_0 : out STD_LOGIC;
    stat_rx_local_fault_0 : out STD_LOGIC;
    stat_rx_remote_fault_0 : out STD_LOGIC;
    stat_rx_internal_local_fault_0 : out STD_LOGIC;
    stat_rx_received_local_fault_0 : out STD_LOGIC;
    tx_reset_0 : in STD_LOGIC;
    user_tx_reset_0 : out STD_LOGIC;
    tx_axis_tready_0 : out STD_LOGIC;
    tx_axis_tvalid_0 : in STD_LOGIC;
    tx_axis_tdata_0 : in STD_LOGIC_VECTOR ( 255 downto 0 );
    tx_axis_tkeep_0 : in STD_LOGIC_VECTOR ( 31 downto 0 );
    tx_axis_tuser_0 : in STD_LOGIC;
    tx_axis_tlast_0 : in STD_LOGIC;
    tx_unfout_0 : out STD_LOGIC;
    tx_preamblein_0 : in STD_LOGIC_VECTOR ( 55 downto 0 );
    ctl_tx_test_pattern_0 : in STD_LOGIC;
    ctl_tx_enable_0 : in STD_LOGIC;
    ctl_tx_fcs_ins_enable_0 : in STD_LOGIC;
    ctl_tx_ipg_value_0 : in STD_LOGIC_VECTOR ( 3 downto 0 );
    ctl_tx_send_lfi_0 : in STD_LOGIC;
    ctl_tx_send_rfi_0 : in STD_LOGIC;
    ctl_tx_send_idle_0 : in STD_LOGIC;
    ctl_tx_custom_preamble_enable_0 : in STD_LOGIC;
    ctl_tx_ignore_fcs_0 : in STD_LOGIC;
    stat_tx_underflow_err_0 : out STD_LOGIC;
    stat_tx_overflow_err_0 : out STD_LOGIC;
    stat_tx_total_packets_0 : out STD_LOGIC;
    stat_tx_total_bytes_0 : out STD_LOGIC_VECTOR ( 4 downto 0 );
    stat_tx_total_good_packets_0 : out STD_LOGIC;
    stat_tx_total_good_bytes_0 : out STD_LOGIC_VECTOR ( 13 downto 0 );
    stat_tx_packet_64_bytes_0 : out STD_LOGIC;
    stat_tx_packet_65_127_bytes_0 : out STD_LOGIC;
    stat_tx_packet_128_255_bytes_0 : out STD_LOGIC;
    stat_tx_packet_256_511_bytes_0 : out STD_LOGIC;
    stat_tx_packet_512_1023_bytes_0 : out STD_LOGIC;
    stat_tx_packet_1024_1518_bytes_0 : out STD_LOGIC;
    stat_tx_packet_1519_1522_bytes_0 : out STD_LOGIC;
    stat_tx_packet_1523_1548_bytes_0 : out STD_LOGIC;
    stat_tx_packet_small_0 : out STD_LOGIC;
    stat_tx_packet_large_0 : out STD_LOGIC;
    stat_tx_packet_1549_2047_bytes_0 : out STD_LOGIC;
    stat_tx_packet_2048_4095_bytes_0 : out STD_LOGIC;
    stat_tx_packet_4096_8191_bytes_0 : out STD_LOGIC;
    stat_tx_packet_8192_9215_bytes_0 : out STD_LOGIC;
    stat_tx_unicast_0 : out STD_LOGIC;
    stat_tx_multicast_0 : out STD_LOGIC;
    stat_tx_broadcast_0 : out STD_LOGIC;
    stat_tx_vlan_0 : out STD_LOGIC;
    stat_tx_bad_fcs_0 : out STD_LOGIC;
    stat_tx_frame_error_0 : out STD_LOGIC;
    stat_tx_local_fault_0 : out STD_LOGIC;
    gtpowergood_out_0 : out STD_LOGIC_VECTOR ( 3 downto 0 );
    txoutclksel_in_0 : in STD_LOGIC_VECTOR ( 11 downto 0 );
    rxoutclksel_in_0 : in STD_LOGIC_VECTOR ( 11 downto 0 );
    gt_refclk_out : out STD_LOGIC;
    gt_refclk_p : in STD_LOGIC;
    gt_refclk_n : in STD_LOGIC;
    sys_reset : in STD_LOGIC;
    dclk : in STD_LOGIC
  );

  attribute CHECK_LICENSE_TYPE : string;
  attribute CHECK_LICENSE_TYPE of optical_port2 : entity is "optical_port2,l_ethernet_core,{}";
  attribute CORE_GENERATION_INFO : string;
  attribute CORE_GENERATION_INFO of optical_port2 : entity is "optical_port2,l_ethernet_v4_0_0,{x_ipProduct=Vivado 2025.2,x_ipVendor=xilinx.com,x_ipLibrary=ip,x_ipName=l_ethernet,x_ipVersion=4.0,x_ipCoreRevision=0,x_ipLanguage=VERILOG,x_ipSimLanguage=MIXED,C_CORE=Ethernet MAC+PCS/PMA,C_RUNTIME_SWITCH=0,C_LINE_RATE=40,C_NUM_OF_LANES=4,C_NUM_OF_CORES=1,C_CLOCKING=Asynchronous,C_DATA_PATH_INTERFACE=256-bit Regular AXI4-Stream,C_BASE_R_KR=BASE-R,C_INCLUDE_FEC_LOGIC=0,C_INCLUDE_RSFEC_LOGIC=0,C_INCLUDE_KP4_RSFEC=0,C_INCLUDE_SOFT_KP4_RSFEC=0,C_INCLUDE_AUTO_NEG_LT_LOGIC=None,C_ANLT_CLK_IN_MHZ=100,C_INCLUDE_AXI4_INTERFACE=0,C_INCLUDE_STATISTICS_COUNTERS=0,C_STATISTICS_REGS_TYPE=1,C_INCLUDE_USER_FIFO=1,C_ENABLE_TX_FLOW_CONTROL_LOGIC=0,C_ENABLE_RX_FLOW_CONTROL_LOGIC=0,C_ENABLE_TIME_STAMPING=0,C_PTP_OPERATION_MODE=2,C_PTP_CLOCKING_MODE=0,C_TX_LATENCY_ADJUST=0,C_ENABLE_VLANE_ADJUST_MODE=0,C_GT_LOCATION=1,C_INS_LOSS_NYQ=30,C_RX_EQ_MODE=AUTO,C_GT_REF_CLK_FREQ=156.25,C_GT_DRP_CLK=100.00,C_GT_TYPE=GTY,C_GT_GROUP_SELECT=Quad X0Y0,C_LANE1_GT_LOC=X0Y8,C_LANE2_GT_LOC=X0Y9,C_LANE3_GT_LOC=X0Y10,C_LANE4_GT_LOC=X0Y11,C_ENABLE_PIPELINE_REG=0,C_ADD_GT_CNTRL_STS_PORTS=0,C_INCLUDE_SHARED_LOGIC=1,C_RX_FRAME_ERR_BASE=3,C_FAST_SIM_MODE=0,C_FAMILY_CHK=zynquplus,IS_BOARD_PROJECT=0,VERSAL_GT_BOARD_FLOW=4,C_AXIS_TDATA_WIDTH=256,C_AXIS_TUSR_WIDTH=1,C_IS_256BIT_TX_0=axis_rx_0,C_IS_256BIT_TX_1=axis_rx_1,C_GTM_GROUP_SELECT=NA,C_GT_SETTINGS=internal,C_IS_GT_WIZ_OLD=1,x_ipLicense=l_eth_mac_pcs@2025.11(bought),x_ipLicense=l_eth_basekr@2025.11(bought),x_ipLicense=l_eth_baser@2025.11(bought)}";
  attribute DowngradeIPIdentifiedWarnings : string;
  attribute DowngradeIPIdentifiedWarnings of optical_port2 : entity is "yes";
end optical_port2;

architecture stub of optical_port2 is
  attribute syn_black_box : boolean;
  attribute black_box_pad_pin : string;
  attribute syn_black_box of stub : architecture is true;
  attribute black_box_pad_pin of stub : architecture is "gt_rxp_in_0,gt_rxn_in_0,gt_txp_out_0,gt_txn_out_0,gt_rxp_in_1,gt_rxn_in_1,gt_txp_out_1,gt_txn_out_1,gt_rxp_in_2,gt_rxn_in_2,gt_txp_out_2,gt_txn_out_2,gt_rxp_in_3,gt_rxn_in_3,gt_txp_out_3,gt_txn_out_3,tx_clk_out_0,rx_core_clk_0,rx_clk_out_0,rxrecclkout_0[3:0],gtwiz_reset_tx_datapath_0,gtwiz_reset_rx_datapath_0,gt_loopback_in_0[11:0],rx_reset_0,user_rx_reset_0,rx_axis_tvalid_0,rx_axis_tdata_0[255:0],rx_axis_tkeep_0[31:0],rx_axis_tuser_0,rx_axis_tlast_0,rx_preambleout_0[55:0],ctl_rx_test_pattern_0,ctl_rx_enable_0,ctl_rx_delete_fcs_0,ctl_rx_ignore_fcs_0,ctl_rx_max_packet_len_0[14:0],ctl_rx_min_packet_len_0[7:0],ctl_rx_custom_preamble_enable_0,ctl_rx_check_sfd_0,ctl_rx_check_preamble_0,ctl_rx_process_lfi_0,ctl_rx_force_resync_0,stat_rx_block_lock_0[3:0],stat_rx_framing_err_valid_0_0,stat_rx_framing_err_0_0,stat_rx_framing_err_valid_1_0,stat_rx_framing_err_1_0,stat_rx_framing_err_valid_2_0,stat_rx_framing_err_2_0,stat_rx_framing_err_valid_3_0,stat_rx_framing_err_3_0,stat_rx_vl_demuxed_0[3:0],stat_rx_vl_number_0_0[1:0],stat_rx_vl_number_1_0[1:0],stat_rx_vl_number_2_0[1:0],stat_rx_vl_number_3_0[1:0],stat_rx_synced_0[3:0],stat_rx_misaligned_0,stat_rx_aligned_err_0,stat_rx_synced_err_0[3:0],stat_rx_mf_len_err_0[3:0],stat_rx_mf_repeat_err_0[3:0],stat_rx_mf_err_0[3:0],stat_rx_bip_err_0_0,stat_rx_bip_err_1_0,stat_rx_bip_err_2_0,stat_rx_bip_err_3_0,stat_rx_aligned_0,stat_rx_hi_ber_0,stat_rx_status_0,stat_rx_bad_code_0[1:0],stat_rx_total_packets_0[1:0],stat_rx_total_good_packets_0,stat_rx_total_bytes_0[5:0],stat_rx_total_good_bytes_0[13:0],stat_rx_packet_small_0[1:0],stat_rx_jabber_0,stat_rx_packet_large_0,stat_rx_oversize_0,stat_rx_undersize_0[1:0],stat_rx_toolong_0,stat_rx_fragment_0[1:0],stat_rx_packet_64_bytes_0,stat_rx_packet_65_127_bytes_0,stat_rx_packet_128_255_bytes_0,stat_rx_packet_256_511_bytes_0,stat_rx_packet_512_1023_bytes_0,stat_rx_packet_1024_1518_bytes_0,stat_rx_packet_1519_1522_bytes_0,stat_rx_packet_1523_1548_bytes_0,stat_rx_bad_fcs_0[1:0],stat_rx_packet_bad_fcs_0,stat_rx_stomped_fcs_0[1:0],stat_rx_packet_1549_2047_bytes_0,stat_rx_packet_2048_4095_bytes_0,stat_rx_packet_4096_8191_bytes_0,stat_rx_packet_8192_9215_bytes_0,stat_rx_unicast_0,stat_rx_multicast_0,stat_rx_broadcast_0,stat_rx_vlan_0,stat_rx_inrangeerr_0,stat_rx_bad_preamble_0,stat_rx_bad_sfd_0,stat_rx_got_signal_os_0,stat_rx_test_pattern_mismatch_0[1:0],stat_rx_truncated_0,stat_rx_local_fault_0,stat_rx_remote_fault_0,stat_rx_internal_local_fault_0,stat_rx_received_local_fault_0,tx_reset_0,user_tx_reset_0,tx_axis_tready_0,tx_axis_tvalid_0,tx_axis_tdata_0[255:0],tx_axis_tkeep_0[31:0],tx_axis_tuser_0,tx_axis_tlast_0,tx_unfout_0,tx_preamblein_0[55:0],ctl_tx_test_pattern_0,ctl_tx_enable_0,ctl_tx_fcs_ins_enable_0,ctl_tx_ipg_value_0[3:0],ctl_tx_send_lfi_0,ctl_tx_send_rfi_0,ctl_tx_send_idle_0,ctl_tx_custom_preamble_enable_0,ctl_tx_ignore_fcs_0,stat_tx_underflow_err_0,stat_tx_overflow_err_0,stat_tx_total_packets_0,stat_tx_total_bytes_0[4:0],stat_tx_total_good_packets_0,stat_tx_total_good_bytes_0[13:0],stat_tx_packet_64_bytes_0,stat_tx_packet_65_127_bytes_0,stat_tx_packet_128_255_bytes_0,stat_tx_packet_256_511_bytes_0,stat_tx_packet_512_1023_bytes_0,stat_tx_packet_1024_1518_bytes_0,stat_tx_packet_1519_1522_bytes_0,stat_tx_packet_1523_1548_bytes_0,stat_tx_packet_small_0,stat_tx_packet_large_0,stat_tx_packet_1549_2047_bytes_0,stat_tx_packet_2048_4095_bytes_0,stat_tx_packet_4096_8191_bytes_0,stat_tx_packet_8192_9215_bytes_0,stat_tx_unicast_0,stat_tx_multicast_0,stat_tx_broadcast_0,stat_tx_vlan_0,stat_tx_bad_fcs_0,stat_tx_frame_error_0,stat_tx_local_fault_0,gtpowergood_out_0[3:0],txoutclksel_in_0[11:0],rxoutclksel_in_0[11:0],gt_refclk_out,gt_refclk_p,gt_refclk_n,sys_reset,dclk";
  attribute X_CORE_INFO : string;
  attribute X_CORE_INFO of stub : architecture is "l_ethernet_v4_0_0,Vivado 2025.2";
begin
end;
