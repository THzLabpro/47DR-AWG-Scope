`timescale 1ns/1ps
`default_nettype none

// =============================================================
// Module: awg_rx
// Function: Capture eight RFDC channels in 24-sample, 14-bit BRAM words.
// Clocks/resets: dac_clk, tx_clk, adc_clk, rx_clk, host_clk; active-low synchronous resets.
// Inputs: 12 samples/channel/adc_clk, capture controls, and TX trigger data.
// Outputs: capture status and two MSB-aligned samples per host read request.
// Key parameters: CAPTURE_WORDS=2730 (24 samples per word).
// =============================================================
module awg_rx #(
    parameter integer CAPTURE_WORDS = 2730
) (
    input  wire                     adc_clk,
    input  wire                     adc_resetn,
    input  wire                     dac_clk,
    input  wire                     tx_clk,
    input  wire                     tx_resetn,
    input  wire                     rx_clk,
    input  wire                     rx_resetn,
    input  wire                     host_clk,
    input  wire                     host_resetn,

    input  wire                     h_arm,
    input  wire                     h_abort,
    input  wire                     h_trig_mode,
    input  wire [11:0]              h_cap_words,
    output reg                      h_busy,
    output reg                      h_armed,
    output reg                      h_done,
    output wire [16:0]              h_captured_samples,
    output wire [11:0]              h_cap_tx_word,

    input  wire [2:0]               h_rd_ch,
    input  wire [14:0]              h_rd_pair,
    input  wire                     h_rd_req,
    output reg  [31:0]              h_rd_data,
    output reg                      h_rd_valid,

    input  wire [8*192-1:0]         adc_tdata,
    input  wire [7:0]               adc_tvalid,
    input  wire                     tx_start_event_toggle,
    input  wire [11:0]              tx_play_word
);

    localparam integer CHANNELS = 8;
    localparam integer SAMPLES_PER_ADC_BEAT = 12;
    localparam integer SAMPLES_PER_RX_WORD = 24;
    localparam integer SAMPLE_CONTAINER_WIDTH = 16;
    localparam integer SAMPLE_WIDTH = 14;
    localparam integer ADC_CHANNEL_WIDTH = SAMPLES_PER_ADC_BEAT * SAMPLE_CONTAINER_WIDTH;
    localparam integer RX_CHANNEL_INPUT_WIDTH = SAMPLES_PER_RX_WORD * SAMPLE_CONTAINER_WIDTH;
    localparam integer RX_CHANNEL_WORD_WIDTH = SAMPLES_PER_RX_WORD * SAMPLE_WIDTH;
    localparam integer RX_DATA_WIDTH = CHANNELS * RX_CHANNEL_WORD_WIDTH;
    localparam integer PAIRS_PER_RX_WORD = SAMPLES_PER_RX_WORD / 2;
    localparam integer MAX_PAIR_INDEX = CAPTURE_WORDS * PAIRS_PER_RX_WORD;
    localparam integer WORD_ADDR_WIDTH = $clog2(CAPTURE_WORDS);
    localparam integer COUNT_WIDTH = $clog2(CAPTURE_WORDS + 1);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_ARMED_MANUAL = 2'd1;
    localparam [1:0] ST_ARMED_EVENT = 2'd2;
    localparam [1:0] ST_CAPTURE = 2'd3;

    // ADC stage: register RFDC input, then join two consecutive beats.
    reg [8*ADC_CHANNEL_WIDTH-1:0] adc_data_q;
    reg                           adc_valid_q;
    // ADC pair phase: an rx_clk toggle sampled in adc_clk. ph_q is registered so
    // pairs update only on the adc_clk edge between rx_clk edges (fixed latency).
    // At rx/adc edge A0 the old toggle equals rtog_q -> ph_q=1, so the pair
    // updates at A1 and rx_clk samples it at A2.
    (* DONT_TOUCH = "TRUE" *) reg [CHANNELS-1:0] rx_phase_tog_r;
    (* DONT_TOUCH = "TRUE" *) reg [CHANNELS-1:0] rtog_q;
    (* DONT_TOUCH = "TRUE" *) reg [CHANNELS-1:0] ph_q;
    reg [8*RX_CHANNEL_INPUT_WIDTH-1:0] adc_pair_data_q;
    reg                           adc_pair_valid_q;   // drives the capture state machine
    // Per-channel copies of adc_pair_valid_q. Each one is the clock enable of only
    // its own channel's rx_clk write registers; a single copy fanned out to all
    // eight channels across adc->rx_clk and closed with only +5 ps in D3B.
    (* DONT_TOUCH = "TRUE" *) reg [CHANNELS-1:0] adc_pair_valid_ch;
    wire                          adc_valid_all = &adc_tvalid;

    integer adc_channel;
    integer adc_sample;
    reg [RX_DATA_WIDTH-1:0] packed_rx_data;

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            adc_data_q <= {8*ADC_CHANNEL_WIDTH{1'b0}};
            adc_valid_q <= 1'b0;
            adc_pair_valid_q <= 1'b0;
        end else begin
            adc_data_q <= adc_tdata;
            adc_valid_q <= adc_valid_all;
            if (ph_q[0])
                adc_pair_valid_q <= adc_valid_all && adc_valid_q;
        end
    end

    genvar adc_channel_index;
    generate
        for (adc_channel_index = 0; adc_channel_index < CHANNELS; adc_channel_index = adc_channel_index + 1) begin : adc_pair_channels
            always @(posedge rx_clk) begin
                if (!rx_resetn)
                    rx_phase_tog_r[adc_channel_index] <= 1'b0;
                else
                    rx_phase_tog_r[adc_channel_index] <= ~rx_phase_tog_r[adc_channel_index];
            end

            always @(posedge adc_clk) begin
                rtog_q[adc_channel_index] <= rx_phase_tog_r[adc_channel_index];
                ph_q[adc_channel_index] <=
                    (rx_phase_tog_r[adc_channel_index] == rtog_q[adc_channel_index]);
            end

            always @(posedge adc_clk) begin
                if (!adc_resetn)
                    adc_pair_valid_ch[adc_channel_index] <= 1'b0;
                else if (ph_q[adc_channel_index])
                    adc_pair_valid_ch[adc_channel_index] <= adc_valid_all && adc_valid_q;
            end

            always @(posedge adc_clk) begin
                if (!adc_resetn)
                    adc_pair_data_q[adc_channel_index*RX_CHANNEL_INPUT_WIDTH +: RX_CHANNEL_INPUT_WIDTH] <= {RX_CHANNEL_INPUT_WIDTH{1'b0}};
                else if (ph_q[adc_channel_index])
                    adc_pair_data_q[adc_channel_index*RX_CHANNEL_INPUT_WIDTH +: RX_CHANNEL_INPUT_WIDTH] <= {
                        adc_tdata[adc_channel_index*ADC_CHANNEL_WIDTH +: ADC_CHANNEL_WIDTH],
                        adc_data_q[adc_channel_index*ADC_CHANNEL_WIDTH +: ADC_CHANNEL_WIDTH]
                    };
            end
        end
    endgenerate

    // RX stage: discard the two padding bits in each RFDC sample.
    always @* begin
        packed_rx_data = {RX_DATA_WIDTH{1'b0}};
        for (adc_channel = 0; adc_channel < CHANNELS; adc_channel = adc_channel + 1) begin
            for (adc_sample = 0; adc_sample < SAMPLES_PER_RX_WORD; adc_sample = adc_sample + 1) begin
                packed_rx_data[adc_channel*RX_CHANNEL_WORD_WIDTH + adc_sample*SAMPLE_WIDTH +: SAMPLE_WIDTH] =
                    adc_pair_data_q[adc_channel*RX_CHANNEL_INPUT_WIDTH + adc_sample*SAMPLE_CONTAINER_WIDTH + 2 +: SAMPLE_WIDTH];
            end
        end
    end

    wire arm_pulse_rx;
    wire abort_pulse_rx;
    wire [12:0] capture_config_rx;
    wire [11:0] tx_play_word_rx;
    wire tx_word_src_rcv;
    wire tx_word_dest_req;
    wire event_toggle_rx;
    wire done_toggle_host;
    wire armed_host;
    reg [11:0] capture_word_gray_rx;
    wire [11:0] capture_word_gray_host;
    wire [11:0] cap_tx_word_rx;

    wire arm_accept_host = h_arm && !h_busy && !h_armed &&
                           (h_cap_words != 0) && (h_cap_words <= CAPTURE_WORDS);

    xpm_cdc_pulse #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .REG_OUTPUT(0),
        .RST_USED(1),
        .SIM_ASSERT_CHK(0)
    ) arm_pulse_cdc (
        .src_clk(host_clk),
        .src_rst(!host_resetn),
        .src_pulse(arm_accept_host),
        .dest_clk(rx_clk),
        .dest_rst(!rx_resetn),
        .dest_pulse(arm_pulse_rx)
    );

    xpm_cdc_pulse #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .REG_OUTPUT(0),
        .RST_USED(1),
        .SIM_ASSERT_CHK(0)
    ) abort_pulse_cdc (
        .src_clk(host_clk),
        .src_rst(!host_resetn),
        .src_pulse(h_abort),
        .dest_clk(rx_clk),
        .dest_rst(!rx_resetn),
        .dest_pulse(abort_pulse_rx)
    );

    xpm_cdc_array_single #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG(0),
        .WIDTH(13)
    ) capture_config_cdc (
        .src_clk(host_clk),
        .src_in({h_cap_words, h_trig_mode}),
        .dest_clk(rx_clk),
        .dest_out(capture_config_rx)
    );

    xpm_cdc_single #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG(0)
    ) tx_event_cdc (
        .src_clk(dac_clk),
        .src_in(tx_start_event_toggle),
        .dest_clk(rx_clk),
        .dest_out(event_toggle_rx)
    );

    reg [11:0] tx_play_word_snapshot;
    reg tx_word_inflight;
    reg tx_word_send;

    always @(posedge tx_clk) begin
        if (!tx_resetn) begin
            tx_play_word_snapshot <= 12'd0;
            tx_word_inflight <= 1'b0;
            tx_word_send <= 1'b0;
        end else if (tx_word_inflight) begin
            if (tx_word_src_rcv)
                tx_word_send <= 1'b0;
            if (!tx_word_send && !tx_word_src_rcv)
                tx_word_inflight <= 1'b0;
        end else begin
            tx_play_word_snapshot <= tx_play_word;
            tx_word_inflight <= 1'b1;
            tx_word_send <= 1'b1;
        end
    end

    xpm_cdc_handshake #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0),
        .SRC_SYNC_FF(2),
        .DEST_EXT_HSK(0),
        .WIDTH(12)
    ) tx_word_cdc (
        .src_clk(tx_clk),
        .src_in(tx_play_word_snapshot),
        .src_send(tx_word_send),
        .src_rcv(tx_word_src_rcv),
        .dest_clk(rx_clk),
        .dest_req(tx_word_dest_req),
        .dest_ack(1'b0),
        .dest_out(tx_play_word_rx)
    );

    reg [1:0] state;
    reg [11:0] cap_words_latched;
    reg [COUNT_WIDTH-1:0] capture_word_count;
    reg [11:0] cap_tx_word_latched;
    reg event_seen;
    reg event_pending;
    reg done_toggle_rx;
    reg armed_rx;

    always @(posedge rx_clk) begin
        if (!rx_resetn)
            capture_word_gray_rx <= 12'd0;
        else
            capture_word_gray_rx <= capture_word_count ^ (capture_word_count >> 1);
    end

    wire event_changed = event_toggle_rx != event_seen;
    wire capture_start = adc_pair_valid_q &&
        ((state == ST_ARMED_MANUAL) ||
         ((state == ST_ARMED_EVENT) && (event_pending || event_changed)));
    wire capture_state_ok = (state == ST_CAPTURE) || (state == ST_ARMED_MANUAL) ||
        ((state == ST_ARMED_EVENT) && (event_pending || event_changed));
    wire capture_fire = adc_pair_valid_q && capture_state_ok;

    always @(posedge rx_clk) begin
        if (!rx_resetn) begin
            state <= ST_IDLE;
            cap_words_latched <= 12'd0;
            capture_word_count <= {COUNT_WIDTH{1'b0}};
            cap_tx_word_latched <= 12'd0;
            event_seen <= 1'b0;
            event_pending <= 1'b0;
            done_toggle_rx <= 1'b0;
            armed_rx <= 1'b0;
        end else begin
            event_seen <= event_toggle_rx;

            if (abort_pulse_rx) begin
                state <= ST_IDLE;
                cap_words_latched <= 12'd0;
                capture_word_count <= {COUNT_WIDTH{1'b0}};
                event_pending <= 1'b0;
                armed_rx <= 1'b0;
            end else if (arm_pulse_rx && state == ST_IDLE) begin
                cap_words_latched <= capture_config_rx[12:1];
                capture_word_count <= {COUNT_WIDTH{1'b0}};
                event_pending <= 1'b0;
                armed_rx <= 1'b1;
                if (capture_config_rx[0])
                    state <= ST_ARMED_EVENT;
                else
                    state <= ST_ARMED_MANUAL;
            end else begin
                if (state == ST_ARMED_EVENT && event_changed) begin
                    event_pending <= 1'b1;
                    cap_tx_word_latched <= tx_play_word_rx;
                end

                if (capture_start && state == ST_ARMED_MANUAL) begin
                    cap_tx_word_latched <= tx_play_word_rx;
                end
                if (capture_start) begin
                    event_pending <= 1'b0;
                    armed_rx <= 1'b0;
                end

                if (capture_fire) begin
                    if (capture_word_count + 1'b1 >= cap_words_latched) begin
                        capture_word_count <= cap_words_latched;
                        state <= ST_IDLE;
                        done_toggle_rx <= ~done_toggle_rx;
                        armed_rx <= 1'b0;
                    end else begin
                        capture_word_count <= capture_word_count + 1'b1;
                        state <= ST_CAPTURE;
                    end
                end
            end
        end
    end

    xpm_cdc_array_single #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG(1),
        .WIDTH(12)
    ) capture_count_cdc (
        .src_clk(rx_clk),
        .src_in(capture_word_gray_rx),
        .dest_clk(host_clk),
        .dest_out(capture_word_gray_host)
    );

    xpm_cdc_array_single #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG(0),
        .WIDTH(12)
    ) cap_tx_word_cdc (
        .src_clk(rx_clk),
        .src_in(cap_tx_word_latched),
        .dest_clk(host_clk),
        .dest_out(cap_tx_word_rx)
    );

    xpm_cdc_single #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG(0)
    ) done_toggle_cdc (
        .src_clk(rx_clk),
        .src_in(done_toggle_rx),
        .dest_clk(host_clk),
        .dest_out(done_toggle_host)
    );

    xpm_cdc_single #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG(0)
    ) armed_cdc (
        .src_clk(rx_clk),
        .src_in(armed_rx),
        .dest_clk(host_clk),
        .dest_out(armed_host)
    );

    reg done_toggle_seen_host;
    reg [11:0] capture_word_count_host;
    integer gray_bit;

    always @* begin
        capture_word_count_host[11] = capture_word_gray_host[11];
        for (gray_bit = 10; gray_bit >= 0; gray_bit = gray_bit - 1)
            capture_word_count_host[gray_bit] = capture_word_count_host[gray_bit+1] ^ capture_word_gray_host[gray_bit];
    end

    assign h_captured_samples = capture_word_count_host * SAMPLES_PER_RX_WORD;
    assign h_cap_tx_word = cap_tx_word_rx;

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            h_busy <= 1'b0;
            h_armed <= 1'b0;
            h_done <= 1'b0;
            done_toggle_seen_host <= 1'b0;
        end else begin
            h_armed <= armed_host;
            if (h_abort) begin
                h_busy <= 1'b0;
                h_armed <= 1'b0;
                h_done <= 1'b0;
            end else if (done_toggle_host != done_toggle_seen_host) begin
                done_toggle_seen_host <= done_toggle_host;
                h_busy <= 1'b0;
                h_armed <= 1'b0;
                h_done <= 1'b1;
            end else if (arm_accept_host) begin
                h_busy <= 1'b1;
                h_done <= 1'b0;
            end
        end
    end

    wire [WORD_ADDR_WIDTH-1:0] rd_word_index = h_rd_pair / PAIRS_PER_RX_WORD;
    wire [3:0] rd_pair_offset = h_rd_pair % PAIRS_PER_RX_WORD;
    wire rd_accept = h_rd_req && !h_busy && (h_rd_pair < MAX_PAIR_INDEX);

    // Stage each channel's write controls and data before driving the wide BRAM bank.
    wire [RX_CHANNEL_WORD_WIDTH-1:0] channel_read_word [0:CHANNELS-1];
    genvar channel_index;
    generate
        for (channel_index = 0; channel_index < CHANNELS; channel_index = channel_index + 1) begin : channel_bram
            (* ram_style = "block" *) reg [RX_CHANNEL_WORD_WIDTH-1:0] capture_mem [0:CAPTURE_WORDS-1];
            reg [RX_CHANNEL_WORD_WIDTH-1:0] read_word_q;
            reg channel_write_enable_q;
            reg [WORD_ADDR_WIDTH-1:0] channel_write_addr_q;
            reg [RX_CHANNEL_WORD_WIDTH-1:0] channel_write_data_q;
            // Same as capture_fire, but enabled by this channel's own valid copy.
            wire channel_fire = adc_pair_valid_ch[channel_index] && capture_state_ok;

            always @(posedge rx_clk) begin
                if (!rx_resetn) begin
                    channel_write_enable_q <= 1'b0;
                    channel_write_addr_q <= {WORD_ADDR_WIDTH{1'b0}};
                    channel_write_data_q <= {RX_CHANNEL_WORD_WIDTH{1'b0}};
                end else begin
                    channel_write_enable_q <= channel_fire;
                    if (channel_fire) begin
                        channel_write_addr_q <= capture_word_count[WORD_ADDR_WIDTH-1:0];
                        channel_write_data_q <= packed_rx_data[channel_index*RX_CHANNEL_WORD_WIDTH +: RX_CHANNEL_WORD_WIDTH];
                    end
                    if (channel_write_enable_q)
                        capture_mem[channel_write_addr_q] <= channel_write_data_q;
                end
            end

            always @(posedge host_clk) begin
                if (!host_resetn)
                    read_word_q <= {RX_CHANNEL_WORD_WIDTH{1'b0}};
                else if (rd_accept && h_rd_ch == channel_index)
                    read_word_q <= capture_mem[rd_word_index];
            end

            assign channel_read_word[channel_index] = read_word_q;
        end
    endgenerate

    reg [RX_CHANNEL_WORD_WIDTH-1:0] selected_read_word;
    reg [2:0] rd_channel_q;
    reg [3:0] rd_pair_offset_q;
    reg rd_pending;
    reg [13:0] rd_sample_early;
    reg [13:0] rd_sample_late;
    integer read_channel;

    always @* begin
        selected_read_word = {RX_CHANNEL_WORD_WIDTH{1'b0}};
        for (read_channel = 0; read_channel < CHANNELS; read_channel = read_channel + 1) begin
            if (rd_channel_q == read_channel)
                selected_read_word = channel_read_word[read_channel];
        end
        rd_sample_early = selected_read_word[(rd_pair_offset_q*2)*SAMPLE_WIDTH +: SAMPLE_WIDTH];
        rd_sample_late = selected_read_word[((rd_pair_offset_q*2)+1)*SAMPLE_WIDTH +: SAMPLE_WIDTH];
    end

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            h_rd_data <= 32'd0;
            h_rd_valid <= 1'b0;
            rd_channel_q <= 3'd0;
            rd_pair_offset_q <= 4'd0;
            rd_pending <= 1'b0;
        end else begin
            h_rd_valid <= rd_pending;
            rd_pending <= rd_accept;
            if (rd_accept) begin
                rd_channel_q <= h_rd_ch;
                rd_pair_offset_q <= rd_pair_offset;
            end
            if (rd_pending)
                h_rd_data <= {{rd_sample_late, 2'b00}, {rd_sample_early, 2'b00}};
        end
    end

endmodule

`default_nettype wire
