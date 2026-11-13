# D0 v2 BD reconstruction for XCZU47DR.
# The project is created in an empty build directory.  The archived BD is used
# only as a structural seed; all v2 RFDC and clock settings are applied here.

set_param general.maxThreads 20

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir .. ..]]
set build_root [expr {[llength $argv] ? [file normalize [lindex $argv 0]] : [file join $repo_root build D0]}]
set project_dir [file join $build_root vivado]
set seed_dir [file join $build_root bd_seed]
set part xczu47dr-fsve1156-2-i

proc ensure_port {name dir type freq} {
    set p [get_bd_ports -quiet $name]
    if {![llength $p]} {
        if {$type eq "clk"} {
            set p [create_bd_port -dir $dir -type $type -freq_hz $freq $name]
        } else {
            set p [create_bd_port -dir $dir -type $type $name]
        }
    }
    if {$type eq "clk"} {set_property CONFIG.FREQ_HZ $freq $p}
    if {$type eq "rst"} {set_property CONFIG.POLARITY ACTIVE_LOW $p}
    return $p
}

proc disconnect_pin {pin} {
    set net [get_bd_nets -quiet -of_objects $pin]
    if {[llength $net]} {disconnect_bd_net $net $pin}
}

proc connect_net {source sink} {
    if {![llength $source] || ![llength $sink]} {
        error "connect_net missing endpoint source=$source sink=$sink"
    }
    set source_net [get_bd_nets -quiet -of_objects $source]
    set sink_net [get_bd_nets -quiet -of_objects $sink]
    if {[llength $source_net] && [llength $sink_net] && [lindex $source_net 0] eq [lindex $sink_net 0]} {
        return
    }
    if {[llength $sink_net]} {disconnect_bd_net [lindex $sink_net 0] $sink}
    connect_bd_net $source $sink
}

file mkdir $build_root
if {[file exists $project_dir]} {file delete -force $project_dir}
if {[file exists $seed_dir]} {file delete -force $seed_dir}
file mkdir $seed_dir
set reference_system [file join $repo_root reference system]
foreach item [glob -nocomplain -directory $reference_system *] {
    file copy -force $item $seed_dir
}

# The archived BD/XCI files embed output paths from the original project.
# Rewrite only this task's staged copies so generation stays under build_root.
set generation_root [file join $build_root generated]
file mkdir $generation_root
set bd_seed_file [file join $seed_dir system.bd]
set fd [open $bd_seed_file r]
set bd_text [read $fd]
close $fd
set bd_text [string map [list \
    {../../../../rf_adda_loop.gen/sources_1/bd/system} \
    {../generated/sources_1/bd/system}] $bd_text]
set fd [open $bd_seed_file w]
puts -nonewline $fd $bd_text
close $fd

set audit_file [file join $build_root generation_path_audit.txt]
set audit_fd [open $audit_file w]
set bd_resolved [file normalize [file join $seed_dir ../generated/sources_1/bd/system]]
if {[string first [file normalize $build_root] $bd_resolved] != 0} {
    close $audit_fd
    error "BD generation path escapes task build: $bd_resolved"
}
puts $audit_fd "BD $bd_seed_file -> $bd_resolved"
foreach xci [glob -nocomplain -types f -directory [file join $seed_dir ip] */*.xci] {
    set fd [open $xci r]
    set xci_text [read $fd]
    close $fd
    set xci_name [file rootname [file tail $xci]]
    set generated_xci_dir "../../../generated/sources_1/bd/system/ip/$xci_name"
    regsub -all {../../../../../../rf_adda_loop\.gen/sources_1/bd/system/ip/[^" <]+} \
        $xci_text $generated_xci_dir xci_text
    set fd [open $xci w]
    puts -nonewline $fd $xci_text
    close $fd
    if {[regexp {rf_adda_loop\.gen} $xci_text]} {
        close $audit_fd
        error "Archived generation path remains in staged XCI: $xci"
    }
    set xci_resolved [file normalize [file join [file dirname $xci] \
        $generated_xci_dir]]
    if {[string first [file normalize $build_root] $xci_resolved] != 0} {
        close $audit_fd
        error "XCI generation path escapes task build: $xci_resolved"
    }
    puts $audit_fd "XCI $xci -> $xci_resolved"
}
close $audit_fd

create_project -force d0_clock_probe $project_dir -part $part
set_property target_language Verilog [current_project]
set seed_bd [file join $seed_dir system.bd]
set up_axi_src [file join $repo_root rtl up_axi.v]
if {[file exists $up_axi_src]} {add_files -norecurse $up_axi_src}
add_files -norecurse $seed_bd
set bd [get_files -quiet */system.bd]
if {[llength $bd] != 1} {error "Expected one seeded system.bd, found [llength $bd]"}
open_bd_design $bd

set rf [get_bd_cells -quiet usp_rf_data_converter_0]
if {[llength $rf] != 1} {error "RFDC cell usp_rf_data_converter_0 is missing"}

