# D3B project-mode full-chip synthesis, implementation, bitstream and XSA.
set_param general.maxThreads 20

set script_dir [file normalize [file dirname [info script]]]
set root [file normalize [file join $script_dir .. ..]]
set build [file join $root build D3C_IMPL]
set project_build $build
set reports [file join $root reports D3C_IMPL]
set project_dir [file join $project_build vivado]
set project_file [file join $project_dir d0_clock_probe.xpr]
set part xczu47dr-fsve1156-2-i
set cdc_tcl [file join $root constraints top cdc.tcl]
# Stage-1 simulations are run and checked before this script is launched.
set DO_IMPLEMENTATION 1

file mkdir $build
file mkdir $reports

proc wait_for_vivado_slot {} {
    set count [string trim [exec powershell -NoProfile -Command {(Get-Process vivado -ErrorAction SilentlyContinue).Count}]]
    while {$count >= 3} {
        puts "VIVADO_SLOTS busy=$count; waiting 60 seconds"
        exec powershell -NoProfile -Command {Start-Sleep -Seconds 60}
        set count [string trim [exec powershell -NoProfile -Command {(Get-Process vivado -ErrorAction SilentlyContinue).Count}]]
    }
}

proc collect_hdl {dir} {
    set out {}
    foreach path [glob -nocomplain -directory $dir *] {
        set tail [string tolower [file tail $path]]
        if {[file isdirectory $path]} {
            if {$tail in {sim simulation test tests tb formal doc}} {continue}
            set out [concat $out [collect_hdl $path]]
        } elseif {[regexp {\.(v|sv|vhd|vhdl|vh)$} $path]} {
            lappend out $path
        }
    }
    return $out
}

# Build the BD/XPR only when this task's project-mode output does not exist.
if {![file exists $project_file]} {
    set create_system [file join $root scripts bd create_system_v2.tcl]
    if {![file exists $create_system]} {error "Missing BD builder: $create_system"}
    set saved_argv $argv
    set argv [list $project_build]
    uplevel #0 [list source $create_system]
    set argv $saved_argv
}
if {![file exists $project_file]} {error "Project creation did not produce $project_file"}
set generation_audit [file join $project_build generation_path_audit.txt]
if {![file exists $generation_audit]} {error "Missing generation path audit: $generation_audit"}
set fd [open $generation_audit r]
set generation_audit_text [read $fd]
close $fd
if {[regexp -nocase {rf_adda_loop\.gen} $generation_audit_text]} {
    error "Task generation path audit contains root output path"
}

open_project $project_file
set bd_file [file join $project_build bd_seed system.bd]
set bd [get_files -quiet $bd_file]
if {[llength $bd] != 1} {error "Expected one system.bd in task build, found [llength $bd]"}
open_bd_design $bd
generate_target all $bd
set wrapper_files [make_wrapper -files $bd -top]
if {![llength $wrapper_files]} {error "BD wrapper generation returned no files"}
add_files -norecurse $wrapper_files

set rtl_files [list \
    [file join $root rtl up_axi.v] \
    [file join $root rtl reset_sync.v] \
    [file join $root rtl user_control.v] \
    [file join $root rtl top awg_eth_top.v] \
    [file join $root rtl ctrl awg_control_v2.sv] \
    [file join $root rtl tx awg_tx.sv] \
    [file join $root rtl tx awg_tx_uram_block.sv] \
    [file join $root rtl rx awg_rx.sv] \
    [file join $root rtl eth awg_eth_bridge.sv] \
    [file join $root rtl eth axil_arb2.sv] \
    [file join $root rtl eth awg_udp_port.v] \
    [file join $root rtl eth awg_eth_frame_pad.v] \
    [file join $root rtl eth awg_eth_core.v] \
    [file join $root rtl eth v3_qsfp2 optical_port2_exdes.v]]
foreach path $rtl_files {
    if {![file exists $path]} {error "Missing required RTL source: $path"}
}

set vendor_root [file join $root rtl eth vendor verilog-ethernet]
set vendor_files [concat \
    [collect_hdl [file join $vendor_root lib]] \
    [collect_hdl [file join $vendor_root rtl]]]
