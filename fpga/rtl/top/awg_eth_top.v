`timescale 1ns/1ps
`default_nettype none

// =============================================================
// 模組：awg_eth_top
// 功能：RFDC、AWG v2 控制器、40GbE core/bridge 與 JTAG AXI 仲裁正式頂層
// 時鐘/復位：BD 輸出的 DAC/ADC/host 時鐘與各自 active-low reset
// 輸入：D0 RFDC/PS 板級管腳、QSFP2 40GbE 管腳
// 輸出：RFDC DAC、QSFP2、LED 與控制狀態
// 關鍵參數：DAC 9.8 GS/s、ADC 5.0 GS/s、AXI base 0x9020_0000
// =============================================================
module awg_eth_top (
    input  wire pl_clk_n, input wire pl_clk_p,
    input  wire pl_sysref_n, input wire pl_sysref_p,
    input  wire adc1_clk_n, input wire adc1_clk_p,
    input  wire dac2_clk_n, input wire dac2_clk_p,
    input  wire sysref_in_n, input wire sysref_in_p,
    input  wire vin0_01_n, input wire vin0_01_p,
    input  wire vin0_23_n, input wire vin0_23_p,
    input  wire vin1_01_n, input wire vin1_01_p,
    input  wire vin1_23_n, input wire vin1_23_p,
    input  wire vin2_01_n, input wire vin2_01_p,
    input  wire vin2_23_n, input wire vin2_23_p,
    input  wire vin3_01_n, input wire vin3_01_p,
    input  wire vin3_23_n, input wire vin3_23_p,
    output wire vout00_n, output wire vout00_p,
    output wire vout02_n, output wire vout02_p,
    output wire vout10_n, output wire vout10_p,
    output wire vout12_n, output wire vout12_p,
    output wire vout20_n, output wire vout20_p,
    output wire vout22_n, output wire vout22_p,
    output wire vout30_n, output wire vout30_p,
    output wire vout32_n, output wire vout32_p,
    output wire [1:0] led,
    output wire qsfp2_reset_n,
    output wire qsfp2_lpmode,
    output wire qsfp2_modsel_n,
    input  wire qsfp2_refclk_p, input wire qsfp2_refclk_n,
    input  wire [3:0] qsfp2_rx_p, input wire [3:0] qsfp2_rx_n,
    output wire [3:0] qsfp2_tx_p, output wire [3:0] qsfp2_tx_n
);

    wire data_clk;
    wire adc_capture_clk;
    wire pl_clk_raw;
    wire pl_clk;
    wire pl_sysref;
    wire fclk_100m;
    wire rf_resetn;
    wire adc_axis_resetn;
    wire pl_resetn0;
    wire host_resetn;
    wire tx_clk;
    wire rx_clk;

    // Each consumer receives a locally synchronized reset.  The small local
    // registers limit reset fanout at the high-rate RF domains.
    wire dac_resetn_sync, tx_resetn_sync, adc_resetn_sync, rx_resetn_sync, host_resetn_sync;
    (* MAX_FANOUT = 64 *) reg dac_resetn_local, tx_resetn_local, adc_resetn_local, rx_resetn_local, host_resetn_local;
    reg [1:0] eth_reset_pipe;
    wire eth_sys_reset = eth_reset_pipe[1];
    reset_sync dac_reset_sync_i (.clk(data_clk), .async_resetn(rf_resetn), .resetn(dac_resetn_sync));
    reset_sync tx_reset_sync_i (.clk(tx_clk), .async_resetn(rf_resetn), .resetn(tx_resetn_sync));
    reset_sync adc_reset_sync_i (.clk(adc_capture_clk), .async_resetn(adc_axis_resetn), .resetn(adc_resetn_sync));
    reset_sync rx_reset_sync_i (.clk(rx_clk), .async_resetn(adc_axis_resetn), .resetn(rx_resetn_sync));
    reset_sync host_reset_sync_i (.clk(fclk_100m), .async_resetn(host_resetn), .resetn(host_resetn_sync));
    always @(posedge data_clk or negedge rf_resetn) begin
        if (!rf_resetn) dac_resetn_local <= 1'b0;
        else dac_resetn_local <= dac_resetn_sync;
    end
    always @(posedge tx_clk or negedge rf_resetn) begin
        if (!rf_resetn) tx_resetn_local <= 1'b0;
        else tx_resetn_local <= tx_resetn_sync;
    end
    always @(posedge adc_capture_clk or negedge adc_axis_resetn) begin
        if (!adc_axis_resetn) adc_resetn_local <= 1'b0;
        else adc_resetn_local <= adc_resetn_sync;
    end
    always @(posedge rx_clk or negedge adc_axis_resetn) begin
        if (!adc_axis_resetn) rx_resetn_local <= 1'b0;
        else rx_resetn_local <= rx_resetn_sync;
    end
    always @(posedge fclk_100m or negedge host_resetn) begin
        if (!host_resetn) host_resetn_local <= 1'b0;
        else host_resetn_local <= host_resetn_sync;
    end
    always @(posedge fclk_100m or negedge host_resetn_local) begin
        if (!host_resetn_local) eth_reset_pipe <= 2'b11;
        else eth_reset_pipe <= {eth_reset_pipe[0], 1'b0};
    end

    IBUFDS pl_clk_ibufds (.I(pl_clk_p), .IB(pl_clk_n), .O(pl_clk_raw));
    BUFG pl_clk_bufg (.I(pl_clk_raw), .O(pl_clk));
    IBUFDS pl_sysref_ibufds (.I(pl_sysref_p), .IB(pl_sysref_n), .O(pl_sysref));
    reg pl_sysref_r;
    (* ASYNC_REG = "TRUE" *) reg sysref_dac_meta;
    (* ASYNC_REG = "TRUE" *) reg sysref_adc_meta;
    always @(posedge pl_clk) pl_sysref_r <= pl_sysref;
    (* ASYNC_REG = "TRUE" *) reg user_sysref_dac;
    (* ASYNC_REG = "TRUE" *) reg user_sysref_adc;
    always @(posedge data_clk) begin
        sysref_dac_meta <= pl_sysref_r;
        user_sysref_dac <= sysref_dac_meta;
    end
    always @(posedge adc_capture_clk) begin
        sysref_adc_meta <= pl_sysref_r;
        user_sysref_adc <= sysref_adc_meta;
    end

    wire [8*192-1:0] adc_tdata;
    wire [7:0] adc_tvalid;
    wire [7:0] adc_tready = 8'hff;
    wire [8*256-1:0] dac_tdata;
    wire [7:0] dac_tvalid;
    wire [7:0] dac_tready;

    wire up_rack;
    wire [15:0] up_raddr;
    wire [31:0] up_rdata;
    wire up_rreq;
    wire up_wack;
    wire [15:0] up_waddr;
    wire [31:0] up_wdata;
    wire up_wreq;
    wire config_done;
    wire [7:0] adc_freeze;
    wire [7:0] adc_clear_ov;

    wire [31:0] j_awaddr, j_wdata, j_araddr, j_rdata;
    wire [3:0] j_wstrb;
    wire [1:0] j_bresp, j_rresp;
    wire j_awvalid, j_awready, j_wvalid, j_wready, j_bvalid, j_bready;
    wire j_arvalid, j_arready, j_rvalid, j_rready;

    wire [31:0] e_awaddr, e_wdata, e_araddr, e_rdata;
    wire [3:0] e_wstrb;
    wire [1:0] e_bresp, e_rresp;
    wire e_awvalid, e_awready, e_wvalid, e_wready, e_bvalid, e_bready;
    wire e_arvalid, e_arready, e_rvalid, e_rready;

    wire [31:0] c_awaddr, c_wdata, c_araddr, c_rdata;
    wire [3:0] c_wstrb;
    wire [1:0] c_bresp, c_rresp;
    wire c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready;
    wire c_arvalid, c_arready, c_rvalid, c_rready;

    wire clk_eth, rst_eth;
    wire rx_hdr_valid, rx_hdr_ready;
    wire [31:0] rx_src_ip;
    wire [15:0] rx_src_port, rx_length;
    wire [63:0] rx_payload_tdata;
    wire [7:0] rx_payload_tkeep;
    wire rx_payload_tvalid, rx_payload_tready, rx_payload_tlast, rx_payload_tuser;
    wire tx_hdr_valid, tx_hdr_ready;
    wire [31:0] tx_dst_ip;
    wire [15:0] tx_dst_port, tx_length;
    wire [63:0] tx_payload_tdata;
    wire [7:0] tx_payload_tkeep;
    wire tx_payload_tvalid, tx_payload_tready, tx_payload_tlast, tx_payload_tuser;
    wire rx_gt_locked, rx_aligned;

    wire [2:0] tx_h_wr_ch;
    wire tx_h_wr_rewind;
    wire [31:0] tx_h_wr_data;
    wire tx_h_wr_valid, tx_h_wr_ready;
    wire [17:0] tx_h_wr_ptr;
    wire tx_h_crc_start;
    wire [2:0] tx_h_crc_ch;
    wire tx_h_crc_busy;
    wire [31:0] tx_h_crc_value;
    wire tx_h_start, tx_h_stop, tx_h_clear_fault;
    wire [12:0] tx_h_length_words;
    wire [7:0] tx_h_mask;
    wire tx_h_running, tx_h_started, tx_h_locked, tx_h_start_rejected;
    wire [7:0] tx_h_faults;
    wire [31:0] tx_h_wrap_count;
    wire tx_start_event, tx_start_event_toggle;
    wire [11:0] tx_play_word;

    wire rx_h_arm, rx_h_abort, rx_h_trig_mode;
    wire [11:0] rx_h_cap_words;
    wire rx_h_busy, rx_h_armed, rx_h_done;
    wire [16:0] rx_h_captured_samples;
    wire [11:0] rx_h_cap_tx_word;
    wire [2:0] rx_h_rd_ch;
    wire [14:0] rx_h_rd_pair;
    wire rx_h_rd_req, rx_h_rd_valid;
    wire [31:0] rx_h_rd_data;

    BUFGCE_DIV #(.BUFGCE_DIVIDE(2)) tx_clk_div (.I(data_clk), .CE(1'b1), .CLR(1'b0), .O(tx_clk));
    BUFGCE_DIV #(.BUFGCE_DIVIDE(2)) rx_clk_div (.I(adc_capture_clk), .CE(1'b1), .CLR(1'b0), .O(rx_clk));

    system_wrapper system_i (
        .adc1_clk_clk_n(adc1_clk_n), .adc1_clk_clk_p(adc1_clk_p),
        .dac2_clk_clk_n(dac2_clk_n), .dac2_clk_clk_p(dac2_clk_p),
        .data_clk(data_clk), .adc_capture_clk(adc_capture_clk),
        .adc_axis_resetn(adc_axis_resetn), .pl_resetn0(pl_resetn0),
        .rf_resetn(rf_resetn), .host_resetn(host_resetn),
        .m00_axis_tdata(adc_tdata[0*192 +: 192]), .m00_axis_tready(adc_tready[0]), .m00_axis_tvalid(adc_tvalid[0]),
        .m02_axis_tdata(adc_tdata[1*192 +: 192]), .m02_axis_tready(adc_tready[1]), .m02_axis_tvalid(adc_tvalid[1]),
        .m10_axis_tdata(adc_tdata[2*192 +: 192]), .m10_axis_tready(adc_tready[2]), .m10_axis_tvalid(adc_tvalid[2]),
        .m12_axis_tdata(adc_tdata[3*192 +: 192]), .m12_axis_tready(adc_tready[3]), .m12_axis_tvalid(adc_tvalid[3]),
        .m20_axis_tdata(adc_tdata[4*192 +: 192]), .m20_axis_tready(adc_tready[4]), .m20_axis_tvalid(adc_tvalid[4]),
        .m22_axis_tdata(adc_tdata[5*192 +: 192]), .m22_axis_tready(adc_tready[5]), .m22_axis_tvalid(adc_tvalid[5]),
        .m30_axis_tdata(adc_tdata[6*192 +: 192]), .m30_axis_tready(adc_tready[6]), .m30_axis_tvalid(adc_tvalid[6]),
        .m32_axis_tdata(adc_tdata[7*192 +: 192]), .m32_axis_tready(adc_tready[7]), .m32_axis_tvalid(adc_tvalid[7]),
        .s00_axis_tdata(dac_tdata[0*256 +: 256]), .s00_axis_tready(dac_tready[0]), .s00_axis_tvalid(dac_tvalid[0]),
        .s02_axis_tdata(dac_tdata[1*256 +: 256]), .s02_axis_tready(dac_tready[1]), .s02_axis_tvalid(dac_tvalid[1]),
        .s10_axis_tdata(dac_tdata[2*256 +: 256]), .s10_axis_tready(dac_tready[2]), .s10_axis_tvalid(dac_tvalid[2]),
        .s12_axis_tdata(dac_tdata[3*256 +: 256]), .s12_axis_tready(dac_tready[3]), .s12_axis_tvalid(dac_tvalid[3]),
        .s20_axis_tdata(dac_tdata[4*256 +: 256]), .s20_axis_tready(dac_tready[4]), .s20_axis_tvalid(dac_tvalid[4]),
        .s22_axis_tdata(dac_tdata[5*256 +: 256]), .s22_axis_tready(dac_tready[5]), .s22_axis_tvalid(dac_tvalid[5]),
        .s30_axis_tdata(dac_tdata[6*256 +: 256]), .s30_axis_tready(dac_tready[6]), .s30_axis_tvalid(dac_tvalid[6]),
        .s32_axis_tdata(dac_tdata[7*256 +: 256]), .s32_axis_tready(dac_tready[7]), .s32_axis_tvalid(dac_tvalid[7]),
        .sysref_in_diff_n(sysref_in_n), .sysref_in_diff_p(sysref_in_p),
        .fclk_100m(fclk_100m), .up_rack(up_rack), .up_raddr(up_raddr), .up_rdata(up_rdata), .up_rreq(up_rreq),
        .up_wack(up_wack), .up_waddr(up_waddr), .up_wdata(up_wdata), .up_wreq(up_wreq),
        .adc_fabric_ref(pl_clk), .user_sysref_adc_0(user_sysref_adc), .user_sysref_dac_0(user_sysref_dac),
        .vin0_01_v_n(vin0_01_n), .vin0_01_v_p(vin0_01_p), .vin0_23_v_n(vin0_23_n), .vin0_23_v_p(vin0_23_p),
        .vin1_01_v_n(vin1_01_n), .vin1_01_v_p(vin1_01_p), .vin1_23_v_n(vin1_23_n), .vin1_23_v_p(vin1_23_p),
        .vin2_01_v_n(vin2_01_n), .vin2_01_v_p(vin2_01_p), .vin2_23_v_n(vin2_23_n), .vin2_23_v_p(vin2_23_p),
        .vin3_01_v_n(vin3_01_n), .vin3_01_v_p(vin3_01_p), .vin3_23_v_n(vin3_23_n), .vin3_23_v_p(vin3_23_p),
        .vout00_v_n(vout00_n), .vout00_v_p(vout00_p), .vout02_v_n(vout02_n), .vout02_v_p(vout02_p),
        .vout10_v_n(vout10_n), .vout10_v_p(vout10_p), .vout12_v_n(vout12_n), .vout12_v_p(vout12_p),
        .vout20_v_n(vout20_n), .vout20_v_p(vout20_p), .vout22_v_n(vout22_n), .vout22_v_p(vout22_p),
        .vout30_v_n(vout30_n), .vout30_v_p(vout30_p), .vout32_v_n(vout32_n), .vout32_v_p(vout32_p)
    );

    user_control user_control_i (
        .axi_gp_clk(fclk_100m), .axi_rst(!host_resetn_local),
        .up_wreq(up_wreq), .up_waddr(up_waddr), .up_wdata(up_wdata), .up_wack(up_wack),
        .up_rreq(up_rreq), .up_raddr(up_raddr), .up_rdata(up_rdata), .up_rack(up_rack),
        .mtime_start(), .pps_select(), .clock_1pps(), .phase(), .rf_mode(),
        .config_done(config_done), .adc_freeze(adc_freeze), .adc_clear_ov(adc_clear_ov),
        .sdr_info(32'h1000_0348), .fw_ver(32'h0001_0000), .adc_over_volt(8'd0), .dev_clk_locked(rf_resetn)
    );

    jtag_awg_axi jtag_axi_i (
        .aclk(fclk_100m), .aresetn(host_resetn_local),
        .m_axi_awaddr(j_awaddr), .m_axi_awprot(), .m_axi_awvalid(j_awvalid), .m_axi_awready(j_awready),
        .m_axi_wdata(j_wdata), .m_axi_wstrb(j_wstrb), .m_axi_wvalid(j_wvalid), .m_axi_wready(j_wready),
        .m_axi_bresp(j_bresp), .m_axi_bvalid(j_bvalid), .m_axi_bready(j_bready),
        .m_axi_araddr(j_araddr), .m_axi_arprot(), .m_axi_arvalid(j_arvalid), .m_axi_arready(j_arready),
        .m_axi_rdata(j_rdata), .m_axi_rresp(j_rresp), .m_axi_rvalid(j_rvalid), .m_axi_rready(j_rready)
    );

    awg_eth_core #(.RX_FIFO_DEPTH(32768), .TX_FIFO_DEPTH(16384), .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(16384)) eth_core_i (
        .qsfp2_reset_n(qsfp2_reset_n), .qsfp2_lpmode(qsfp2_lpmode), .qsfp2_modsel_n(qsfp2_modsel_n),
        .qsfp2_refclk_p(qsfp2_refclk_p), .qsfp2_refclk_n(qsfp2_refclk_n), .qsfp2_rx_p(qsfp2_rx_p), .qsfp2_rx_n(qsfp2_rx_n),
        .qsfp2_tx_p(qsfp2_tx_p), .qsfp2_tx_n(qsfp2_tx_n), .sys_reset(eth_sys_reset), .clk_eth(clk_eth), .rst_eth(rst_eth),
        .rx_hdr_valid(rx_hdr_valid), .rx_hdr_ready(rx_hdr_ready), .rx_src_ip(rx_src_ip), .rx_src_port(rx_src_port), .rx_length(rx_length),
        .rx_payload_tdata(rx_payload_tdata), .rx_payload_tkeep(rx_payload_tkeep), .rx_payload_tvalid(rx_payload_tvalid),
        .rx_payload_tready(rx_payload_tready), .rx_payload_tlast(rx_payload_tlast), .rx_payload_tuser(rx_payload_tuser),
        .tx_hdr_valid(tx_hdr_valid), .tx_hdr_ready(tx_hdr_ready), .tx_dst_ip(tx_dst_ip), .tx_dst_port(tx_dst_port), .tx_length(tx_length),
        .tx_payload_tdata(tx_payload_tdata), .tx_payload_tkeep(tx_payload_tkeep), .tx_payload_tvalid(tx_payload_tvalid),
        .tx_payload_tready(tx_payload_tready), .tx_payload_tlast(tx_payload_tlast), .tx_payload_tuser(tx_payload_tuser),
        .rx_gt_locked(rx_gt_locked), .rx_aligned(rx_aligned), .rx_frames(), .rx_udp_9100(), .rx_udp_other(), .rx_non_ip(), .tx_frames()
    );

    awg_eth_bridge #(.BUILD_ID(32'hD3C0_2026), .RX_FIFO_DEPTH(32768), .TX_FIFO_DEPTH(32768)) eth_bridge_i (
        .clk_eth(clk_eth), .rst_eth(rst_eth), .rx_hdr_valid(rx_hdr_valid), .rx_hdr_ready(rx_hdr_ready), .rx_src_ip(rx_src_ip), .rx_src_port(rx_src_port), .rx_length(rx_length),
        .rx_payload_tdata(rx_payload_tdata), .rx_payload_tkeep(rx_payload_tkeep), .rx_payload_tvalid(rx_payload_tvalid), .rx_payload_tready(rx_payload_tready), .rx_payload_tlast(rx_payload_tlast), .rx_payload_tuser(rx_payload_tuser),
        .tx_hdr_valid(tx_hdr_valid), .tx_hdr_ready(tx_hdr_ready), .tx_dst_ip(tx_dst_ip), .tx_dst_port(tx_dst_port), .tx_length(tx_length), .tx_payload_tdata(tx_payload_tdata), .tx_payload_tkeep(tx_payload_tkeep), .tx_payload_tvalid(tx_payload_tvalid), .tx_payload_tready(tx_payload_tready), .tx_payload_tlast(tx_payload_tlast), .tx_payload_tuser(tx_payload_tuser),
        .host_clk(fclk_100m), .host_resetn(host_resetn_local), .m_awaddr(e_awaddr), .m_awvalid(e_awvalid), .m_awready(e_awready), .m_wdata(e_wdata), .m_wstrb(e_wstrb), .m_wvalid(e_wvalid), .m_wready(e_wready), .m_bresp(e_bresp), .m_bvalid(e_bvalid), .m_bready(e_bready), .m_araddr(e_araddr), .m_arvalid(e_arvalid), .m_arready(e_arready), .m_rdata(e_rdata), .m_rresp(e_rresp), .m_rvalid(e_rvalid), .m_rready(e_rready)
    );

    axil_arb2 arb_i (
        .clk(fclk_100m), .resetn(host_resetn_local),
        .s0_awaddr(j_awaddr), .s0_awvalid(j_awvalid), .s0_awready(j_awready), .s0_wdata(j_wdata), .s0_wstrb(j_wstrb), .s0_wvalid(j_wvalid), .s0_wready(j_wready), .s0_bresp(j_bresp), .s0_bvalid(j_bvalid), .s0_bready(j_bready), .s0_araddr(j_araddr), .s0_arvalid(j_arvalid), .s0_arready(j_arready), .s0_rdata(j_rdata), .s0_rresp(j_rresp), .s0_rvalid(j_rvalid), .s0_rready(j_rready),
        .s1_awaddr(e_awaddr), .s1_awvalid(e_awvalid), .s1_awready(e_awready), .s1_wdata(e_wdata), .s1_wstrb(e_wstrb), .s1_wvalid(e_wvalid), .s1_wready(e_wready), .s1_bresp(e_bresp), .s1_bvalid(e_bvalid), .s1_bready(e_bready), .s1_araddr(e_araddr), .s1_arvalid(e_arvalid), .s1_arready(e_arready), .s1_rdata(e_rdata), .s1_rresp(e_rresp), .s1_rvalid(e_rvalid), .s1_rready(e_rready),
        .m_awaddr(c_awaddr), .m_awvalid(c_awvalid), .m_awready(c_awready), .m_wdata(c_wdata), .m_wstrb(c_wstrb), .m_wvalid(c_wvalid), .m_wready(c_wready), .m_bresp(c_bresp), .m_bvalid(c_bvalid), .m_bready(c_bready), .m_araddr(c_araddr), .m_arvalid(c_arvalid), .m_arready(c_arready), .m_rdata(c_rdata), .m_rresp(c_rresp), .m_rvalid(c_rvalid), .m_rready(c_rready)
    );

    awg_control_v2 #(.BUILD_ID(32'hD3C0_2026)) control_i (
        .host_clk(fclk_100m), .host_resetn(host_resetn_local),
        .s_awaddr(c_awaddr), .s_awvalid(c_awvalid), .s_awready(c_awready), .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wvalid(c_wvalid), .s_wready(c_wready), .s_bresp(c_bresp), .s_bvalid(c_bvalid), .s_bready(c_bready), .s_araddr(c_araddr), .s_arvalid(c_arvalid), .s_arready(c_arready), .s_rdata(c_rdata), .s_rresp(c_rresp), .s_rvalid(c_rvalid), .s_rready(c_rready),
        .ps_ready(config_done),
        .tx_h_wr_ch(tx_h_wr_ch), .tx_h_wr_rewind(tx_h_wr_rewind), .tx_h_wr_data(tx_h_wr_data), .tx_h_wr_valid(tx_h_wr_valid), .tx_h_wr_ready(tx_h_wr_ready), .tx_h_wr_ptr(tx_h_wr_ptr), .tx_h_crc_start(tx_h_crc_start), .tx_h_crc_ch(tx_h_crc_ch), .tx_h_crc_busy(tx_h_crc_busy), .tx_h_crc_value(tx_h_crc_value), .tx_h_start(tx_h_start), .tx_h_stop(tx_h_stop), .tx_h_clear_fault(tx_h_clear_fault), .tx_h_length_words(tx_h_length_words), .tx_h_mask(tx_h_mask), .tx_h_running(tx_h_running), .tx_h_started(tx_h_started), .tx_h_faults(tx_h_faults), .tx_h_wrap_count(tx_h_wrap_count), .tx_h_locked(tx_h_locked), .tx_h_start_rejected(tx_h_start_rejected),
        .rx_h_arm(rx_h_arm), .rx_h_abort(rx_h_abort), .rx_h_trig_mode(rx_h_trig_mode), .rx_h_cap_words(rx_h_cap_words), .rx_h_busy(rx_h_busy), .rx_h_armed(rx_h_armed), .rx_h_done(rx_h_done), .rx_h_captured_samples(rx_h_captured_samples), .rx_h_cap_tx_word(rx_h_cap_tx_word), .rx_h_rd_ch(rx_h_rd_ch), .rx_h_rd_pair(rx_h_rd_pair), .rx_h_rd_req(rx_h_rd_req), .rx_h_rd_data(rx_h_rd_data), .rx_h_rd_valid(rx_h_rd_valid), .dbg_cmd_busy()
    );

    awg_tx tx_i (
        .host_clk(fclk_100m), .host_resetn(host_resetn_local), .tx_clk(tx_clk), .tx_resetn(tx_resetn_local), .dac_clk(data_clk), .dac_resetn(dac_resetn_local), .ps_config_done(config_done),
        .h_wr_ch(tx_h_wr_ch), .h_wr_rewind(tx_h_wr_rewind), .h_wr_data(tx_h_wr_data), .h_wr_valid(tx_h_wr_valid), .h_wr_ready(tx_h_wr_ready), .h_wr_ptr(tx_h_wr_ptr), .h_crc_start(tx_h_crc_start), .h_crc_ch(tx_h_crc_ch), .h_crc_busy(tx_h_crc_busy), .h_crc_value(tx_h_crc_value), .h_start(tx_h_start), .h_stop(tx_h_stop), .h_clear_fault(tx_h_clear_fault), .h_length_words(tx_h_length_words), .h_mask(tx_h_mask), .h_running(tx_h_running), .h_started(tx_h_started), .h_faults(tx_h_faults), .h_wrap_count(tx_h_wrap_count), .h_locked(tx_h_locked), .h_start_rejected(tx_h_start_rejected), .dac_tdata(dac_tdata), .dac_tvalid(dac_tvalid), .dac_tready(dac_tready), .tx_start_event(tx_start_event), .tx_start_event_toggle(tx_start_event_toggle), .tx_play_word(tx_play_word)
    );

    awg_rx rx_i (
        .adc_clk(adc_capture_clk), .adc_resetn(adc_resetn_local), .dac_clk(data_clk), .tx_clk(tx_clk), .tx_resetn(tx_resetn_local), .rx_clk(rx_clk), .rx_resetn(rx_resetn_local), .host_clk(fclk_100m), .host_resetn(host_resetn_local),
        .h_arm(rx_h_arm), .h_abort(rx_h_abort), .h_trig_mode(rx_h_trig_mode), .h_cap_words(rx_h_cap_words), .h_busy(rx_h_busy), .h_armed(rx_h_armed), .h_done(rx_h_done), .h_captured_samples(rx_h_captured_samples), .h_cap_tx_word(rx_h_cap_tx_word), .h_rd_ch(rx_h_rd_ch), .h_rd_pair(rx_h_rd_pair), .h_rd_req(rx_h_rd_req), .h_rd_data(rx_h_rd_data), .h_rd_valid(rx_h_rd_valid), .adc_tdata(adc_tdata), .adc_tvalid(adc_tvalid), .tx_start_event_toggle(tx_start_event_toggle), .tx_play_word(tx_play_word)
    );

    assign led[0] = tx_h_running && (tx_h_faults == 0);
    assign led[1] = rx_aligned;
endmodule

`default_nettype wire
