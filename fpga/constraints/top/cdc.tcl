set d3a6_cdc_matches {}

proc require_objects {label objects} {
    global d3a6_cdc_matches
    if {[llength $objects] == 0} {
        error "D3A6 CDC constraint '$label' matched zero objects"
    }
    lappend d3a6_cdc_matches [list $label [llength $objects]]
    puts "CDC_MATCH name=$label count=[llength $objects]"
    return $objects
}

proc sequential_cells {label pattern} {
    set candidates [get_cells -hierarchical -regexp -quiet $pattern]
    set registers {}
    foreach cell $candidates {
        if {[string match {FD*} [get_property REF_NAME $cell]]} {
            lappend registers $cell
        }
    }
    return [require_objects $label $registers]
}

proc apply_bus_timing {label source_pattern destination_pattern max_delay} {
    set source_regs [sequential_cells ${label}_source $source_pattern]
    set destination_regs [sequential_cells ${label}_destination $destination_pattern]
    set_max_delay -datapath_only $max_delay -from $source_regs -to $destination_regs
    set_bus_skew $max_delay -from $source_regs -to $destination_regs
    puts "CDC_RULE name=$label source_regs=[llength $source_regs] destination_regs=[llength $destination_regs] max_delay_ns=$max_delay bus_skew_ns=$max_delay"
}

proc apply_sync_false_path {label source_pattern destination_regexp} {
    set source_regs [sequential_cells ${label}_source $source_pattern]
    set destination_regs [sequential_cells ${label}_stage1 $destination_regexp]
    set_false_path -from $source_regs -to $destination_regs
    puts "CDC_RULE name=$label source_regs=[llength $source_regs] stage1_regs=[llength $destination_regs]"
}

proc apply_cdc_waiver {label cdc_id source_pattern destination_pattern description} {
    set source_pins [require_objects ${label}_from \
        [get_pins -hierarchical -regexp -quiet $source_pattern]]
    set destination_pins [require_objects ${label}_to \
        [get_pins -hierarchical -regexp -quiet $destination_pattern]]
    create_waiver -type CDC -id $cdc_id -from $source_pins -to $destination_pins \
        -description $description
    puts "CDC_WAIVER name=$label id=$cdc_id from=[llength $source_pins] to=[llength $destination_pins]"
}

set sysref_source [require_objects sysref_source \
    [get_cells -hierarchical -quiet *pl_sysref_r_reg*]]
set sysref_dac [require_objects sysref_dac_stage1 \
    [get_cells -hierarchical -quiet *sysref_dac_meta_reg*]]
set sysref_adc [require_objects sysref_adc_stage1 \
    [get_cells -hierarchical -quiet *sysref_adc_meta_reg*]]

set host_clocks [require_objects host_clock [get_clocks -quiet clk_pl_0]]
set dac_clock_pins [require_objects dac_clock_pin \
    [get_pins -hierarchical -quiet *system_i/data_clk]]
set adc_clock_pins [require_objects adc_clock_pin \
    [get_pins -hierarchical -quiet *system_i/adc_capture_clk]]
set dac_clocks [require_objects dac_clock \
    [get_clocks -quiet -of_objects $dac_clock_pins]]
set tx_clocks [require_objects tx_clock [get_clocks -quiet tx_clk]]
set adc_clocks [require_objects adc_clock \
    [get_clocks -quiet -of_objects $adc_clock_pins]]
set rx_clocks [require_objects rx_clock [get_clocks -quiet rx_clk]]
set eth_tx_clocks [require_objects eth_tx_clock [get_clocks -quiet *txoutclk_out*]]
set eth_rx_clocks [require_objects eth_rx_clock [get_clocks -quiet *rxoutclk_out*]]
set eth_management_clocks [require_objects eth_management_clock [concat \
    [get_clocks -quiet *demo_management_clock*] \
    [get_clocks -quiet *optical_port1_clk_wiz_0*]]]
set eth_clocks [concat $eth_tx_clocks $eth_rx_clocks $eth_management_clocks]

# tx_clk has bundled and Gray-coded data crossings. Keep those paths visible
# and constrain their first-stage buses individually instead of masking them
# with a host/tx clock group. The other host/RF pairs are grouped as async.
set rf_async_clocks [require_objects rf_async_clocks \
    [concat $dac_clocks $adc_clocks $rx_clocks]]
set eth_clocks [require_objects eth_clocks $eth_clocks]
set_clock_groups -asynchronous -group $host_clocks -group $rf_async_clocks
set_clock_groups -asynchronous -group $host_clocks -group $eth_clocks
puts "CDC_MATCH name=host_rf_clock_group host=[llength $host_clocks] rf=[llength $rf_async_clocks]"
puts "CDC_MATCH name=host_eth_clock_group host=[llength $host_clocks] eth=[llength $eth_clocks]"

set dac_period [get_property PERIOD [lindex $dac_clocks 0]]
set adc_period [get_property PERIOD [lindex $adc_clocks 0]]
set host_period [get_property PERIOD [lindex $host_clocks 0]]
set tx_period [get_property PERIOD [lindex $tx_clocks 0]]
set_max_delay -datapath_only $dac_period -from $sysref_source -to $sysref_dac
set_max_delay -datapath_only $adc_period -from $sysref_source -to $sysref_adc
puts "CDC_RULE name=sysref_dac max_delay_ns=$dac_period"
puts "CDC_RULE name=sysref_adc max_delay_ns=$adc_period"

apply_bus_timing crc_value_tx_to_host {.*crc_value_tx_reg\[[0-9]+\]$} \
    {.*crc_value_host_reg\[[0-9]+\]$} $host_period