set qsfp_files [glob -nocomplain -types f [file join $root rtl eth v3_qsfp2 *.v]]
set all_sources {}
foreach path [concat $rtl_files $qsfp_files $vendor_files] {
    if {[lsearch -exact $all_sources $path] < 0} {lappend all_sources $path}
}
add_files -norecurse $all_sources

# Import the E2 optical IP and create the JTAG AXI IP used by the top.
set e2_xci_files [concat \
    [glob -nocomplain -types f [file join $root build E2 ip_staging *.xci]] \
    [glob -nocomplain -types f [file join $root build E2 vivado_ooc awg_eth_core_ooc.srcs sources_1 ip optical_port1_clk_wiz_0 *.xci]]]
if {![llength $e2_xci_files]} {error "No E2 IP XCI files found under build/E2"}
foreach xci $e2_xci_files {
    set ip_name [file rootname [file tail $xci]]
    if {![llength [get_ips -quiet $ip_name]]} {import_ip -files $xci}
}
if {![llength [get_ips -quiet jtag_awg_axi]]} {
    create_ip -name jtag_axi -vendor xilinx.com -library ip -version 1.2 -module_name jtag_awg_axi
}
set_property -dict [list CONFIG.PROTOCOL 2 CONFIG.M_AXI_DATA_WIDTH 32] [get_ips jtag_awg_axi]
generate_target all [get_ips jtag_awg_axi]
foreach ip_name {optical_port2 demo_management_clock} {
    if {[llength [get_ips -quiet $ip_name]]} {generate_target all [get_ips $ip_name]}
}
if {[llength [get_ips -quiet optical_port1_clk_wiz_0]]} {
    generate_target all [get_ips optical_port1_clk_wiz_0]
}

set xdc_files [concat \
    [list [file join $root constraints d0 d0_board.xdc] \
          [file join $root constraints eth awg_eth_core.xdc]] \
    [glob -nocomplain -types f [file join $root constraints top *.xdc]]]
foreach path $xdc_files {
    if {![file exists $path]} {error "Missing required XDC: $path"}
}
add_files -fileset constrs_1 -norecurse $xdc_files
set timing_xdc [get_files -quiet [file join $root constraints top timing.xdc]]
if {[llength $timing_xdc]} {set_property PROCESSING_ORDER LATE $timing_xdc}
set debug_xdc [get_files -quiet [file join $root constraints top debug.xdc]]
if {[llength $debug_xdc] != 1} {error "constraints/top/debug.xdc missing from constrs_1"}
# dbg_hub is inserted by opt_design, so its constraints are implementation-only.
set_property USED_IN_SYNTHESIS false $debug_xdc
set_property USED_IN_IMPLEMENTATION true $debug_xdc
set_property top awg_eth_top [current_fileset]
update_compile_order -fileset sources_1

set synth_run [get_runs -quiet synth_1]
if {![llength $synth_run]} {error "Project is missing synth_1"}
set impl_run [get_runs -quiet impl_1]
if {![llength $impl_run]} {error "Project is missing impl_1"}
set_property STEPS.OPT_DESIGN.TCL.PRE $cdc_tcl $impl_run

set bd_dump [file join $project_build bd_params_v2.txt]
set bd_diff_source [file join $project_build bd_param_diff.txt]
set bd_diff_report [file join $reports bd_param_diff.txt]
if {![file exists $bd_dump] || ![file exists $bd_diff_source]} {
    error "BD parameter dump/diff missing from task build"
}
file copy -force $bd_diff_source $bd_diff_report
set fd [open $bd_diff_report r]
set bd_diff_text [read $fd]
close $fd
if {![regexp -nocase {unexpected[[:space:]_:=]+0} $bd_diff_text]} {
    error "BD parameter diff does not report unexpected=0"
}

# Reuse a current completed run; otherwise run the task's full synthesis.
set source_mtime 0
foreach path [concat $all_sources $wrapper_files $e2_xci_files $xdc_files [list $cdc_tcl]] {
    if {[file exists $path] && [file mtime $path] > $source_mtime} {
        set source_mtime [file mtime $path]
    }
}
set synth_dcp [file join $project_dir d0_clock_probe.runs synth_1 awg_eth_top.dcp]
set synth_status [get_property STATUS $synth_run]
set needs_synth [expr {![file exists $synth_dcp] || $source_mtime > [file mtime $synth_dcp] || ![string match "*Complete!*" $synth_status]}]
if {$needs_synth} {
    wait_for_vivado_slot
    reset_run synth_1
    launch_runs synth_1 -jobs 2
    wait_on_run synth_1
    set synth_status [get_property STATUS $synth_run]
}
puts "SYNTH_STATUS $synth_status"
set run_log [file join $project_dir d0_clock_probe.runs synth_1 runme.log]
if {[file exists $run_log]} {
    file copy -force $run_log [file join $reports synth_1_runme.log]
}
if {![string match "*Complete!*" $synth_status]} {error "synth_1 did not complete: $synth_status"}