# HWH-derived RFDC settings, with only the frozen v2 sample-rate/mode changes.
set rfdc_cfg [list \
    CONFIG.ADC_RTS false \
    CONFIG.DAC_RTS false \
    CONFIG.Calibration_Freeze false]
foreach tile {0 1 2 3} {
    lappend rfdc_cfg CONFIG.ADC${tile}_Sampling_Rate 5.0
    lappend rfdc_cfg CONFIG.ADC${tile}_Multi_Tile_Sync true
    lappend rfdc_cfg CONFIG.DAC${tile}_Sampling_Rate 9.8
    lappend rfdc_cfg CONFIG.DAC${tile}_Multi_Tile_Sync true
}
foreach {tile outclk} {0 39.063 1 312.500 2 39.063 3 39.063} {
    lappend rfdc_cfg CONFIG.ADC${tile}_Outclk_Freq $outclk
}
foreach tile {0 1 2 3} {lappend rfdc_cfg CONFIG.DAC${tile}_Outclk_Freq 612.500}
foreach {tile source dist pll} {
    0 1 0 false
    1 1 2 true
    2 1 0 false
    3 1 0 false
} {
    lappend rfdc_cfg CONFIG.ADC${tile}_Clock_Source $source
    lappend rfdc_cfg CONFIG.ADC${tile}_Clock_Dist $dist
    lappend rfdc_cfg CONFIG.ADC${tile}_PLL_Enable $pll
}
foreach {tile source dist pll} {
    0 6 0 false
    1 6 0 false
    2 6 2 true
    3 6 0 false
} {
    lappend rfdc_cfg CONFIG.DAC${tile}_Clock_Source $source
    lappend rfdc_cfg CONFIG.DAC${tile}_Clock_Dist $dist
    lappend rfdc_cfg CONFIG.DAC${tile}_PLL_Enable $pll
}
lappend rfdc_cfg CONFIG.ADC1_Refclk_Freq 200.000
lappend rfdc_cfg CONFIG.DAC2_Refclk_Freq 200.000
foreach tile {0 1 2 3} {
    foreach slice {0 1 2 3} {
        set lane ${tile}${slice}
        set active [expr {$slice == 0 || $slice == 2}]
        lappend rfdc_cfg CONFIG.ADC_Slice${lane}_Enable $active
        lappend rfdc_cfg CONFIG.DAC_Slice${lane}_Enable $active
        if {$active} {
            lappend rfdc_cfg CONFIG.ADC_Data_Type${lane} 0 \
                CONFIG.ADC_Decimation_Mode${lane} 1 \
                CONFIG.ADC_Mixer_Mode${lane} 2 \
                CONFIG.ADC_Mixer_Type${lane} 1 \
                CONFIG.ADC_Data_Width${lane} 12 \
                CONFIG.ADC_Dither${lane} false \
                CONFIG.DAC_Data_Type${lane} 0 \
                CONFIG.DAC_Mode${lane} 3 \
                CONFIG.DAC_Interpolation_Mode${lane} 1 \
                CONFIG.DAC_Mixer_Mode${lane} 2 \
                CONFIG.DAC_Mixer_Type${lane} 1 \
                CONFIG.DAC_Data_Width${lane} 16
        }
    }
}
set_property -dict $rfdc_cfg $rf

# DAC fabric MMCM: RFDC clk_dac2 -> 612.5 MHz. VCO = 612.5*4.25/2 =
# 1301.5625 MHz; output divide = 2.125.
set dac_wiz [get_bd_cells -quiet clk_wiz_0]
if {[llength $dac_wiz] != 1} {error "DAC clk_wiz_0 is missing"}
set_property -dict [list \
    CONFIG.PRIM_SOURCE No_buffer \
    CONFIG.PRIM_IN_FREQ 612.500 \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 612.500 \
    CONFIG.CLKOUT2_USED false \
    CONFIG.USE_RESET true \
    CONFIG.USE_FREQ_SYNTH true] $dac_wiz

# Keep the reference RFDC clock as the DAC MMCM input.
connect_net [get_bd_pins $rf/clk_dac2] [get_bd_pins $dac_wiz/clk_in1]
set data_clk [ensure_port data_clk O clk 612500000]
connect_net [get_bd_pins $dac_wiz/clk_out1] $data_clk
set_property CONFIG.FREQ_HZ 612500000 $data_clk

# ADC fabric MMCM: board LMK PL_CLK 200 MHz -> 416.666667 MHz.
set adc_wiz [get_bd_cells -quiet clk_wiz_adc]
if {![llength $adc_wiz]} {
    set adc_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_adc]
}
set_property -dict [list \
    CONFIG.PRIM_SOURCE No_buffer \
    CONFIG.PRIM_IN_FREQ 200.000 \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 416.666667 \
    CONFIG.NUM_OUT_CLKS 1 \
    CONFIG.USE_RESET false \
    CONFIG.MMCM_CLKFBOUT_MULT_F 71.875 \
    CONFIG.MMCM_DIVCLK_DIVIDE 12 \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F 2.875] $adc_wiz
