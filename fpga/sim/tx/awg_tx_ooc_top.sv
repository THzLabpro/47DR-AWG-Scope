`default_nettype none

module awg_tx_ooc_top (
    input  wire          host_clk,
    input  wire          host_resetn,
    input  wire          dac_clk,
    input  wire          dac_resetn,
    input  wire          tx_resetn,
    input  wire          ps_config_done,
    input  wire [2:0]    h_wr_ch,
    input  wire          h_wr_rewind,
    input  wire [31:0]   h_wr_data,
    input  wire          h_wr_valid,
    output wire          h_wr_ready,
    output wire [17:0]   h_wr_ptr,
    input  wire          h_crc_start,
    input  wire [2:0]    h_crc_ch,
    output wire          h_crc_busy,
    output wire [31:0]   h_crc_value,
    input  wire          h_start,
    input  wire          h_stop,
    input  wire          h_clear_fault,
    input  wire [12:0]   h_length_words,
    input  wire [7:0]    h_mask,
    output wire          h_running,
    output wire          h_started,
    output wire [7:0]    h_faults,
    output wire [31:0]   h_wrap_count,
    output wire          h_locked,
    output wire          h_start_rejected,
    output wire [2047:0] dac_tdata,
    output wire [7:0]    dac_tvalid,
    input  wire [7:0]    dac_tready,
    output wire          tx_start_event,
    output wire          tx_start_event_toggle,
    output wire [11:0]   tx_play_word
);
    wire tx_clk;

    BUFGCE_DIV #(
        .BUFGCE_DIVIDE(2),
        .IS_CE_INVERTED(1'b0),
        .IS_CLR_INVERTED(1'b0)
    ) tx_clk_div_i (
        .I(dac_clk),
        .CE(1'b1),
        .CLR(1'b0),
        .O(tx_clk)
    );

    awg_tx awg_tx_i (
        .host_clk(host_clk),
        .host_resetn(host_resetn),
        .tx_clk(tx_clk),
        .tx_resetn(tx_resetn),
        .dac_clk(dac_clk),
        .dac_resetn(dac_resetn),
        .ps_config_done(ps_config_done),
        .h_wr_ch(h_wr_ch),
        .h_wr_rewind(h_wr_rewind),
        .h_wr_data(h_wr_data),
        .h_wr_valid(h_wr_valid),
        .h_wr_ready(h_wr_ready),
        .h_wr_ptr(h_wr_ptr),
        .h_crc_start(h_crc_start),
        .h_crc_ch(h_crc_ch),
        .h_crc_busy(h_crc_busy),
        .h_crc_value(h_crc_value),
        .h_start(h_start),
        .h_stop(h_stop),
        .h_clear_fault(h_clear_fault),
        .h_length_words(h_length_words),
        .h_mask(h_mask),
        .h_running(h_running),
        .h_started(h_started),
        .h_faults(h_faults),
        .h_wrap_count(h_wrap_count),
        .h_locked(h_locked),
        .h_start_rejected(h_start_rejected),
        .dac_tdata(dac_tdata),
        .dac_tvalid(dac_tvalid),
        .dac_tready(dac_tready),
        .tx_start_event(tx_start_event),
        .tx_start_event_toggle(tx_start_event_toggle),
        .tx_play_word(tx_play_word)
    );
endmodule

`default_nettype wire
