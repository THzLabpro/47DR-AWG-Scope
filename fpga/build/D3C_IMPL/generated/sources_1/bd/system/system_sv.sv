// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
// -------------------------------------------------------------------------------
// This file contains confidential and proprietary information
// of AMD and is protected under U.S. and international copyright
// and other intellectual property laws.
//
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// AMD, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) AMD shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or AMD had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// AMD products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of AMD products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
//
// DO NOT MODIFY THIS FILE.

// MODULE VLNV: amd.com:blockdesign:system:1.0

`timescale 1ps / 1ps

`include "vivado_interfaces.svh"

module system_sv (
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s00_axis" *)
  (* X_INTERFACE_MODE = "slave s00_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s00_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 612500000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.slave s00_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s02_axis" *)
  (* X_INTERFACE_MODE = "slave s02_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s02_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 612500000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.slave s02_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s10_axis" *)
  (* X_INTERFACE_MODE = "slave s10_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s10_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 612500000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.slave s10_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s12_axis" *)
  (* X_INTERFACE_MODE = "slave s12_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s12_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 612500000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.slave s12_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s20_axis" *)
  (* X_INTERFACE_MODE = "slave s20_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s20_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 612500000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.slave s20_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s22_axis" *)
  (* X_INTERFACE_MODE = "slave s22_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s22_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 612500000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.slave s22_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s30_axis" *)
  (* X_INTERFACE_MODE = "slave s30_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s30_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 612500000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.slave s30_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s32_axis" *)
  (* X_INTERFACE_MODE = "slave s32_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s32_axis, TDATA_NUM_BYTES 32, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 612500000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.slave s32_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m00_axis" *)
  (* X_INTERFACE_MODE = "master m00_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m00_axis, TDATA_NUM_BYTES 24, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 416666666, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m00_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m01_axis" *)
  (* X_INTERFACE_MODE = "master m01_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m01_axis, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 245760000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m01_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m02_axis" *)
  (* X_INTERFACE_MODE = "master m02_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m02_axis, TDATA_NUM_BYTES 24, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 416666666, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m02_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m03_axis" *)
  (* X_INTERFACE_MODE = "master m03_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m03_axis, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 245760000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m03_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m10_axis" *)
  (* X_INTERFACE_MODE = "master m10_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m10_axis, TDATA_NUM_BYTES 24, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 416666666, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m10_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m11_axis" *)
  (* X_INTERFACE_MODE = "master m11_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m11_axis, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 245760000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m11_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m12_axis" *)
  (* X_INTERFACE_MODE = "master m12_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m12_axis, TDATA_NUM_BYTES 24, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 416666666, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m12_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m13_axis" *)
  (* X_INTERFACE_MODE = "master m13_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m13_axis, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 245760000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m13_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m20_axis" *)
  (* X_INTERFACE_MODE = "master m20_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m20_axis, TDATA_NUM_BYTES 24, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 416666666, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m20_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m21_axis" *)
  (* X_INTERFACE_MODE = "master m21_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m21_axis, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 245760000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m21_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m22_axis" *)
  (* X_INTERFACE_MODE = "master m22_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m22_axis, TDATA_NUM_BYTES 24, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 416666666, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m22_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m23_axis" *)
  (* X_INTERFACE_MODE = "master m23_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m23_axis, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 245760000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m23_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m30_axis" *)
  (* X_INTERFACE_MODE = "master m30_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m30_axis, TDATA_NUM_BYTES 24, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 416666666, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m30_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m31_axis" *)
  (* X_INTERFACE_MODE = "master m31_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m31_axis, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 245760000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m31_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m32_axis" *)
  (* X_INTERFACE_MODE = "master m32_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m32_axis, TDATA_NUM_BYTES 24, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 416666666, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m32_axis,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m33_axis" *)
  (* X_INTERFACE_MODE = "master m33_axis" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m33_axis, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 245760000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0" *)
  vivado_axis_v1_0.master m33_axis,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire adc1_clk_clk_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire adc1_clk_clk_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire dac2_clk_clk_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire dac2_clk_clk_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin0_01_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin0_01_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin0_23_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin0_23_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin1_01_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin1_01_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin1_23_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin1_23_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin2_01_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin2_01_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin2_23_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin2_23_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin3_01_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin3_01_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin3_23_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire vin3_23_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout00_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout00_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout02_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout02_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout10_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout10_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout12_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout12_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout20_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout20_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout22_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout22_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout30_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout30_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout32_v_n,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire vout32_v_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire sysref_in_diff_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire sysref_in_diff_p,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire data_clk,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire user_sysref_adc_0,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire user_sysref_dac_0,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire up_wreq,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [15:0] up_waddr,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [31:0] up_wdata,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire up_rreq,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [15:0] up_raddr,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire up_wack,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire [31:0] up_rdata,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire up_rack,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire fclk_100m,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire pl_resetn0,
  (* X_INTERFACE_IGNORE = "true" *)
  input wire adc_fabric_ref,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire adc_capture_clk,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [0:0] adc_axis_resetn,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [0:0] rf_resetn,
  (* X_INTERFACE_IGNORE = "true" *)
  output wire [0:0] host_resetn
);

  // interface wire assignments
  assign m00_axis.TDEST = 0;
  assign m00_axis.TID = 0;
  assign m00_axis.TKEEP = 0;
  assign m00_axis.TLAST = 0;
  assign m00_axis.TSTRB = 0;
  assign m00_axis.TUSER = 0;
  assign m01_axis.TDATA = 0;
  assign m01_axis.TDEST = 0;
  assign m01_axis.TID = 0;
  assign m01_axis.TKEEP = 0;
  assign m01_axis.TLAST = 0;
  assign m01_axis.TSTRB = 0;
  assign m01_axis.TUSER = 0;
  assign m01_axis.TVALID = 0;
  assign m02_axis.TDEST = 0;
  assign m02_axis.TID = 0;
  assign m02_axis.TKEEP = 0;
  assign m02_axis.TLAST = 0;
  assign m02_axis.TSTRB = 0;
  assign m02_axis.TUSER = 0;
  assign m03_axis.TDATA = 0;
  assign m03_axis.TDEST = 0;
  assign m03_axis.TID = 0;
  assign m03_axis.TKEEP = 0;
  assign m03_axis.TLAST = 0;
  assign m03_axis.TSTRB = 0;
  assign m03_axis.TUSER = 0;
  assign m03_axis.TVALID = 0;
  assign m10_axis.TDEST = 0;
  assign m10_axis.TID = 0;
  assign m10_axis.TKEEP = 0;
  assign m10_axis.TLAST = 0;
  assign m10_axis.TSTRB = 0;
  assign m10_axis.TUSER = 0;
  assign m11_axis.TDATA = 0;
  assign m11_axis.TDEST = 0;
  assign m11_axis.TID = 0;
  assign m11_axis.TKEEP = 0;
  assign m11_axis.TLAST = 0;
  assign m11_axis.TSTRB = 0;
  assign m11_axis.TUSER = 0;
  assign m11_axis.TVALID = 0;
  assign m12_axis.TDEST = 0;
  assign m12_axis.TID = 0;
  assign m12_axis.TKEEP = 0;
  assign m12_axis.TLAST = 0;
  assign m12_axis.TSTRB = 0;
  assign m12_axis.TUSER = 0;
  assign m13_axis.TDATA = 0;
  assign m13_axis.TDEST = 0;
  assign m13_axis.TID = 0;
  assign m13_axis.TKEEP = 0;
  assign m13_axis.TLAST = 0;
  assign m13_axis.TSTRB = 0;
  assign m13_axis.TUSER = 0;
  assign m13_axis.TVALID = 0;
  assign m20_axis.TDEST = 0;
  assign m20_axis.TID = 0;
  assign m20_axis.TKEEP = 0;
  assign m20_axis.TLAST = 0;
  assign m20_axis.TSTRB = 0;
  assign m20_axis.TUSER = 0;
  assign m21_axis.TDATA = 0;
  assign m21_axis.TDEST = 0;
  assign m21_axis.TID = 0;
  assign m21_axis.TKEEP = 0;
  assign m21_axis.TLAST = 0;
  assign m21_axis.TSTRB = 0;
  assign m21_axis.TUSER = 0;
  assign m21_axis.TVALID = 0;
  assign m22_axis.TDEST = 0;
  assign m22_axis.TID = 0;
  assign m22_axis.TKEEP = 0;
  assign m22_axis.TLAST = 0;
  assign m22_axis.TSTRB = 0;
  assign m22_axis.TUSER = 0;
  assign m23_axis.TDATA = 0;
  assign m23_axis.TDEST = 0;
  assign m23_axis.TID = 0;
  assign m23_axis.TKEEP = 0;
  assign m23_axis.TLAST = 0;
  assign m23_axis.TSTRB = 0;
  assign m23_axis.TUSER = 0;
  assign m23_axis.TVALID = 0;
  assign m30_axis.TDEST = 0;
  assign m30_axis.TID = 0;
  assign m30_axis.TKEEP = 0;
  assign m30_axis.TLAST = 0;
  assign m30_axis.TSTRB = 0;
  assign m30_axis.TUSER = 0;
  assign m31_axis.TDATA = 0;
  assign m31_axis.TDEST = 0;
  assign m31_axis.TID = 0;
  assign m31_axis.TKEEP = 0;
  assign m31_axis.TLAST = 0;
  assign m31_axis.TSTRB = 0;
  assign m31_axis.TUSER = 0;
  assign m31_axis.TVALID = 0;
  assign m32_axis.TDEST = 0;
  assign m32_axis.TID = 0;
  assign m32_axis.TKEEP = 0;
  assign m32_axis.TLAST = 0;
  assign m32_axis.TSTRB = 0;
  assign m32_axis.TUSER = 0;
  assign m33_axis.TDATA = 0;
  assign m33_axis.TDEST = 0;
  assign m33_axis.TID = 0;
  assign m33_axis.TKEEP = 0;
  assign m33_axis.TLAST = 0;
  assign m33_axis.TSTRB = 0;
  assign m33_axis.TUSER = 0;
  assign m33_axis.TVALID = 0;

  system inst (
    .s00_axis_tdata(s00_axis.TDATA),
    .s00_axis_tready(s00_axis.TREADY),
    .s00_axis_tvalid(s00_axis.TVALID),
    .s02_axis_tdata(s02_axis.TDATA),
    .s02_axis_tready(s02_axis.TREADY),
    .s02_axis_tvalid(s02_axis.TVALID),
    .s10_axis_tdata(s10_axis.TDATA),
    .s10_axis_tready(s10_axis.TREADY),
    .s10_axis_tvalid(s10_axis.TVALID),
    .s12_axis_tdata(s12_axis.TDATA),
    .s12_axis_tready(s12_axis.TREADY),
    .s12_axis_tvalid(s12_axis.TVALID),
    .s20_axis_tdata(s20_axis.TDATA),
    .s20_axis_tready(s20_axis.TREADY),
    .s20_axis_tvalid(s20_axis.TVALID),
    .s22_axis_tdata(s22_axis.TDATA),
    .s22_axis_tready(s22_axis.TREADY),
    .s22_axis_tvalid(s22_axis.TVALID),
    .s30_axis_tdata(s30_axis.TDATA),
    .s30_axis_tready(s30_axis.TREADY),
    .s30_axis_tvalid(s30_axis.TVALID),
    .s32_axis_tdata(s32_axis.TDATA),
    .s32_axis_tready(s32_axis.TREADY),
    .s32_axis_tvalid(s32_axis.TVALID),
    .adc1_clk_clk_n(adc1_clk_clk_n),
    .adc1_clk_clk_p(adc1_clk_clk_p),
    .dac2_clk_clk_n(dac2_clk_clk_n),
    .dac2_clk_clk_p(dac2_clk_clk_p),
    .vin0_01_v_n(vin0_01_v_n),
    .vin0_01_v_p(vin0_01_v_p),
    .vin0_23_v_n(vin0_23_v_n),
    .vin0_23_v_p(vin0_23_v_p),
    .vin1_01_v_n(vin1_01_v_n),
    .vin1_01_v_p(vin1_01_v_p),
    .vin1_23_v_n(vin1_23_v_n),
    .vin1_23_v_p(vin1_23_v_p),
    .vin2_01_v_n(vin2_01_v_n),
    .vin2_01_v_p(vin2_01_v_p),
    .vin2_23_v_n(vin2_23_v_n),
    .vin2_23_v_p(vin2_23_v_p),
    .vin3_01_v_n(vin3_01_v_n),
    .vin3_01_v_p(vin3_01_v_p),
    .vin3_23_v_n(vin3_23_v_n),
    .vin3_23_v_p(vin3_23_v_p),
    .m00_axis_tdata(m00_axis.TDATA),
    .m00_axis_tready(m00_axis.TREADY),
    .m00_axis_tvalid(m00_axis.TVALID),
    .m02_axis_tdata(m02_axis.TDATA),
    .m02_axis_tready(m02_axis.TREADY),
    .m02_axis_tvalid(m02_axis.TVALID),
    .m10_axis_tdata(m10_axis.TDATA),
    .m10_axis_tready(m10_axis.TREADY),
    .m10_axis_tvalid(m10_axis.TVALID),
    .m12_axis_tdata(m12_axis.TDATA),
    .m12_axis_tready(m12_axis.TREADY),
    .m12_axis_tvalid(m12_axis.TVALID),
    .m20_axis_tdata(m20_axis.TDATA),
    .m20_axis_tready(m20_axis.TREADY),
    .m20_axis_tvalid(m20_axis.TVALID),
    .m22_axis_tdata(m22_axis.TDATA),
    .m22_axis_tready(m22_axis.TREADY),
    .m22_axis_tvalid(m22_axis.TVALID),
    .m30_axis_tdata(m30_axis.TDATA),
    .m30_axis_tready(m30_axis.TREADY),
    .m30_axis_tvalid(m30_axis.TVALID),
    .m32_axis_tdata(m32_axis.TDATA),
    .m32_axis_tready(m32_axis.TREADY),
    .m32_axis_tvalid(m32_axis.TVALID),
    .vout00_v_n(vout00_v_n),
    .vout00_v_p(vout00_v_p),
    .vout02_v_n(vout02_v_n),
    .vout02_v_p(vout02_v_p),
    .vout10_v_n(vout10_v_n),
    .vout10_v_p(vout10_v_p),
    .vout12_v_n(vout12_v_n),
    .vout12_v_p(vout12_v_p),
    .vout20_v_n(vout20_v_n),
    .vout20_v_p(vout20_v_p),
    .vout22_v_n(vout22_v_n),
    .vout22_v_p(vout22_v_p),
    .vout30_v_n(vout30_v_n),
    .vout30_v_p(vout30_v_p),
    .vout32_v_n(vout32_v_n),
    .vout32_v_p(vout32_v_p),
    .sysref_in_diff_n(sysref_in_diff_n),
    .sysref_in_diff_p(sysref_in_diff_p),
    .data_clk(data_clk),
    .user_sysref_adc_0(user_sysref_adc_0),
    .user_sysref_dac_0(user_sysref_dac_0),
    .up_wreq(up_wreq),
    .up_waddr(up_waddr),
    .up_wdata(up_wdata),
    .up_rreq(up_rreq),
    .up_raddr(up_raddr),
    .up_wack(up_wack),
    .up_rdata(up_rdata),
    .up_rack(up_rack),
    .fclk_100m(fclk_100m),
    .pl_resetn0(pl_resetn0),
    .adc_fabric_ref(adc_fabric_ref),
    .adc_capture_clk(adc_capture_clk),
    .adc_axis_resetn(adc_axis_resetn),
    .rf_resetn(rf_resetn),
    .host_resetn(host_resetn)
  );

endmodule