set adc_ref [ensure_port adc_fabric_ref I clk 200000000]
set adc_clk [ensure_port adc_capture_clk O clk 416666666]
connect_net $adc_ref [get_bd_pins $adc_wiz/clk_in1]
connect_net [get_bd_pins $adc_wiz/clk_out1] $adc_clk
set_property CONFIG.FREQ_HZ 416666666 $adc_clk

# ADC AXIS clock/reset is independent of the DAC fabric clock.
set rst_adc [get_bd_cells -quiet rst_adc_clk]
if {![llength $rst_adc]} {
    set rst_adc [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_adc_clk]
}
connect_net [get_bd_pins $adc_wiz/clk_out1] [get_bd_pins $rst_adc/slowest_sync_clk]
connect_net [get_bd_pins $adc_wiz/locked] [get_bd_pins $rst_adc/dcm_locked]
set pl_reset [get_bd_ports -quiet pl_resetn0]
if {![llength $pl_reset]} {set pl_reset [ensure_port pl_resetn0 O rst 0]}
connect_net $pl_reset [get_bd_pins $rst_adc/ext_reset_in]
set adc_reset [ensure_port adc_axis_resetn O rst 0]
connect_net [get_bd_pins $rst_adc/peripheral_aresetn] $adc_reset

foreach tile {0 1 2 3} {
    disconnect_pin [get_bd_pins $rf/m${tile}_axis_aclk]
    connect_net [get_bd_pins $adc_wiz/clk_out1] [get_bd_pins $rf/m${tile}_axis_aclk]
    disconnect_pin [get_bd_pins $rf/m${tile}_axis_aresetn]
    connect_net [get_bd_pins $rst_adc/peripheral_aresetn] [get_bd_pins $rf/m${tile}_axis_aresetn]
    disconnect_pin [get_bd_pins $rf/s${tile}_axis_aclk]
    connect_net [get_bd_pins $dac_wiz/clk_out1] [get_bd_pins $rf/s${tile}_axis_aclk]
}

# Existing PS reset blocks are retained from the HWH structure.
set rf_reset [ensure_port rf_resetn O rst 0]
set host_reset [ensure_port host_resetn O rst 0]
set fclk [ensure_port fclk_100m O clk 100000000]
set_property CONFIG.FREQ_HZ 99999001 $fclk
connect_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] $fclk
connect_net [get_bd_pins rst_rf_clk/peripheral_aresetn] $rf_reset
connect_net [get_bd_pins rst_ps8_0_99M/peripheral_aresetn] $host_reset

# External AXIS metadata must follow the v2 fabric clocks and widths.
foreach lane {00 02 10 12 20 22 30 32} {
    set s_if [get_bd_intf_ports -quiet s${lane}_axis]
    set m_if [get_bd_intf_ports -quiet m${lane}_axis]
    if {[llength $s_if]} {
        set_property CONFIG.FREQ_HZ 612500000 $s_if
        set_property CONFIG.TDATA_NUM_BYTES 32 $s_if
    }
    if {[llength $m_if]} {
        set_property CONFIG.FREQ_HZ 416666666 $m_if
        set_property CONFIG.TDATA_NUM_BYTES 24 $m_if
    }
}

# The top-level SYSREF synchronizers are implemented in d0_probe_top.v.
if {![llength [get_bd_ports -quiet user_sysref_adc_0]]} {create_bd_port -dir I user_sysref_adc_0}
if {![llength [get_bd_ports -quiet user_sysref_dac_0]]} {create_bd_port -dir I user_sysref_dac_0}

validate_bd_design
save_bd_design
generate_target all [get_files -quiet */system.bd]
update_compile_order -fileset sources_1

set param_dump [file join $build_root bd_params_v2.txt]
set fd [open $param_dump w]
foreach instance {usp_rf_data_converter_0 clk_wiz_0 clk_wiz_adc zynq_ultra_ps_e_0 rst_adc_clk rst_rf_clk rst_ps8_0_99M} {
    set cell [get_bd_cells -quiet $instance]
    if {![llength $cell]} {continue}
    puts $fd "\[$instance\]"
    foreach prop [lsort [list_property $cell]] {
        if {[string match "CONFIG.*" $prop]} {
            set short [string range $prop 7 end]
            puts $fd "$short=[get_property $prop $cell]"
        }
    }
    puts $fd ""
}
close $fd

set published [file join $repo_root reports D0 published_bd_params.txt]
# Write the diff next to the parameter dump so callers never overwrite reports/D0.
set diff_file [file join [file dirname $param_dump] bd_param_diff.txt]
set compare [file join $repo_root scripts d0 compare_bd_params.py]
if {[file exists $published]} {
    set compare_cmd "\$env:PYTHONHOME=\$null; \$env:PYTHONPATH=\$null; py -X utf8 \"$compare\" --published \"$published\" --bd \"$param_dump\" --out \"$diff_file\""
    catch {exec powershell -NoProfile -Command $compare_cmd} compare_result
    puts $compare_result
}
puts "BD_V2_READY $project_dir"
puts "BD_PARAM_DUMP $param_dump"
puts "BD_PARAM_DIFF $diff_file"
puts "GENERATION_PATH_AUDIT $audit_file"
close_project