if {![file exists $run_log]} {error "synth_1 runme.log missing"}
set fd [open $run_log r]
set run_log_text [read $fd]
close $fd
set synth_error_count [regexp -all {ERROR:} $run_log_text]
puts "SYNTH_ERROR_COUNT $synth_error_count"
if {$synth_error_count != 0} {error "synth_1 runme.log contains $synth_error_count ERROR entries"}
set synth_critical_warning_count [regexp -all -line -nocase {^CRITICAL WARNING:} $run_log_text]
puts "SYNTH_CRITICAL_WARNING_COUNT $synth_critical_warning_count"
if {$synth_critical_warning_count != 0} {error "synth_1 runme.log contains $synth_critical_warning_count CRITICAL WARNING entries"}

open_run synth_1
report_clocks -file [file join $reports clocks_pre_cdc_synth.rpt]
set eth_clock_probe [get_clocks -quiet -of_objects [get_pins -hierarchical -quiet *eth_core_i/clk_eth]]
set fd [open [file join $reports eth_clock_probe.txt] w]
puts $fd "eth_clock_pin_count=[llength [get_pins -hierarchical -quiet *eth_core_i/clk_eth]]"
puts $fd "eth_clock_objects=$eth_clock_probe"
close $fd
source $cdc_tcl
set fd [open [file join $reports cdc_match_counts.txt] w]
foreach item $d3a6_cdc_matches {
    lassign $item name count
    puts $fd "CDC_MATCH name=$name count=$count"
    if {$count <= 0} {close $fd; error "CDC constraint $name matched no objects"}
}
close $fd

set fd [open [file join $reports xdc_inventory.txt] w]
foreach xdc [get_files -all -filter {FILE_TYPE == XDC}] {
    puts $fd "$xdc used_in_synthesis=[get_property -quiet USED_IN_SYNTHESIS $xdc] enabled=[get_property -quiet IS_ENABLED $xdc]"
}
close $fd

report_utilization -file [file join $reports utilization_synth.rpt]
report_ram_utilization -file [file join $reports ram_utilization_synth.rpt]
report_clocks -file [file join $reports clocks_synth.rpt]
report_timing -delay_type max -max_paths 40 -from $eth_rx_clocks -to $eth_tx_clocks \
    -path_type full_clock_expanded -input_pins -file [file join $reports mac_rx_to_tx_paths.rpt]
report_timing -delay_type max -max_paths 40 -from $host_clocks -to $tx_clocks \
    -path_type full_clock_expanded -input_pins -file [file join $reports host_to_tx_paths.rpt]
report_timing -delay_type max -max_paths 40 -from $tx_clocks -to $host_clocks \
    -path_type full_clock_expanded -input_pins -file [file join $reports tx_to_host_paths.rpt]
report_exceptions -file [file join $reports exceptions_synth.rpt]
report_clock_interaction -file [file join $reports clock_interaction_synth.rpt]
check_timing -verbose -file [file join $reports check_timing_synth.rpt]
report_cdc -details -file [file join $reports cdc_synth.rpt]

