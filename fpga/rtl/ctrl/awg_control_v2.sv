`timescale 1ns/1ps
`default_nettype none

// =============================================================
// 模組：awg_control_v2
// 功能：AWG/Scope v2 AXI4-Lite 控制器與資料埠命令整合
// 時鐘/復位：host_clk；host_resetn 同步低有效
// 輸入：AXI4-Lite slave、awg_tx/awg_rx host 埠與 PS ready
// 輸出：AXI4-Lite 回應及 awg_tx/awg_rx 單拍控制脈衝
// 關鍵參數：基址 0x9020_0000；TX 4096 字、RX 2730 字
// =============================================================
module awg_control_v2 #(
    parameter [31:0] BUILD_ID = 32'hD3A3_0001
) (
    input  wire        host_clk,
    input  wire        host_resetn,
    input  wire [31:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,
    input  wire        ps_ready,

    output reg  [2:0]  tx_h_wr_ch,
    output reg         tx_h_wr_rewind,
    output reg  [31:0] tx_h_wr_data,
    output reg         tx_h_wr_valid,
    input  wire        tx_h_wr_ready,
    input  wire [17:0] tx_h_wr_ptr,
    output reg         tx_h_crc_start,
    output reg  [2:0]  tx_h_crc_ch,
    input  wire        tx_h_crc_busy,
    input  wire [31:0] tx_h_crc_value,
    output reg         tx_h_start,
    output reg         tx_h_stop,
    output reg         tx_h_clear_fault,
    output reg  [12:0] tx_h_length_words,
    output reg  [7:0]  tx_h_mask,
    input  wire        tx_h_running,
    input  wire        tx_h_started,
    input  wire [7:0]  tx_h_faults,
    input  wire [31:0] tx_h_wrap_count,
    input  wire        tx_h_locked,
    input  wire        tx_h_start_rejected,

    output reg         rx_h_arm,
    output reg         rx_h_abort,
    output reg         rx_h_trig_mode,
    output reg  [11:0] rx_h_cap_words,
    input  wire        rx_h_busy,
    input  wire        rx_h_armed,
    input  wire        rx_h_done,
    input  wire [16:0] rx_h_captured_samples,
    input  wire [11:0] rx_h_cap_tx_word,
    output reg  [2:0]  rx_h_rd_ch,
    output reg  [14:0] rx_h_rd_pair,
    output reg         rx_h_rd_req,
    input  wire [31:0] rx_h_rd_data,
    input  wire        rx_h_rd_valid,
    output wire        dbg_cmd_busy
);

    localparam [31:0] BASE_ADDR = 32'h9020_0000;
    localparam [31:0] ID_VALUE = 32'h4157_4732;
    localparam [31:0] ABI_VALUE = 32'h0003_0001;
    localparam [12:0] TX_MAX_WORDS = 13'd4096;
    localparam [11:0] CAP_MAX_WORDS = 12'd2730;
    localparam [14:0] CAP_MAX_PAIR = 15'd32760;
    localparam [1:0] AXI_OK = 2'b00;
    localparam [1:0] AXI_SLVERR = 2'b10;
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_WRITE = 3'd1;
    localparam [2:0] ST_WR_DATA = 3'd2;
    localparam [2:0] ST_READ = 3'd3;
    localparam [2:0] ST_RD_DATA = 3'd4;

    reg aw_hold, w_hold, ar_hold;
    reg [31:0] awaddr_q, wdata_q, araddr_q;
    reg [3:0]  wstrb_q;
    reg [2:0]  state;
    reg [2:0]  selected_wr_ch, selected_rd_ch;
    reg [14:0] selected_rd_pair;
    reg [11:0] cap_words_cfg;
    reg        cap_trig_cfg;
    reg [1:0]  last_cmd_result;
    reg [17:0] written_samples [0:7];
    reg        rd_req_issued;
    reg [3:0]  rd_wait;
    integer i;

    wire write_pair = aw_hold && w_hold && state == ST_IDLE;
    wire read_pending = ar_hold && state == ST_IDLE;
    wire control_busy = (state != ST_IDLE) || aw_hold || w_hold || ar_hold || s_bvalid || s_rvalid;
    assign dbg_cmd_busy = control_busy;
    assign s_awready = !aw_hold && state == ST_IDLE && !s_bvalid && !s_rvalid && !ar_hold;
    assign s_wready  = !w_hold  && state == ST_IDLE && !s_bvalid && !s_rvalid && !ar_hold;
    assign s_arready = !ar_hold && state == ST_IDLE && !s_bvalid && !s_rvalid && !aw_hold && !w_hold;

    wire aw_fire = s_awvalid && s_awready;
    wire w_fire  = s_wvalid && s_wready;
    wire ar_fire = s_arvalid && s_arready;

    function automatic [31:0] apply_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  strb;
        integer b;
        begin
            apply_wstrb = old_value;
            for (b = 0; b < 4; b = b + 1)
                if (strb[b]) apply_wstrb[b*8 +: 8] = new_value[b*8 +: 8];
        end
    endfunction

    function automatic [31:0] read_value;
        input [31:0] addr;
        reg [31:0] value;
        begin
            value = 32'd0;
            value[0] = tx_h_running;
            value[1] = (tx_h_locked && !tx_h_running) || tx_h_crc_busy;
            value[2] = ps_ready;
            value[3] = (tx_h_faults != 0);
            value[5:4] = last_cmd_result;
            value[6] = rx_h_busy;
            value[7] = rx_h_done;
            value[8] = tx_h_crc_busy;
            case (addr - BASE_ADDR)
                32'h00: read_value = ID_VALUE;
                32'h04: read_value = value;
                32'h0c: read_value = {{19{1'b0}}, tx_h_length_words};
                32'h10: read_value = {24'd0, tx_h_mask};
                32'h14: read_value = 32'd9_800_000;
                32'h18: read_value = 32'd5_000_000;
                32'h1c: read_value = {24'd0, tx_h_faults};
                32'h20: read_value = ABI_VALUE;
                32'h24: read_value = {16'd2730, 3'd0, TX_MAX_WORDS};
                32'h28: read_value = {29'd0, rx_h_armed, rx_h_done, rx_h_busy};
                32'h2c: read_value = {15'd0, rx_h_captured_samples};
                32'h30: read_value = {29'd0, selected_wr_ch};
                32'h34: read_value = {14'd0, tx_h_wr_ptr};
                32'h3c: read_value = tx_h_crc_value;
                32'h40: read_value = {29'd0, selected_rd_ch};
                32'h44: read_value = {17'd0, selected_rd_pair};
                32'h4c: read_value = {4'd0, cap_words_cfg, 15'd0, cap_trig_cfg};
                32'h50: read_value = {20'd0, rx_h_cap_tx_word};
                32'h54: read_value = BUILD_ID;
                default: read_value = 32'd0;
            endcase
        end
    endfunction

    wire [31:0] tx_length_merged = apply_wstrb({19'd0, tx_h_length_words}, wdata_q, wstrb_q);
    wire [31:0] tx_mask_merged = apply_wstrb({24'd0, tx_h_mask}, wdata_q, wstrb_q);
    wire [31:0] tx_wr_ch_merged = apply_wstrb({29'd0, selected_wr_ch}, wdata_q, wstrb_q);
    wire [31:0] cap_rd_ch_merged = apply_wstrb({29'd0, selected_rd_ch}, wdata_q, wstrb_q);
    wire [31:0] cap_rd_ptr_merged = apply_wstrb({17'd0, selected_rd_pair}, wdata_q, wstrb_q);
    wire [31:0] cap_ctrl_merged = apply_wstrb({4'd0, cap_words_cfg, 15'd0, cap_trig_cfg}, wdata_q, wstrb_q);

    wire start_counts_ok =
        ((tx_h_mask[0] == 1'b0) || (written_samples[0] >= (tx_h_length_words * 18'd32))) &&
        ((tx_h_mask[1] == 1'b0) || (written_samples[1] >= (tx_h_length_words * 18'd32))) &&
        ((tx_h_mask[2] == 1'b0) || (written_samples[2] >= (tx_h_length_words * 18'd32))) &&
        ((tx_h_mask[3] == 1'b0) || (written_samples[3] >= (tx_h_length_words * 18'd32))) &&
        ((tx_h_mask[4] == 1'b0) || (written_samples[4] >= (tx_h_length_words * 18'd32))) &&
        ((tx_h_mask[5] == 1'b0) || (written_samples[5] >= (tx_h_length_words * 18'd32))) &&
        ((tx_h_mask[6] == 1'b0) || (written_samples[6] >= (tx_h_length_words * 18'd32))) &&
        ((tx_h_mask[7] == 1'b0) || (written_samples[7] >= (tx_h_length_words * 18'd32)));

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            aw_hold <= 1'b0; w_hold <= 1'b0; ar_hold <= 1'b0;
            awaddr_q <= 32'd0; wdata_q <= 32'd0; wstrb_q <= 4'd0; araddr_q <= 32'd0;
            state <= ST_IDLE; s_bresp <= AXI_OK; s_bvalid <= 1'b0;
            s_rdata <= 32'd0; s_rresp <= AXI_OK; s_rvalid <= 1'b0;
            selected_wr_ch <= 3'd0; selected_rd_ch <= 3'd0; selected_rd_pair <= 15'd0;
            cap_words_cfg <= 12'd1; cap_trig_cfg <= 1'b0; last_cmd_result <= 2'd0; rd_req_issued <= 1'b0; rd_wait <= 4'd0;
            tx_h_length_words <= 13'd1; tx_h_mask <= 8'd0; tx_h_wr_ch <= 3'd0;
            tx_h_wr_rewind <= 1'b0; tx_h_wr_data <= 32'd0; tx_h_wr_valid <= 1'b0;
            tx_h_crc_start <= 1'b0; tx_h_crc_ch <= 3'd0; tx_h_start <= 1'b0;
            tx_h_stop <= 1'b0; tx_h_clear_fault <= 1'b0;
            rx_h_arm <= 1'b0; rx_h_abort <= 1'b0; rx_h_trig_mode <= 1'b0; rx_h_cap_words <= 12'd1;
            rx_h_rd_ch <= 3'd0; rx_h_rd_pair <= 15'd0; rx_h_rd_req <= 1'b0;
            for (i = 0; i < 8; i = i + 1) written_samples[i] <= 18'd0;
        end else begin
            tx_h_wr_rewind <= 1'b0; tx_h_crc_start <= 1'b0; tx_h_start <= 1'b0;
            tx_h_stop <= 1'b0; tx_h_clear_fault <= 1'b0; rx_h_arm <= 1'b0; rx_h_abort <= 1'b0; rx_h_rd_req <= 1'b0;
            if (aw_fire) begin aw_hold <= 1'b1; awaddr_q <= s_awaddr; end
            if (w_fire) begin w_hold <= 1'b1; wdata_q <= s_wdata; wstrb_q <= s_wstrb; end
            if (ar_fire) begin ar_hold <= 1'b1; araddr_q <= s_araddr; end
            if (s_bvalid && s_bready) s_bvalid <= 1'b0;
            if (s_rvalid && s_rready) s_rvalid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (write_pair) begin aw_hold <= 1'b0; w_hold <= 1'b0; state <= ST_WRITE; end
                    else if (read_pending) begin ar_hold <= 1'b0; state <= ST_READ; rd_req_issued <= 1'b0; end
                end
                ST_WRITE: begin
                    case (awaddr_q - BASE_ADDR)
                        32'h08: begin
                            if (wdata_q == 32'd1) begin tx_h_stop <= 1'b1; last_cmd_result <= 2'd0; s_bresp <= AXI_OK;
                            end else if (wdata_q == 32'd2 && ps_ready && !tx_h_running && !tx_h_locked && tx_h_mask != 0 && tx_h_faults == 0 && tx_h_length_words != 0 && tx_h_length_words <= TX_MAX_WORDS && start_counts_ok) begin
                                tx_h_start <= 1'b1; last_cmd_result <= 2'd0; s_bresp <= AXI_OK;
                            end else if (wdata_q == 32'd4 && !tx_h_running) begin tx_h_clear_fault <= 1'b1; last_cmd_result <= 2'd0; s_bresp <= AXI_OK;
                            end else if (wdata_q == 32'd8 && !rx_h_busy && !rx_h_armed && cap_words_cfg != 0 && cap_words_cfg <= CAP_MAX_WORDS) begin
                                rx_h_trig_mode <= cap_trig_cfg; rx_h_cap_words <= cap_words_cfg; rx_h_arm <= 1'b1; last_cmd_result <= 2'd0; s_bresp <= AXI_OK;
                            end else if (wdata_q == 32'd16 && !tx_h_locked && !tx_h_crc_busy) begin tx_h_crc_ch <= selected_wr_ch; tx_h_crc_start <= 1'b1; last_cmd_result <= 2'd0; s_bresp <= AXI_OK;
                            end else if (wdata_q == 32'd32) begin rx_h_abort <= 1'b1; last_cmd_result <= 2'd0; s_bresp <= AXI_OK;
                            end else begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; end
                            s_bvalid <= 1'b1; state <= ST_IDLE;
                        end
                        32'h0c: begin
                            if (tx_h_running || tx_h_locked || tx_length_merged[31:13] != 0 || tx_length_merged[12:0] == 0 || tx_length_merged[12:0] > TX_MAX_WORDS) begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; end
                            else begin tx_h_length_words <= tx_length_merged[12:0]; last_cmd_result <= 2'd0; s_bresp <= AXI_OK; end
                            s_bvalid <= 1'b1; state <= ST_IDLE;
                        end
                        32'h10: begin
                            if (tx_h_running || tx_h_locked || tx_mask_merged[31:8] != 0) begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; end
                            else begin tx_h_mask <= tx_mask_merged[7:0]; last_cmd_result <= 2'd0; s_bresp <= AXI_OK; end
                            s_bvalid <= 1'b1; state <= ST_IDLE;
                        end
                        32'h30: begin
                            if (tx_h_running || tx_h_locked || tx_wr_ch_merged[31:3] != 0 || tx_wr_ch_merged[2:0] > 3'd7) begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; end
                            else begin selected_wr_ch <= tx_wr_ch_merged[2:0]; tx_h_wr_ch <= tx_wr_ch_merged[2:0]; tx_h_wr_rewind <= 1'b1; written_samples[tx_wr_ch_merged[2:0]] <= 18'd0; last_cmd_result <= 2'd0; s_bresp <= AXI_OK; end
                            s_bvalid <= 1'b1; state <= ST_IDLE;
                        end
                        32'h38: begin
                            if (tx_h_running || tx_h_locked) begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; s_bvalid <= 1'b1; state <= ST_IDLE; end
                            else begin tx_h_wr_ch <= selected_wr_ch; tx_h_wr_data <= wdata_q; tx_h_wr_valid <= 1'b1; state <= ST_WR_DATA; end
                        end
                        32'h40: begin
                            if (rx_h_busy || rx_h_armed || cap_rd_ch_merged[31:3] != 0 || cap_rd_ch_merged[2:0] > 3'd7) begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; end
                            // doc/01 §5: selecting a channel also rewinds the read pointer (E5 found it did not).
                            else begin selected_rd_ch <= cap_rd_ch_merged[2:0]; rx_h_rd_ch <= cap_rd_ch_merged[2:0]; selected_rd_pair <= 15'd0; rx_h_rd_pair <= 15'd0; last_cmd_result <= 2'd0; s_bresp <= AXI_OK; end
                            s_bvalid <= 1'b1; state <= ST_IDLE;
                        end
                        32'h44: begin
                            if (rx_h_busy || rx_h_armed || cap_rd_ptr_merged[31:15] != 0 || cap_rd_ptr_merged[14:0] >= CAP_MAX_PAIR) begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; end
                            else begin selected_rd_pair <= cap_rd_ptr_merged[14:0]; rx_h_rd_pair <= cap_rd_ptr_merged[14:0]; last_cmd_result <= 2'd0; s_bresp <= AXI_OK; end
                            s_bvalid <= 1'b1; state <= ST_IDLE;
                        end
                        32'h4c: begin
                            if (rx_h_busy || rx_h_armed || cap_ctrl_merged[31:28] != 0 || cap_ctrl_merged[15:1] != 0 || cap_ctrl_merged[27:16] == 0 || cap_ctrl_merged[27:16] > CAP_MAX_WORDS) begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; end
                            else begin cap_trig_cfg <= cap_ctrl_merged[0]; cap_words_cfg <= cap_ctrl_merged[27:16]; last_cmd_result <= 2'd0; s_bresp <= AXI_OK; end
                            s_bvalid <= 1'b1; state <= ST_IDLE;
                        end
                        default: begin last_cmd_result <= 2'd1; s_bresp <= AXI_SLVERR; s_bvalid <= 1'b1; state <= ST_IDLE; end
                    endcase
                end
                ST_WR_DATA: begin
                    // Valid and data remain asserted until the FIFO accepts the word.
                    if (tx_h_wr_valid && tx_h_wr_ready) begin
                        tx_h_wr_valid <= 1'b0; written_samples[selected_wr_ch] <= written_samples[selected_wr_ch] + 18'd2;
                        last_cmd_result <= 2'd0; s_bresp <= AXI_OK; s_bvalid <= 1'b1; state <= ST_IDLE;
                    end
                end
                ST_READ: begin
                    if ((araddr_q - BASE_ADDR) == 32'h48) begin
                        // A pointer past the buffer is rejected here: awg_rx ignores such a request, and
                        // waiting for its data locked the AXI bus on the board (E5).
                        if (rx_h_busy || rx_h_armed || selected_rd_pair >= CAP_MAX_PAIR) begin s_rdata <= 32'd0; s_rresp <= AXI_SLVERR; s_rvalid <= 1'b1; state <= ST_IDLE; end
                        else if (!rd_req_issued) begin rx_h_rd_ch <= selected_rd_ch; rx_h_rd_pair <= selected_rd_pair; rx_h_rd_req <= 1'b1; rd_req_issued <= 1'b1; rd_wait <= 4'd0; state <= ST_RD_DATA; end
                    end else begin
                        case (araddr_q - BASE_ADDR)
                            32'h00,32'h04,32'h0c,32'h10,32'h14,32'h18,32'h1c,32'h20,32'h24,32'h28,32'h2c,32'h30,32'h34,32'h3c,32'h40,32'h44,32'h4c,32'h50,32'h54: begin s_rdata <= read_value(araddr_q); s_rresp <= AXI_OK; end
                            default: begin s_rdata <= 32'd0; s_rresp <= AXI_SLVERR; end
                        endcase
                        s_rvalid <= 1'b1; state <= ST_IDLE;
                    end
                end
                ST_RD_DATA: begin
                    if (rx_h_rd_valid) begin s_rdata <= rx_h_rd_data; s_rresp <= AXI_OK; s_rvalid <= 1'b1; rd_req_issued <= 1'b0; selected_rd_pair <= selected_rd_pair + 1'b1; rx_h_rd_pair <= selected_rd_pair + 1'b1; state <= ST_IDLE; end
                    // awg_rx answers within 2 cycles; never wait forever for a dropped request.
                    else if (rd_wait == 4'd15) begin s_rdata <= 32'd0; s_rresp <= AXI_SLVERR; s_rvalid <= 1'b1; rd_req_issued <= 1'b0; last_cmd_result <= 2'd2; state <= ST_IDLE; end
                    else rd_wait <= rd_wait + 4'd1;
                end
                default: begin state <= ST_IDLE; tx_h_wr_valid <= 1'b0; end
            endcase
        end
    end
endmodule

`default_nettype wire
