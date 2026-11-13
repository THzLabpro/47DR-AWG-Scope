`default_nettype none
`timescale 1ns/1ps

// =============================================================
// 模組：awg_tx
// 功能：8 通道 14-bit 緊密打包 TX 播放器；每通道 7 個 72-bit URAM
// 時鐘/復位：host_clk、tx_clk、dac_clk，各自同步低有效復位
// 輸入：host 寫入/控制介面、ps_config_done、RFDC ready
// 輸出：RFDC 8×256-bit AXIS、起播事件、播放字索引與狀態
// 關鍵參數：32 個 14-bit 樣點/URAM 字，4096 字/通道
// =============================================================
//
// 設計備註：
// 1. host -> tx 的資料通道是 35-bit、64 深度非同步 XPM FIFO。
// 2. URAM 陣列明確宣告為 8×7 個 72×4096 記憶體，綜合時要求推論為 56 個 URAM。
// 3. tx_clk 與 dac_clk 為同源 ÷2；dac_clk 僅做相位選擇與輸出暫存，不使用非同步 FIFO。
// 4. 寫入資料的兩個 int16 取 bits [15:2] 與 [31:18]，再以 14-bit 時間順序打包。

module awg_tx #(
    parameter integer URAM_ADDR_BITS = 12
) (
    input  wire                         host_clk,
    input  wire                         host_resetn,
    input  wire                         tx_clk,
    input  wire                         tx_resetn,
    input  wire                         dac_clk,
    input  wire                         dac_resetn,
    input  wire                         ps_config_done,

    input  wire [2:0]                   h_wr_ch,
    input  wire                         h_wr_rewind,
    input  wire [31:0]                  h_wr_data,
    input  wire                         h_wr_valid,
    output wire                         h_wr_ready,
    output wire [17:0]                  h_wr_ptr,

    input  wire                         h_crc_start,
    input  wire [2:0]                   h_crc_ch,
    output wire                         h_crc_busy,
    output wire [31:0]                  h_crc_value,

    input  wire                         h_start,
    input  wire                         h_stop,
    input  wire                         h_clear_fault,
    input  wire [12:0]                  h_length_words,
    input  wire [7:0]                   h_mask,
    output wire                         h_running,
    output wire                         h_started,
    output wire [7:0]                   h_faults,
    output wire [31:0]                  h_wrap_count,
    output wire                         h_locked,
    output wire                         h_start_rejected,

    output wire [8*256-1:0]             dac_tdata,
    output wire [7:0]                   dac_tvalid,
    input  wire [7:0]                   dac_tready,
    output wire                         tx_start_event,
    output wire                         tx_start_event_toggle,
    output wire [11:0]                  tx_play_word
);

    localparam integer CHANNELS = 8;
    localparam integer URAM_WORD_BITS = 448;
    localparam integer URAM_BLOCK_BITS = 72;
    localparam integer DAC_WORD_BITS = 512;
    localparam integer URAM_WORDS = (1 << URAM_ADDR_BITS);
    localparam integer SAMPLE_BITS = 14;
    localparam integer SAMPLES_PER_WORD = 32;
    localparam integer FIFO_ADDR_BITS = 6;
    localparam integer FIFO_WIDTH = 35;
    localparam integer FIFO_DEPTH = (1 << FIFO_ADDR_BITS);
    localparam [12:0] MAX_LENGTH_WORDS = 13'd4096;
    localparam [17:0] MAX_SAMPLES = 18'd131072;

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_PLAY = 2'd1;
    localparam [1:0] ST_CRC_READ = 2'd2;
    localparam [1:0] ST_CRC_WAIT = 2'd3;
    localparam [2:0] ST_CRC_CAPTURE = 3'd4;
    localparam [2:0] ST_CRC_BYTES = 3'd5;
    localparam [2:0] ST_CRC_WAIT_2 = 3'd6;
    localparam [2:0] ST_CRC_WAIT_3 = 3'd7;

    integer ch;
    integer blk;

    // ------------------------------------------------------------------
    // host_clk: command mailboxes and write-side FIFO
    // ------------------------------------------------------------------
    reg [17:0] host_accepted_samples [0:CHANNELS-1];
    reg [2:0]  rewind_ch_host;
    reg        rewind_toggle_host;
    reg        start_toggle_host;
    reg        stop_toggle_host;
    reg        clear_toggle_host;
    reg        crc_toggle_host;
    reg [2:0]  crc_ch_host;
    reg [12:0] length_hold_host;
    reg [7:0]  mask_hold_host;

    wire wr_fifo_full;
    wire wr_fifo_wr_rst_busy;
    wire wr_fifo_write;
    wire fifo_empty;
    wire [FIFO_WIDTH-1:0] fifo_dout;
    wire fifo_data_valid_ip;
    wire fifo_rd_en;
    wire tx_reset_host;
    reg fifo_reset_host;
    wire fifo_reset = fifo_reset_host;
    assign h_wr_ready = !wr_fifo_full && !wr_fifo_wr_rst_busy &&
                        !fifo_reset_host && host_resetn && !h_locked &&
                        (host_accepted_samples[h_wr_ch] < MAX_SAMPLES);
    assign wr_fifo_write = h_wr_valid && h_wr_ready;

    xpm_cdc_async_rst #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .RST_ACTIVE_HIGH(1)
    ) tx_reset_to_host_cdc (
        .src_arst(!tx_resetn),
        .dest_clk(host_clk),
        .dest_arst(tx_reset_host)
    );

    always @(posedge host_clk) begin
        if (!host_resetn)
            fifo_reset_host <= 1'b1;
        else
            fifo_reset_host <= tx_reset_host;
    end

    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2),
        .DOUT_RESET_VALUE("0"),
        .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_READ_LATENCY(1),
        .FIFO_WRITE_DEPTH(FIFO_DEPTH),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10),
        .PROG_FULL_THRESH(10),
        .RD_DATA_COUNT_WIDTH(FIFO_ADDR_BITS+1),
        .READ_DATA_WIDTH(FIFO_WIDTH),
        .READ_MODE("std"),
        .RELATED_CLOCKS(0),
        .SIM_ASSERT_CHK(0),
        .USE_ADV_FEATURES("0707"),
        .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(FIFO_WIDTH),
        .WR_DATA_COUNT_WIDTH(FIFO_ADDR_BITS+1)
    ) wr_fifo_i (
        .rst(fifo_reset),
        .wr_clk(host_clk), .wr_en(wr_fifo_write), .din({h_wr_ch, h_wr_data}),
        .full(wr_fifo_full), .overflow(), .wr_ack(), .wr_data_count(),
        .almost_full(), .prog_full(), .wr_rst_busy(wr_fifo_wr_rst_busy),
        .rd_clk(tx_clk), .rd_en(fifo_rd_en), .dout(fifo_dout),
        .empty(fifo_empty), .data_valid(fifo_data_valid_ip), .underflow(),
        .rd_data_count(), .almost_empty(), .prog_empty(), .rd_rst_busy(),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .sbiterr(), .dbiterr()
    );

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            rewind_ch_host    <= '0;
            rewind_toggle_host <= 1'b0;
            start_toggle_host <= 1'b0;
            stop_toggle_host  <= 1'b0;
            clear_toggle_host <= 1'b0;
            crc_toggle_host   <= 1'b0;
            crc_ch_host       <= '0;
            length_hold_host  <= 13'd1;
            mask_hold_host    <= 8'h00;
            for (ch = 0; ch < CHANNELS; ch = ch + 1)
                host_accepted_samples[ch] <= '0;
        end else begin
            if (h_wr_rewind && !h_locked) begin
                rewind_ch_host     <= h_wr_ch;
                rewind_toggle_host <= ~rewind_toggle_host;
                host_accepted_samples[h_wr_ch] <= '0;
            end

            if (wr_fifo_write) begin
                host_accepted_samples[h_wr_ch] <=
                    host_accepted_samples[h_wr_ch] + 18'd2;
            end

            if (!h_locked) begin
                // Keep the bundled configuration mailbox stable before the
                // command toggle crosses into tx_clk.
                length_hold_host  <= h_length_words;
                mask_hold_host    <= h_mask;
            end
            if (h_start && !h_locked) begin
                start_toggle_host <= ~start_toggle_host;
            end
            if (h_stop)
                stop_toggle_host <= ~stop_toggle_host;
            if (h_clear_fault)
                clear_toggle_host <= ~clear_toggle_host;
            if (h_crc_start && !h_locked) begin
                crc_ch_host     <= h_crc_ch;
                crc_toggle_host <= ~crc_toggle_host;
            end
        end
    end

    // ------------------------------------------------------------------
    // tx_clk: command synchronizers, FIFO read side, URAM and playback
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [1:0] rewind_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] start_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] stop_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] clear_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] crc_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ps_ready_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] rewind_ch_t1;
    (* ASYNC_REG = "TRUE" *) reg [2:0] rewind_ch_t2;
    (* ASYNC_REG = "TRUE" *) reg [2:0] crc_ch_t1;
    (* ASYNC_REG = "TRUE" *) reg [2:0] crc_ch_t2;
    (* ASYNC_REG = "TRUE" *) reg [12:0] length_t1;
    (* ASYNC_REG = "TRUE" *) reg [12:0] length_t2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] mask_t1;
    (* ASYNC_REG = "TRUE" *) reg [7:0] mask_t2;

    wire fifo_empty_t = fifo_empty;
    reg [FIFO_WIDTH-1:0] fifo_data_stage;
    reg fifo_data_valid;
    reg fifo_read_pending;

    reg [2:0] state;
    reg crc_busy_tx;
    reg [17:0] write_samples [0:CHANNELS-1];
    reg [12:0] write_words_gray_tx [0:CHANNELS-1];
    reg [31:0] wrap_gray_tx;
    reg        crc_done_toggle_tx;
    reg [11:0] write_word_idx [0:CHANNELS-1];
    reg [4:0]  pack_count;
    reg [URAM_WORD_BITS-1:0] pack_shift;
    reg [2:0]  pack_channel;
    reg        pack_channel_valid;

    // 8 channels × 7 independent 72×4096 URAM288 blocks.
    reg [CHANNELS-1:0] uram_wr_en [0:6];
    reg [11:0] uram_wr_addr [0:CHANNELS-1][0:6];
    reg [URAM_BLOCK_BITS-1:0] uram_wr_data [0:CHANNELS-1][0:6];
    wire [URAM_BLOCK_BITS-1:0] uram_rd_data [0:CHANNELS-1][0:6];
    reg uram_rd_en;
    reg [11:0] uram_rd_addr;

    reg [URAM_BLOCK_BITS-1:0] uram_rd_stage0 [0:CHANNELS-1][0:6];
    reg [URAM_BLOCK_BITS-1:0] uram_rd_stage1 [0:CHANNELS-1][0:6];
    reg [11:0] rd_addr_stage0;
    reg [11:0] rd_addr_stage1;
    reg [11:0] rd_addr_stage2;
    reg [11:0] rd_addr_stage3;
    reg [11:0] rd_addr_stage4;
    reg [11:0] rd_addr_stage5;
    reg        rd_valid_stage0;
    reg        rd_valid_stage1;
    reg        rd_valid_stage2;
    reg        rd_valid_stage3;
    reg        rd_valid_stage4;
    reg        rd_valid_stage5;
    reg [11:0] play_addr_issue;
    reg [11:0] play_word_stage;
    reg [11:0] play_word_reg;
    reg [DAC_WORD_BITS-1:0] tx_word_reg [0:CHANNELS-1];
    reg [CHANNELS-1:0] tx_word_valid;
    reg [CHANNELS-1:0] active_mask_tx;
    reg [12:0] length_words_tx;
    reg [31:0] wrap_count_tx;
    reg [7:0] fault_tx;
    reg        started_tx;
    reg        start_pending_tx;
    reg        start_rejected_tx;
    reg        rewind_seen_tx;
    reg        rewind_pending_tx;
    reg        start_seen_tx;
    reg        stop_seen_tx;
    reg        clear_seen_tx;
    reg        crc_seen_tx;
    reg [2:0]  start_rewind_channel;

    (* ASYNC_REG = "TRUE" *) reg [7:0] dac_ready_t1;
    (* ASYNC_REG = "TRUE" *) reg [7:0] dac_ready_t2;
    wire dac_ready_all_tx = (&(dac_ready_t2 | ~active_mask_tx));
    wire ps_ready_tx = ps_ready_sync[1];

    // CRC engine state
    reg [2:0]  crc_channel_tx;
    reg [12:0] crc_length_tx;
    reg [11:0] crc_word_index_tx;
    reg [5:0]  crc_byte_index_tx;
    reg [31:0] crc_accum_tx;
    reg [31:0] crc_value_tx;
    reg [URAM_WORD_BITS-1:0] crc_word_buf;
    reg [31:0] crc_byte_count_tx;

    genvar uram_ch;
    genvar uram_blk;
    generate
        for (uram_ch = 0; uram_ch < CHANNELS; uram_ch = uram_ch + 1) begin: g_uram_channel
            for (uram_blk = 0; uram_blk < 7; uram_blk = uram_blk + 1) begin: g_uram_block
                awg_tx_uram_block #(
                    .ADDR_BITS(URAM_ADDR_BITS),
                    .DATA_BITS(URAM_BLOCK_BITS)
                ) uram_i (
                    .clk(tx_clk),
                    .wr_en(uram_wr_en[uram_blk][uram_ch]),
                    .wr_addr(uram_wr_addr[uram_ch][uram_blk]),
                    .wr_data(uram_wr_data[uram_ch][uram_blk]),
                    .rd_en(uram_rd_en),
                    .rd_addr(uram_rd_addr),
                    .rd_data(uram_rd_data[uram_ch][uram_blk])
                );
            end
        end
    endgenerate

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data_in;
        integer k;
        reg [31:0] c;
        begin
            c = crc_in;
            for (k = 0; k < 8; k = k + 1) begin
                if (c[0] ^ data_in[k])
                    c = (c >> 1) ^ 32'hEDB88320;
                else
                    c = c >> 1;
            end
            crc32_byte = c;
        end
    endfunction

    function [7:0] crc_data_byte;
        input [URAM_WORD_BITS-1:0] word_in;
        input [5:0] byte_index_in;
        reg [URAM_WORD_BITS-1:0] shifted_word;
        reg [13:0] sample14;
        reg [15:0] sample16;
        begin
            shifted_word = word_in >> ((byte_index_in >> 1) * SAMPLE_BITS);
            sample14 = shifted_word[13:0];
            sample16 = {sample14, 2'b00};
            crc_data_byte = byte_index_in[0] ? sample16[15:8] : sample16[7:0];
        end
    endfunction

    function [DAC_WORD_BITS-1:0] expand_uram_word;
        input [URAM_WORD_BITS-1:0] packed_word;
        integer n;
        reg [URAM_WORD_BITS-1:0] shifted_word;
        reg [13:0] sample14;
        begin
            expand_uram_word = '0;
            for (n = 0; n < SAMPLES_PER_WORD; n = n + 1) begin
                shifted_word = packed_word >> (n * SAMPLE_BITS);
                sample14 = shifted_word[13:0];
                expand_uram_word[n*16 +: 16] = {sample14, 2'b00};
            end
        end
    endfunction

    wire command_start_event = start_sync[1] ^ start_seen_tx;
    wire command_stop_event  = stop_sync[1]  ^ stop_seen_tx;
    wire command_clear_event = clear_sync[1] ^ clear_seen_tx;
    wire command_crc_event   = crc_sync[1]   ^ crc_seen_tx;
    wire command_rewind_event = rewind_sync[1] ^ rewind_seen_tx;

    wire fifo_read_enable = !fifo_empty_t && (state == ST_IDLE) &&
                            !rewind_pending_tx && !command_rewind_event;
    reg [URAM_WORD_BITS-1:0] pack_tmp;
    reg [URAM_BLOCK_BITS*7-1:0] pack_tmp_uram;
    reg [13:0] wr_sample0;
    reg [13:0] wr_sample1;
    reg [2:0] fifo_channel;
    reg pack_restart;
    reg [31:0] crc_next_value;

    assign fifo_rd_en = fifo_read_enable;

    always @(posedge tx_clk) begin
        if (!tx_resetn) begin
            rewind_sync      <= '0;
            start_sync       <= '0;
            stop_sync        <= '0;
            clear_sync       <= '0;
            crc_sync         <= '0;
            ps_ready_sync    <= '0;
            rewind_ch_t1     <= '0;
            rewind_ch_t2     <= '0;
            crc_ch_t1        <= '0;
            crc_ch_t2        <= '0;
            length_t1        <= 13'd1;
            length_t2        <= 13'd1;
            mask_t1          <= '0;
            mask_t2          <= '0;
            dac_ready_t1     <= 8'h00;
            dac_ready_t2     <= 8'h00;
            fifo_data_valid  <= 1'b0;
            fifo_read_pending <= 1'b0;
            state            <= ST_IDLE;
            rd_addr_stage0  <= '0;
            rd_addr_stage1  <= '0;
            rd_addr_stage2  <= '0;
            rd_addr_stage3  <= '0;
            rd_addr_stage4  <= '0;
            rd_addr_stage5  <= '0;
            rd_valid_stage0 <= 1'b0;
            rd_valid_stage1 <= 1'b0;
            rd_valid_stage2 <= 1'b0;
            rd_valid_stage3 <= 1'b0;
            rd_valid_stage4 <= 1'b0;
            rd_valid_stage5 <= 1'b0;
            play_addr_issue <= '0;
            play_word_stage <= '0;
            play_word_reg   <= '0;
            tx_word_valid   <= '0;
            active_mask_tx  <= '0;
            length_words_tx <= 13'd1;
            wrap_count_tx   <= '0;
            wrap_gray_tx    <= '0;
            crc_done_toggle_tx <= 1'b0;
            crc_busy_tx <= 1'b0;
            fault_tx        <= '0;
            started_tx      <= 1'b0;
            start_pending_tx <= 1'b0;
            start_rejected_tx <= 1'b0;
            rewind_seen_tx  <= 1'b0;
            rewind_pending_tx <= 1'b0;
            start_seen_tx   <= 1'b0;
            stop_seen_tx    <= 1'b0;
            clear_seen_tx   <= 1'b0;
            crc_seen_tx     <= 1'b0;
            start_rewind_channel <= '0;
            crc_channel_tx  <= '0;
            crc_length_tx   <= 13'd1;
            crc_word_index_tx <= '0;
            crc_byte_index_tx <= '0;
            crc_accum_tx    <= 32'hFFFFFFFF;
            crc_value_tx    <= '0;
            crc_word_buf    <= '0;
            crc_byte_count_tx <= '0;
            uram_rd_en      <= 1'b0;
            uram_rd_addr    <= '0;
            for (blk = 0; blk < 7; blk = blk + 1)
                uram_wr_en[blk] <= '0;
            for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                write_samples[ch] <= '0;
                write_words_gray_tx[ch] <= '0;
                write_word_idx[ch] <= '0;
                for (blk = 0; blk < 7; blk = blk + 1) begin
                    uram_wr_addr[ch][blk] <= '0;
                end
            end
            pack_count <= '0;
            pack_channel <= '0;
            pack_channel_valid <= 1'b0;
        end else begin
            crc_busy_tx <= (state == ST_CRC_READ) ||
                           (state == ST_CRC_WAIT) ||
                           (state == ST_CRC_WAIT_2) ||
                           (state == ST_CRC_WAIT_3) ||
                           (state == ST_CRC_CAPTURE) ||
                           (state == ST_CRC_BYTES);
            // CDC synchronizers.  Bundled command buses are held stable by host_clk
            // until the corresponding toggle is observed here.
            rewind_sync     <= {rewind_sync[0], rewind_toggle_host};
            start_sync      <= {start_sync[0], start_toggle_host};
            stop_sync       <= {stop_sync[0], stop_toggle_host};
            clear_sync      <= {clear_sync[0], clear_toggle_host};
            crc_sync        <= {crc_sync[0], crc_toggle_host};
            ps_ready_sync   <= {ps_ready_sync[0], ps_config_done};
            rewind_ch_t1    <= rewind_ch_host;
            rewind_ch_t2    <= rewind_ch_t1;
            crc_ch_t1       <= crc_ch_host;
            crc_ch_t2       <= crc_ch_t1;
            length_t1       <= length_hold_host;
            length_t2       <= length_t1;
            mask_t1         <= mask_hold_host;
            mask_t2         <= mask_t1;
            dac_ready_t1    <= dac_tready;
            dac_ready_t2    <= dac_ready_t1;
            wrap_gray_tx <= (wrap_count_tx >> 1) ^ wrap_count_tx;
            for (ch = 0; ch < CHANNELS; ch = ch + 1)
                write_words_gray_tx[ch] <=
                    (write_samples[ch][17:5] >> 1) ^ write_samples[ch][17:5];
            uram_rd_en      <= 1'b0;
            fifo_read_pending <= fifo_read_enable;
            fifo_data_valid <= fifo_read_pending;
            if (fifo_read_pending) begin
                fifo_data_stage <= fifo_dout;
            end
            for (blk = 0; blk < 7; blk = blk + 1)
                uram_wr_en[blk] <= '0;

            // Command edge bookkeeping and mailbox handling.
            if (command_rewind_event) begin
                rewind_seen_tx <= rewind_sync[1];
                rewind_pending_tx <= 1'b1;
                fifo_data_valid <= 1'b0;
            end
            if (rewind_pending_tx) begin
                rewind_pending_tx <= 1'b0;
                write_samples[rewind_ch_t2] <= '0;
                write_word_idx[rewind_ch_t2] <= '0;
                if (pack_channel_valid && (pack_channel == rewind_ch_t2)) begin
                    pack_count <= '0;
                    pack_channel_valid <= 1'b0;
                end
            end
            if (command_start_event) begin
                start_seen_tx <= start_sync[1];
                start_pending_tx <= 1'b1;
                start_rewind_channel <= mask_t2[2:0];
            end
            if (command_stop_event) begin
                stop_seen_tx <= stop_sync[1];
                if (state == ST_PLAY) begin
                    state <= ST_IDLE;
                    active_mask_tx <= '0;
                    tx_word_valid <= '0;
                    started_tx <= 1'b0;
                end
            end
            if (command_clear_event) begin
                clear_seen_tx <= clear_sync[1];
                if (state == ST_IDLE)
                    fault_tx <= '0;
            end

            // Consume only the registered FIFO output; this is the CDC data boundary.
            if (fifo_data_valid && !command_rewind_event &&
                !rewind_pending_tx && (state == ST_IDLE)) begin
                fifo_channel = fifo_data_stage[34:32];
                wr_sample0 = fifo_data_stage[15:2];
                wr_sample1 = fifo_data_stage[31:18];
                pack_restart = !pack_channel_valid || (pack_channel != fifo_channel);
                if (pack_restart)
                    pack_tmp = {wr_sample1, wr_sample0, {420{1'b0}}};
                else
                    pack_tmp = {wr_sample1, wr_sample0, pack_shift[URAM_WORD_BITS-1:28]};

                pack_shift <= pack_tmp;
                pack_channel <= fifo_channel;
                pack_channel_valid <= 1'b1;
                if (pack_restart) begin
                    pack_count <= 5'd1;
                end else if (pack_count == 5'd15) begin
                    pack_tmp_uram = '0;
                    pack_tmp_uram[URAM_WORD_BITS-1:0] = pack_tmp;
                    for (blk = 0; blk < 7; blk = blk + 1) begin
                        uram_wr_en[blk][fifo_channel] <= 1'b1;
                        uram_wr_addr[fifo_channel][blk] <= write_word_idx[fifo_channel];
                        uram_wr_data[fifo_channel][blk] <=
                            pack_tmp_uram[blk*URAM_BLOCK_BITS +: URAM_BLOCK_BITS];
                    end
                    pack_count <= '0;
                    write_word_idx[fifo_channel] <= write_word_idx[fifo_channel] + 1'b1;
                    write_samples[fifo_channel] <= write_samples[fifo_channel] + 18'd32;
                end else begin
                    pack_count <= pack_count + 1'b1;
                end
            end

            // Start validation and playback control.
            if (start_pending_tx && fifo_empty_t && !fifo_data_valid &&
                (state == ST_IDLE)) begin
                start_pending_tx <= 1'b0;
                start_rejected_tx <= 1'b0;
                if (!ps_ready_tx || (mask_t2 == 8'h00) || (length_t2 == 13'd0) ||
                    (length_t2 > MAX_LENGTH_WORDS) || (fault_tx != 8'h00)) begin
                    start_rejected_tx <= 1'b1;
                end else begin
                    start_rejected_tx <= 1'b0;
                    state            <= ST_PLAY;
                    active_mask_tx   <= mask_t2;
                    length_words_tx  <= length_t2;
                    play_addr_issue  <= 12'd0;
                    rd_addr_stage0   <= 12'd0;
                    rd_addr_stage1   <= 12'd0;
                    rd_addr_stage2   <= 12'd0;
                    rd_addr_stage3   <= 12'd0;
                    rd_addr_stage4   <= 12'd0;
                    rd_addr_stage5   <= 12'd0;
                    rd_valid_stage0  <= 1'b0;
                    rd_valid_stage1  <= 1'b0;
                    rd_valid_stage2  <= 1'b0;
                    rd_valid_stage3  <= 1'b0;
                    rd_valid_stage4  <= 1'b0;
                    rd_valid_stage5  <= 1'b0;
                    tx_word_valid    <= '0;
                    started_tx       <= 1'b1;
                    wrap_count_tx    <= 32'd0;
                    for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                        if (mask_t2[ch] && (write_samples[ch] < (length_t2 * 18'd32)))
                            start_rejected_tx <= 1'b1;
                    end
                    if (|(mask_t2 & {CHANNELS{1'b1}}) &&
                        ((write_samples[0] < (length_t2 * 18'd32) && mask_t2[0]) ||
                         (write_samples[1] < (length_t2 * 18'd32) && mask_t2[1]) ||
                         (write_samples[2] < (length_t2 * 18'd32) && mask_t2[2]) ||
                         (write_samples[3] < (length_t2 * 18'd32) && mask_t2[3]) ||
                         (write_samples[4] < (length_t2 * 18'd32) && mask_t2[4]) ||
                         (write_samples[5] < (length_t2 * 18'd32) && mask_t2[5]) ||
                         (write_samples[6] < (length_t2 * 18'd32) && mask_t2[6]) ||
                         (write_samples[7] < (length_t2 * 18'd32) && mask_t2[7]))) begin
                        state          <= ST_IDLE;
                        active_mask_tx <= '0;
                        started_tx     <= 1'b0;
                        start_rejected_tx <= 1'b1;
                    end
                end
            end

            if ((state == ST_PLAY) && !dac_ready_all_tx) begin
                fault_tx      <= fault_tx | active_mask_tx;
                state         <= ST_IDLE;
                active_mask_tx <= '0;
                tx_word_valid <= '0;
                started_tx    <= 1'b0;
            end

            // URAM synchronous read pipeline: memory output register plus one
            // additional register before the expanded 16-bit AXIS word.
            if (state == ST_PLAY) begin
                uram_rd_en      <= 1'b1;
                uram_rd_addr    <= play_addr_issue;
                rd_valid_stage0 <= 1'b1;
                rd_valid_stage1 <= rd_valid_stage0;
                rd_valid_stage2 <= rd_valid_stage1;
                rd_valid_stage3 <= rd_valid_stage2;
                rd_valid_stage4 <= rd_valid_stage3;
                rd_valid_stage5 <= rd_valid_stage4;
                rd_addr_stage0  <= play_addr_issue;
                rd_addr_stage1  <= rd_addr_stage0;
                rd_addr_stage2  <= rd_addr_stage1;
                rd_addr_stage3  <= rd_addr_stage2;
                rd_addr_stage4  <= rd_addr_stage3;
                rd_addr_stage5  <= rd_addr_stage4;
                for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                    if (active_mask_tx[ch]) begin
                        for (blk = 0; blk < 7; blk = blk + 1)
                            uram_rd_stage0[ch][blk] <= uram_rd_data[ch][blk];
                        for (blk = 0; blk < 7; blk = blk + 1)
                            uram_rd_stage1[ch][blk] <= uram_rd_stage0[ch][blk];
                        tx_word_reg[ch] <= expand_uram_word({
                            uram_rd_stage1[ch][6], uram_rd_stage1[ch][5],
                            uram_rd_stage1[ch][4], uram_rd_stage1[ch][3],
                            uram_rd_stage1[ch][2], uram_rd_stage1[ch][1],
                            uram_rd_stage1[ch][0]
                        });
                    end else begin
                        tx_word_reg[ch] <= '0;
                    end
                end
                tx_word_valid <= {CHANNELS{rd_valid_stage5}} & active_mask_tx;
                if (rd_valid_stage5) begin
                    play_word_stage <= rd_addr_stage5;
                    play_word_reg   <= rd_addr_stage5;
                    if (rd_addr_stage5 == (length_words_tx - 1'b1))
                        wrap_count_tx <= wrap_count_tx + 1'b1;
                end
                if (play_addr_issue == (length_words_tx - 1'b1))
                    play_addr_issue <= 12'd0;
                else
                    play_addr_issue <= play_addr_issue + 1'b1;
            end else begin
                rd_valid_stage0 <= 1'b0;
                rd_valid_stage1 <= 1'b0;
                rd_valid_stage2 <= 1'b0;
                rd_valid_stage3 <= 1'b0;
                rd_valid_stage4 <= 1'b0;
                rd_valid_stage5 <= 1'b0;
                tx_word_valid   <= '0;
            end

            // CRC-32 is available only while stopped.  One word is read from
            // URAM, then 64 little-endian bytes are folded into the IEEE CRC.
            if (command_crc_event) begin
                crc_seen_tx <= crc_sync[1];
                if ((state == ST_IDLE) && fifo_empty_t && !fifo_data_valid &&
                    !start_pending_tx) begin
                    crc_channel_tx    <= crc_ch_t2;
                    crc_length_tx     <= length_t2;
                    crc_word_index_tx <= 12'd0;
                    crc_byte_index_tx <= 6'd0;
                    crc_accum_tx      <= 32'hFFFFFFFF;
                    crc_byte_count_tx <= 32'd0;
                    state             <= ST_CRC_READ;
                end
            end

            if (state == ST_CRC_READ) begin
                uram_rd_en   <= 1'b1;
                uram_rd_addr <= crc_word_index_tx;
                state <= ST_CRC_WAIT;
            end else if (state == ST_CRC_WAIT) begin
                uram_rd_en <= 1'b0;
                state <= ST_CRC_WAIT_2;
            end else if (state == ST_CRC_WAIT_2) begin
                state <= ST_CRC_WAIT_3;
            end else if (state == ST_CRC_WAIT_3) begin
                state <= ST_CRC_CAPTURE;
            end else if (state == ST_CRC_CAPTURE) begin
                crc_word_buf <= {
                    uram_rd_data[crc_channel_tx][6],
                    uram_rd_data[crc_channel_tx][5],
                    uram_rd_data[crc_channel_tx][4],
                    uram_rd_data[crc_channel_tx][3],
                    uram_rd_data[crc_channel_tx][2],
                    uram_rd_data[crc_channel_tx][1],
                    uram_rd_data[crc_channel_tx][0]
                };
                crc_byte_index_tx <= 6'd0;
                state <= ST_CRC_BYTES;
            end else if (state == ST_CRC_BYTES) begin
                crc_next_value = crc32_byte(crc_accum_tx,
                                             crc_data_byte(crc_word_buf, crc_byte_index_tx));
                crc_accum_tx      <= crc_next_value;
                crc_byte_count_tx <= crc_byte_count_tx + 1'b1;
                if (crc_byte_index_tx == 6'd63) begin
                    if (crc_word_index_tx == (crc_length_tx - 1'b1)) begin
                        crc_value_tx <= ~crc_next_value;
                        crc_done_toggle_tx <= ~crc_done_toggle_tx;
                        state <= ST_IDLE;
                    end else begin
                        crc_word_index_tx <= crc_word_index_tx + 1'b1;
                        state <= ST_CRC_READ;
                    end
                end else begin
                    crc_byte_index_tx <= crc_byte_index_tx + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // dac_clk: same-source 2:1 width conversion and RFDC output registers
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [7:0] active_dac_t1;
    (* ASYNC_REG = "TRUE" *) reg [7:0] active_dac_t2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] word_valid_dac_t1;
    (* ASYNC_REG = "TRUE" *) reg [7:0] word_valid_dac_t2;
    reg [CHANNELS-1:0] start_event_sent_dac;
    reg [8*256-1:0]      dac_tdata_reg;
    reg [7:0]             dac_tvalid_reg;
    reg                    tx_start_event_reg;
    reg                    tx_start_event_toggle_reg;
    // Half-word phase: a tx_clk toggle sampled in dac_clk. fh_q is registered
    // so the 512->256 select comes from a local flop (one copy per 64-bit block).
    // At tx/dac edge E0 the old toggle equals tog_q -> fh_q=1, used at E1 (low half);
    // at E1 the new toggle differs from tog_q -> fh_q=0, used at E2 (high half).
    (* DONT_TOUCH = "TRUE" *) reg [CHANNELS-1:0]   tx_phase_tog_r;
    (* DONT_TOUCH = "TRUE" *) reg [CHANNELS*4-1:0] tog_q;
    (* DONT_TOUCH = "TRUE" *) reg [CHANNELS*4-1:0] fh_q;

    genvar phase_replica;
    generate
        for (phase_replica = 0; phase_replica < CHANNELS; phase_replica = phase_replica + 1) begin : tx_phase_replica
            always @(posedge tx_clk) begin
                if (!tx_resetn)
                    tx_phase_tog_r[phase_replica] <= 1'b0;
                else
                    tx_phase_tog_r[phase_replica] <= ~tx_phase_tog_r[phase_replica];
            end
        end
        for (phase_replica = 0; phase_replica < CHANNELS*4; phase_replica = phase_replica + 1) begin : dac_phase_replica
            always @(posedge dac_clk) begin
                tog_q[phase_replica] <= tx_phase_tog_r[phase_replica/4];
                fh_q[phase_replica]  <= (tx_phase_tog_r[phase_replica/4] == tog_q[phase_replica]);
            end
        end
    endgenerate

    always @(posedge dac_clk) begin
        if (!dac_resetn) begin
            active_dac_t1       <= '0;
            active_dac_t2       <= '0;
            word_valid_dac_t1   <= '0;
            word_valid_dac_t2   <= '0;
            start_event_sent_dac <= '0;
            dac_tvalid_reg      <= '0;
            tx_start_event_reg  <= 1'b0;
            tx_start_event_toggle_reg <= 1'b0;
        end else begin
            active_dac_t1     <= active_mask_tx;
            active_dac_t2     <= active_dac_t1;
            word_valid_dac_t1 <= tx_word_valid;
            word_valid_dac_t2 <= word_valid_dac_t1;
            tx_start_event_reg <= 1'b0;

            if (active_dac_t2 == 8'h00) begin
                start_event_sent_dac <= '0;
            end

            dac_tvalid_reg <= 8'hFF;
            for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                if (active_dac_t2[ch] && word_valid_dac_t2[ch]) begin
                    for (blk = 0; blk < 4; blk = blk + 1) begin
                        if (fh_q[ch*4+blk])
                            dac_tdata_reg[ch*256+blk*64 +: 64] <=
                                tx_word_reg[ch][blk*64 +: 64];
                        else
                            dac_tdata_reg[ch*256+blk*64 +: 64] <=
                                tx_word_reg[ch][256+blk*64 +: 64];
                    end
                    if (fh_q[ch*4] && !start_event_sent_dac[ch] && dac_tready[ch]) begin
                        start_event_sent_dac[ch] <= 1'b1;
                        tx_start_event_reg <= 1'b1;
                        tx_start_event_toggle_reg <= ~tx_start_event_toggle_reg;
                    end
                end else begin
                    dac_tdata_reg[ch*256 +: 256] <= '0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // host_clk status synchronizers
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [12:0] write_words_gray_h1 [0:CHANNELS-1];
    (* ASYNC_REG = "TRUE" *) reg [12:0] write_words_gray_h2 [0:CHANNELS-1];
    (* ASYNC_REG = "TRUE" *) reg [7:0] fault_h1, fault_h2;
    (* ASYNC_REG = "TRUE" *) reg running_h1, running_h2;
    (* ASYNC_REG = "TRUE" *) reg started_h1, started_h2;
    (* ASYNC_REG = "TRUE" *) reg start_rejected_h1, start_rejected_h2;
    (* ASYNC_REG = "TRUE" *) reg [31:0] wrap_gray_h1, wrap_gray_h2;
    (* ASYNC_REG = "TRUE" *) reg crc_busy_h1, crc_busy_h2;
    (* ASYNC_REG = "TRUE" *) reg crc_done_h1, crc_done_h2;
    reg crc_done_seen_host;
    reg [31:0] crc_value_host;

    function [12:0] gray13_to_bin;
        input [12:0] gray_value;
        integer bit_index;
        begin
            gray13_to_bin[12] = gray_value[12];
            for (bit_index = 11; bit_index >= 0; bit_index = bit_index-1)
                gray13_to_bin[bit_index] =
                    gray13_to_bin[bit_index+1] ^ gray_value[bit_index];
        end
    endfunction

    function [31:0] gray32_to_bin;
        input [31:0] gray_value;
        integer bit_index;
        begin
            gray32_to_bin[31] = gray_value[31];
            for (bit_index = 30; bit_index >= 0; bit_index = bit_index-1)
                gray32_to_bin[bit_index] =
                    gray32_to_bin[bit_index+1] ^ gray_value[bit_index];
        end
    endfunction

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                write_words_gray_h1[ch] <= '0;
                write_words_gray_h2[ch] <= '0;
            end
            fault_h1 <= '0;
            fault_h2 <= '0;
            running_h1 <= 1'b0;
            running_h2 <= 1'b0;
            started_h1 <= 1'b0;
            started_h2 <= 1'b0;
            start_rejected_h1 <= 1'b0;
            start_rejected_h2 <= 1'b0;
            wrap_gray_h1 <= '0;
            wrap_gray_h2 <= '0;
            crc_busy_h1 <= 1'b0;
            crc_busy_h2 <= 1'b0;
            crc_done_h1 <= 1'b0;
            crc_done_h2 <= 1'b0;
            crc_done_seen_host <= 1'b0;
            crc_value_host <= '0;
        end else begin
            for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
                write_words_gray_h1[ch] <= write_words_gray_tx[ch];
                write_words_gray_h2[ch] <= write_words_gray_h1[ch];
            end
            fault_h1 <= fault_tx;
            fault_h2 <= fault_h1;
            running_h1 <= (state == ST_PLAY);
            running_h2 <= running_h1;
            started_h1 <= started_tx;
            started_h2 <= started_h1;
            start_rejected_h1 <= start_rejected_tx;
            start_rejected_h2 <= start_rejected_h1;
            wrap_gray_h1 <= wrap_gray_tx;
            wrap_gray_h2 <= wrap_gray_h1;
            crc_busy_h1 <= crc_busy_tx;
            crc_busy_h2 <= crc_busy_h1;
            crc_done_h1 <= crc_done_toggle_tx;
            crc_done_h2 <= crc_done_h1;
            if (crc_done_h2 != crc_done_seen_host) begin
                crc_done_seen_host <= crc_done_h2;
                crc_value_host <= crc_value_tx;
            end
        end
    end

    assign h_wr_ptr = {gray13_to_bin(write_words_gray_h2[h_wr_ch]), 5'b00000};
    assign h_crc_busy = crc_busy_h2;
    assign h_crc_value = crc_value_host;
    assign h_running = running_h2;
    assign h_started = started_h2;
    assign h_faults = fault_h2;
    assign h_wrap_count = gray32_to_bin(wrap_gray_h2);
    assign h_locked = h_running || h_crc_busy;
    assign h_start_rejected = start_rejected_h2;

    assign dac_tdata = dac_tdata_reg;
    assign dac_tvalid = dac_tvalid_reg;
    assign tx_start_event = tx_start_event_reg;
    assign tx_start_event_toggle = tx_start_event_toggle_reg;
    assign tx_play_word = play_word_reg;

endmodule

`default_nettype wire
