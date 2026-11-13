set_param general.maxThreads 20

set project_root [file normalize [file join [file dirname [info script]] .. ..]]
set build_root [file normalize [file dirname [info script]]]
set project_dir [file join $build_root vivado_ooc]
set part_name xczu47dr-fsve1156-2-i

create_project -force awg_eth_core_ooc $project_dir -part $part_name
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set source_files [list \
    [file join $project_root rtl eth vendor verilog-ethernet lib axis rtl priority_encoder.v] \
    [file join $project_root rtl eth vendor verilog-ethernet lib axis rtl arbiter.v] \
    [file join $project_root rtl eth vendor verilog-ethernet lib axis rtl axis_fifo.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl lfsr.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl eth_axis_rx.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl eth_axis_tx.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl ip_eth_rx_64.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl ip_eth_tx_64.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl ip_64.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl ip_arb_mux.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl eth_arb_mux.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl arp_eth_rx.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl arp_eth_tx.v] \
    [file join $project_root rtl eth vendor verilog-ethernet rtl arp_cache.v] \
    [file join $project_root rtl eth v3_qsfp2 optical_port2_exdes.v] \
    [file join $project_root rtl eth v3_qsfp2 axis256_to_axis64.v] \
    [file join $project_root rtl eth v3_qsfp2 axis64_to_axis256.v] \
    [file join $project_root rtl eth awg_eth_frame_pad.v] \
    [file join $project_root rtl eth v3_qsfp2 udp_ip_rx_64.v] \
    [file join $project_root rtl eth v3_qsfp2 udp_ip_tx_64.v] \
    [file join $project_root rtl eth v3_qsfp2 udp_checksum_gen_64.v] \
    [file join $project_root rtl eth v3_qsfp2 udp_64.v] \
    [file join $project_root rtl eth v3_qsfp2 arp.v] \
    [file join $project_root rtl eth v3_qsfp2 ip_complete_64.v] \
    [file join $project_root rtl eth v3_qsfp2 udp_complete_64.v] \
    [file join $project_root rtl eth awg_udp_port.v] \
    [file join $project_root rtl eth awg_eth_core.v] \
]
add_files -norecurse $source_files
foreach ip_name {optical_port2 demo_management_clock optical_port1_clk_wiz_0} {
    set source_xci [file join $project_root ip eth $ip_name $ip_name.xci]
    import_ip -files $source_xci
}
add_files -fileset constrs_1 -norecurse [file join $project_root constraints eth awg_eth_core.xdc]
set_property top awg_eth_core [current_fileset]
update_compile_order -fileset sources_1

generate_target all [get_ips]
update_compile_order -fileset sources_1

# Add generated IP HDL to the synthesis fileset; import_ip keeps the XCI
# copies and their generated products under this temporary project.
proc collect_ip_hdl {directory} {
    set paths {}
    foreach path [glob -nocomplain -directory $directory *] {
        if {[file isdirectory $path]} {
            set paths [concat $paths [collect_ip_hdl $path]]
        } elseif {[regexp {\.(v|sv|vhd|vhdl)$} $path]} {
            lappend paths $path
        }
    }
    return $paths
}
set ip_output_dir [file join $project_dir awg_eth_core_ooc.gen sources_1 ip]
set generated_ip_hdl [collect_ip_hdl $ip_output_dir]
if {[llength $generated_ip_hdl] == 0} {
    error "No generated HDL found under $ip_output_dir"
}
add_files -norecurse $generated_ip_hdl
update_compile_order -fileset sources_1

synth_design -top awg_eth_core -part $part_name -flatten_hierarchy rebuilt
report_utilization -file [file join $build_root utilization.rpt]
report_timing_summary -delay_type max -report_unconstrained -file [file join $build_root timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $build_root timing_paths.rpt]

set gt_cells [get_cells -hier -quiet -filter {REF_NAME =~ GTYE4_CHANNEL* || REF_NAME =~ GTYE4_COMMON*}]
set gt_report [open [file join $build_root gt_locations.rpt] w]
puts $gt_report "Optical-port IP GT_GROUP_SELECT: [get_property CONFIG.GT_GROUP_SELECT [get_ips optical_port2]]"
puts $gt_report "GT primitive cells: [llength $gt_cells]"
foreach cell $gt_cells {
    puts $gt_report "$cell LOC=[get_property LOC $cell] REF_NAME=[get_property REF_NAME $cell]"
}
close $gt_report

puts "E2 OOC synthesis completed for $part_name"