proc classify_check_timing_section {report_file section_name output_file} {
    set fd [open $report_file r]
    set content [read $fd]
    close $fd
    set section_index -1
    set reported_count unknown
    set groups [dict create]
    set lines [split $content "\n"]
    for {set index 0} {$index < [llength $lines]} {incr index} {
        set line [lindex $lines $index]
        if {[regexp "checking ${section_name} \\(([0-9]+)\\)" $line -> reported_count]} {
            set section_index $index
        }
    }
    if {$section_index < 0} {error "check_timing section '$section_name' not found"}
    for {set index [expr {$section_index + 1}]} {$index < [llength $lines]} {incr index} {
        set endpoint [string trim [lindex $lines $index]]
        if {[regexp {^[0-9]+[.] checking } $endpoint]} {break}
        if {$endpoint eq "" || [string match "There are *" $endpoint] ||
            [string first / $endpoint] < 0} {
            continue
        }
        set parts [split $endpoint /]
        set group [join [lrange $parts 0 2] /]
        dict incr groups $group
    }
    set rows {}
    dict for {group count} $groups {lappend rows [list $group $count]}
    set rows [lsort -integer -decreasing -index 1 $rows]
    set fd [open $output_file w]
    puts $fd "CHECK_TIMING_SECTION name=$section_name total=$reported_count"
    foreach row [lrange $rows 0 9] {
        puts $fd "GROUP name=[lindex $row 0] count=[lindex $row 1]"
    }
    close $fd
}

classify_check_timing_section [file join $reports check_timing_synth.rpt] no_clock \
    [file join $reports check_timing_no_clock_groups.txt]
classify_check_timing_section [file join $reports check_timing_synth.rpt] unconstrained_internal_endpoints \
    [file join $reports check_timing_unconstrained_groups.txt]

set payload_cells [get_cells -quiet -hierarchical *payload_mem*]
set uram_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ URAM288*}]
set ramb36_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB36*}]
set ramb18_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB18*}]
set gty_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ GTYE4_CHANNEL*}]
set fd [open [file join $reports synthesized_memory_cells.txt] w]
puts $fd "payload_mem_cells=$payload_cells"
foreach cell $payload_cells {puts $fd "payload_mem_ref=$cell:[get_property REF_NAME $cell]"}
puts $fd "uram_count=[llength $uram_cells]"
puts $fd "ramb36_count=[llength $ramb36_cells]"
puts $fd "ramb18_count=[llength $ramb18_cells]"
puts $fd "gty_count=[llength $gty_cells]"
close $fd

