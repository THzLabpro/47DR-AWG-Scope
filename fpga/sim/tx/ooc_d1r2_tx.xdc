create_clock -name dac_clk -period 1.632653 [get_ports dac_clk]
create_generated_clock -name tx_clk -source [get_pins tx_clk_div_i/I] \
    -divide_by 2 [get_pins tx_clk_div_i/O]
create_clock -name host_clk -period 10.000000 [get_ports host_clk]

proc constrain_cdc_bus {label from_pattern to_pattern delay_ns} {
    set from_objects [get_pins -hier -filter "NAME =~ $from_pattern"]
    set to_objects [get_pins -hier -filter "NAME =~ $to_pattern"]
    puts "INFO: D1R2 CDC bus $label objects: from=[llength $from_objects] to=[llength $to_objects]"
    if {[llength $from_objects] == 0 || [llength $to_objects] == 0} {
        puts "WARNING: D1R2 CDC bus constraint not applied: $label"
        return
    }
    set_max_delay -datapath_only $delay_ns -from $from_objects -to $to_objects
    set_bus_skew $delay_ns -from $from_objects -to $to_objects
}

proc constrain_cdc_bit {label from_pattern to_pattern delay_ns} {
    set from_objects [get_pins -hier -filter "NAME =~ $from_pattern"]
    set to_objects [get_pins -hier -filter "NAME =~ $to_pattern"]
    puts "INFO: D1R2 CDC bit $label objects: from=[llength $from_objects] to=[llength $to_objects]"
    if {[llength $from_objects] == 0 || [llength $to_objects] == 0} {
        puts "WARNING: D1R2 CDC bit constraint not applied: $label"
        return
    }
    set_max_delay -datapath_only $delay_ns -from $from_objects -to $to_objects
}

# host_clk -> tx_clk asynchronous FIFO and bundled command data.
constrain_cdc_bus fifo_write_pointer {*wr_fifo_gray_reg*/Q} {*wr_fifo_gray_t1_reg*/D} 3.265306
constrain_cdc_bus fifo_read_data {*wr_fifo_mem_reg*/RAM*/CLK} {*fifo_data_stage_reg*/D} 3.265306
constrain_cdc_bus rewind_channel {*rewind_ch_host_reg*/Q} {*rewind_ch_t1_reg*/D} 3.265306
constrain_cdc_bus crc_channel {*crc_ch_host_reg*/Q} {*crc_ch_t1_reg*/D} 3.265306
constrain_cdc_bus start_configuration_length {*length_hold_host_reg*/Q} {*length_t1_reg*/D} 3.265306
constrain_cdc_bus start_configuration_mask {*mask_hold_host_reg*/Q} {*mask_t1_reg*/D} 3.265306
constrain_cdc_bit rewind_toggle {*rewind_toggle_host_reg/Q} {*rewind_sync_reg\[0\]/D} 3.265306
constrain_cdc_bit start_toggle {*start_toggle_host_reg/Q} {*start_sync_reg\[0\]/D} 3.265306
constrain_cdc_bit stop_toggle {*stop_toggle_host_reg/Q} {*stop_sync_reg\[0\]/D} 3.265306
constrain_cdc_bit clear_toggle {*clear_toggle_host_reg/Q} {*clear_sync_reg\[0\]/D} 3.265306
constrain_cdc_bit crc_toggle {*crc_toggle_host_reg/Q} {*crc_sync_reg\[0\]/D} 3.265306

# tx_clk -> host_clk asynchronous FIFO pointer, Gray-coded status, and bundled CRC data.
constrain_cdc_bus fifo_read_pointer {*rd_fifo_gray_reg*/Q} {*rd_fifo_gray_h1_reg*/D} 10.000000
constrain_cdc_bus write_sample_count {*write_words_gray_tx_reg*/Q} {*write_words_gray_h1_reg*/D} 10.000000
constrain_cdc_bus wrap_count {*wrap_gray_tx_reg*/Q} {*wrap_gray_h1_reg*/D} 10.000000
constrain_cdc_bus fault_flags {*fault_tx_reg*/Q} {*fault_h1_reg*/D} 10.000000
constrain_cdc_bus crc_result_data {*crc_value_tx_reg*/Q} {*crc_value_host_reg*/D} 10.000000
constrain_cdc_bit running_state {*state_reg*/Q} {*running_h1_reg/D} 10.000000
constrain_cdc_bit started_state {*started_tx_reg/Q} {*started_h1_reg/D} 10.000000
constrain_cdc_bit start_rejected_state {*start_rejected_tx_reg/Q} {*start_rejected_h1_reg/D} 10.000000
constrain_cdc_bit crc_busy_state {*state_reg*/Q} {*crc_busy_h1_reg/D} 10.000000
constrain_cdc_bit crc_done_toggle {*crc_done_toggle_tx_reg/Q} {*crc_done_h1_reg/D} 10.000000