apply_bus_timing wrap_gray_tx_to_host {.*wrap_gray_tx_reg\[[0-9]+\]$} \
    {.*wrap_gray_h1_reg\[[0-9]+\]$} $host_period
apply_bus_timing fault_tx_to_host {.*fault_tx_reg\[[0-9]+\]$} \
    {.*fault_h1_reg\[[0-9]+\]$} $host_period

for {set channel 0} {$channel < 8} {incr channel} {
    set src_re [format {.*write_words_gray_tx_reg\[%d\]\[[0-9]+\]} $channel]
    set dst_re [format {.*write_words_gray_h1_reg\[%d\]\[[0-9]+\]} $channel]
    apply_bus_timing write_words_gray_${channel}_to_host $src_re $dst_re $host_period
}

apply_bus_timing rewind_channel_host_to_tx \
    {.*rewind_ch_host_reg\[[0-9]+\]$} {.*rewind_ch_t1_reg\[[0-9]+\]$} $tx_period
apply_bus_timing crc_channel_host_to_tx \
    {.*crc_ch_host_reg\[[0-9]+\]$} {.*crc_ch_t1_reg\[[0-9]+\]$} $tx_period
apply_bus_timing length_host_to_tx \
    {.*length_hold_host_reg\[[0-9]+\]$} {.*length_t1_reg\[[0-9]+\]$} $tx_period
apply_bus_timing mask_host_to_tx \
    {.*mask_hold_host_reg\[[0-9]+\]$} {.*mask_t1_reg\[[0-9]+\]$} $tx_period

apply_sync_false_path crc_busy_tx_to_host {.*crc_busy_tx_reg$} {.*crc_busy_h1_reg$}
apply_sync_false_path crc_done_toggle_to_host {.*crc_done_toggle_tx_reg$} {.*crc_done_h1_reg$}
apply_sync_false_path running_tx_to_host {.*tx_i/FSM_onehot_state_reg\[2\]$} {.*running_h1_reg$}
apply_sync_false_path started_tx_to_host {.*started_tx_reg$} {.*started_h1_reg$}
apply_sync_false_path start_rejected_tx_to_host {.*start_rejected_tx_reg$} {.*start_rejected_h1_reg$}

apply_sync_false_path rewind_toggle_host_to_tx {.*rewind_toggle_host_reg$} {.*rewind_sync_reg\[0\]$}
apply_sync_false_path start_toggle_host_to_tx {.*start_toggle_host_reg$} {.*start_sync_reg\[0\]$}
apply_sync_false_path stop_toggle_host_to_tx {.*stop_toggle_host_reg$} {.*stop_sync_reg\[0\]$}
apply_sync_false_path clear_toggle_host_to_tx {.*clear_toggle_host_reg$} {.*clear_sync_reg\[0\]$}
apply_sync_false_path crc_toggle_host_to_tx {.*crc_toggle_host_reg$} {.*crc_sync_reg\[0\]$}

apply_sync_false_path config_done_to_tx_ready \
    {.*user_control_i/config_done_reg$} {.*tx_i/ps_ready_sync_reg\[0\]$}

for {set tile 0} {$tile < 4} {incr tile} {
    set rf_source {.*rst_rf_clk/U0/ACTIVE_LOW_PR_OUT_DFF\[0\]\.FDRE_PER_N/C$}
    set rf_destination [format {.*usp_rf_data_converter_0/inst/cdc_dac%d_clk_valid_i/syncstages_ff_reg\[0\]/D$} $tile]
    apply_cdc_waiver rfdc_dac${tile}_clock_valid CDC-11 $rf_source $rf_destination \
        "廠商 IP 內部 RFDC DAC clock-valid CDC-11"

    set adc_source {.*rst_adc_clk/U0/ACTIVE_LOW_PR_OUT_DFF\[0\]\.FDRE_PER_N/C$}
    set adc_destination [format {.*usp_rf_data_converter_0/inst/cdc_adc%d_clk_valid_i/syncstages_ff_reg\[0\]/D$} $tile]
    apply_cdc_waiver rfdc_adc${tile}_clock_valid CDC-11 $adc_source $adc_destination \
        "廠商 IP 內部 RFDC ADC clock-valid CDC-11"

    set control_source [format {.*usp_rf_data_converter_0/inst/adc%d_cmn_control_ff_reg\[12\]/C$} $tile]
    set control_destination [format {.*usp_rf_data_converter_0/inst/.*rf_wrapper_i/rx%d_u_adc/CONTROL_COMMON\[12\]$} $tile]
    apply_cdc_waiver rfdc_adc${tile}_control_common CDC-13 $control_source $control_destination \
        "廠商 IP 內部 RFDC CONTROL_COMMON CDC-13"
}

apply_cdc_waiver eth_reset_xpm CDC-10 \
    {.*eth_reset_pipe_reg\[1\]/C$} \
    {.*eth_core_i/u_eth_reset/arststages_ff_reg\[0\]/CLR$} \
    "外層同步重置後進入 Ethernet XPM 非同步重置同步器；合併的管理鎖定與 MAC reset 是預期非同步 assert"
apply_cdc_waiver eth_reset_gt_controller CDC-10 \
    {.*eth_reset_pipe_reg\[1\]/C$} \
    {.*reset_synchronizer_gtwiz_reset_all_inst/rst_in_meta_reg/PRE$} \
    "GT reset controller 位於唯讀廠商 IP；外層 host reset 已先同步打兩拍，GT reset 仍由 IP 依自身時鐘釋放"