# Phase-replica audit: replicated phase flops must survive synthesis (D3B0 S1/S2).
set fd [open [file join $reports phase_replica_audit.txt] w]
set replica_fail 0
foreach {pattern expected} {
    tx_i/*tx_phase_tog_r_reg* 8
    tx_i/*tog_q_reg* 32
    tx_i/*fh_q_reg* 32
    rx_i/*rx_phase_tog_r_reg* 8
    rx_i/*rtog_q_reg* 8
    rx_i/*ph_q_reg* 8
    rx_i/*adc_pair_valid_ch_reg* 8
} {
    # Generate-block replicas are named e.g. tx_i/dac_phase_replica[0].fh_q_reg[0].
    set cells [get_cells -quiet -hierarchical -filter "NAME =~ $pattern && IS_PRIMITIVE"]
    puts $fd "REPLICA pattern=$pattern cells=[llength $cells] expected=$expected"
    if {[llength $cells] != $expected} {set replica_fail 1}
    set max_fo 0
    foreach cell $cells {
        set net [get_nets -quiet -of_objects [get_pins -quiet -of_objects $cell -filter {DIRECTION == OUT}]]
        set fo [expr {[get_property FLAT_PIN_COUNT $net] - 1}]
        if {$fo > $max_fo} {set max_fo $fo}
    }
    puts $fd "FANOUT pattern=$pattern max_fanout=$max_fo"
}
close $fd
if {$replica_fail} {error "Phase replica registers were merged; see phase_replica_audit.txt"}
close_design

if {!$DO_IMPLEMENTATION} {
    close_project
    puts "D3B_SYNTH_PASS status=$synth_status"
    return
}

# ---------------------------------------------------------------------------
# Implementation: up to three configurations, stop at the first timing-clean one.
# ---------------------------------------------------------------------------
proc configure_impl {impl_run cdc_tcl attempt} {
    switch -- $attempt {
        1 {
            set_property strategy Vivado\ Implementation\ Defaults $impl_run
            set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
            set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run
            set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
        }
        2 {
            set_property strategy Performance_ExplorePostRoutePhysOpt $impl_run
        }
        3 {
            set_property strategy Performance_ExtraTimingOpt $impl_run
            set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
        }
    }
    set_property STEPS.OPT_DESIGN.TCL.PRE $cdc_tcl $impl_run
}

set impl_pass 0
set impl_dir [file join $project_dir d0_clock_probe.runs impl_1]
for {set attempt 1} {$attempt <= 3 && !$impl_pass} {incr attempt} {
    configure_impl $impl_run $cdc_tcl $attempt
    reset_run impl_1
    wait_for_vivado_slot
    puts "IMPL_ATTEMPT $attempt strategy=[get_property STRATEGY $impl_run]"
    launch_runs impl_1 -to_step write_bitstream -jobs 2
    wait_on_run impl_1
    set impl_progress [get_property PROGRESS $impl_run]
    set impl_status [get_property STATUS $impl_run]
    puts "IMPL_RESULT attempt=$attempt progress=$impl_progress status=$impl_status"
    foreach logname {runme.log} {
        set src [file join $impl_dir $logname]
        if {[file exists $src]} {file copy -force $src [file join $reports impl_attempt${attempt}_$logname]}
    }
    if {$impl_progress ne "100%" || [string match -nocase "*ERROR*" $impl_status]} {
        error "impl_1 attempt $attempt failed: progress=$impl_progress status=$impl_status"
    }
    open_run impl_1
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    set unrouted [llength [get_nets -quiet -hierarchical -filter {ROUTE_STATUS == UNROUTED}]]
    puts "IMPL_TIMING attempt=$attempt wns=$wns whs=$whs unrouted=$unrouted"
    report_timing_summary -max_paths 20 -file [file join $reports impl_attempt${attempt}_timing_summary.rpt]
    if {$wns ne "" && $whs ne "" && $wns >= 0 && $whs >= 0 && $unrouted == 0} {
        set impl_pass 1
    } else {
        report_timing -max_paths 20 -nworst 1 -setup -file [file join $reports impl_attempt${attempt}_worst_setup.rpt]
        report_timing -max_paths 20 -nworst 1 -hold -file [file join $reports impl_attempt${attempt}_worst_hold.rpt]
        close_design
    }
}
if {!$impl_pass} {
    close_project
    error "D3C_IMPL_TIMING_FAIL: three implementation configurations did not close timing"
}

report_timing_summary -max_paths 20 -file [file join $reports timing_summary_routed.rpt]
report_route_status -file [file join $reports route_status.rpt]
report_drc -file [file join $reports drc_routed.rpt]
report_methodology -file [file join $reports methodology_routed.rpt]
report_power -file [file join $reports power_routed.rpt]
report_clock_utilization -file [file join $reports clock_utilization_routed.rpt]
report_clock_interaction -delay_type min_max -file [file join $reports clock_interaction_routed.rpt]
report_cdc -details -file [file join $reports cdc_routed.rpt]
report_utilization -file [file join $reports utilization_routed.rpt]
report_ram_utilization -file [file join $reports ram_utilization_routed.rpt]
set fd [open [file join $reports debug_hub_check.txt] w]
set hub [get_debug_cores -quiet dbg_hub]
puts $fd "dbg_hub=$hub"
if {[llength $hub]} {
    foreach prop {C_CLK_INPUT_FREQ_HZ C_ENABLE_CLK_DIVIDER C_USER_SCAN_CHAIN} {
        puts $fd "$prop=[get_property -quiet $prop $hub]"
    }
    puts $fd "clk_net=[get_nets -quiet -of_objects [get_pins -quiet dbg_hub/clk]]"
}
close $fd

set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
puts "ROUTED_DRC_ERRORS $drc_errors"

set bit_src [lindex [glob -nocomplain -directory $impl_dir *.bit] 0]
if {$bit_src eq ""} {error "Bitstream not found in $impl_dir"}
set bit_out [file join $build awg_eth_v2.bit]
file copy -force $bit_src $bit_out
set xsa_out [file join $build awg_eth_v2.xsa]
write_hw_platform -fixed -include_bit -force -file $xsa_out
# sha256 is appended by run_build_d3.ps1 (Windows PowerShell under Vivado lacks Get-FileHash).
set fd [open [file join $reports artifacts.txt] w]
foreach f [list $bit_out $xsa_out] {
    puts $fd "artifact=$f size=[file size $f]"
    puts "ARTIFACT $f size=[file size $f]"
}
close $fd

close_design
close_project
puts "D3C_IMPL_PASS synth=$synth_status attempts=[expr {$attempt - 1}] wns=$wns whs=$whs drc_errors=$drc_errors"
