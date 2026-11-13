# D0R2 timing implementation. Run in the dedicated D0R2 build directory.
set_param general.maxThreads 20

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir .. ..]]
set build_root [expr {[llength $argv] ? [file normalize [lindex $argv 0]] : [file join $repo_root build D0R2_TIMING]}]
set reports_dir [file join $repo_root reports D0R2_TIMING]
set phase [expr {[llength $argv] > 1 ? [lindex $argv 1] : "full"}]
if {$phase ni {full default_only alternate_only}} {error "Unknown D0R2 phase: $phase"}
file mkdir $build_root
file mkdir $reports_dir

proc wait_for_vivado_slot {} {
    set count [string trim [exec powershell -NoProfile -Command {(Get-Process vivado -ErrorAction SilentlyContinue).Count}]]
    if {$count >= 3} {
        puts "VIVADO_SLOTS busy=$count; waiting in 60-second intervals"
        exec powershell -NoProfile -Command {while ((Get-Process vivado -ErrorAction SilentlyContinue).Count -ge 3) { Start-Sleep -Seconds 60 }}
    }
}

set project_file [file join $build_root vivado d0_clock_probe.xpr]
if {![file exists $project_file]} {
    error "D0R2 requires the validated D0 project copied into $build_root/vivado"
}

open_project $project_file
set_property top d0_probe_top [current_fileset]
update_compile_order -fileset sources_1

set synth_template [get_runs synth_1]
set synth_flow [get_property FLOW $synth_template]
set synth_strategy [get_property STRATEGY $synth_template]
set synth_run [get_runs -quiet synth_d0r2]
if {![llength $synth_run]} {
    create_run synth_d0r2 -flow $synth_flow -strategy $synth_strategy -constrset constrs_1
    set synth_run [get_runs synth_d0r2]
}
set_property STRATEGY "Vivado Synthesis Defaults" $synth_run
wait_for_vivado_slot
set synth_status [get_property STATUS $synth_run]
if {$phase ne "alternate_only"} {
    reset_run synth_d0r2
    launch_runs synth_d0r2 -jobs 8
    wait_on_run synth_d0r2
    set synth_status [get_property STATUS $synth_run]
} else {
    puts "D0R2_SYNTH_REUSE $synth_status"
}
puts "D0R2_SYNTH_STATUS $synth_status"
if {![string match "*Complete!*" $synth_status]} {
    error "D0R2 synthesis failed: $synth_status"
}

open_run synth_d0r2
foreach item {{host *system_i/fclk_100m} {dac *system_i/data_clk} {tx *tx_clk_div/O} {adc *system_i/adc_capture_clk} {rx *rx_clk_div/O} {pl *pl_clk_bufg/O}} {
    lassign $item label pin_pattern
    set pins [get_pins -hierarchical $pin_pattern]
    if {![llength $pins]} {error "D0R2_TIMING: missing $label clock source pin $pin_pattern"}
    set clocks [get_clocks -of_objects $pins]
    if {![llength $clocks]} {error "D0R2_TIMING: no $label clock on source pin $pins"}
    puts "D0R2_CLOCK_ASSERT_PASS label=$label pins=$pins clocks=$clocks"
}
foreach item {{sysref_source *pl_sysref_r_reg/Q} {sysref_dac_meta *sysref_dac_meta_reg/D} {sysref_adc_meta *sysref_adc_meta_reg/D}} {
    lassign $item label pin_pattern
    set pins [get_pins -hierarchical $pin_pattern]
    if {![llength $pins]} {error "D0R2_TIMING: missing $label pin $pin_pattern"}
}
report_utilization -hierarchical -file [file join $reports_dir utilization_synth.rpt]
report_cdc -file [file join $reports_dir cdc_synth.rpt]
close_design

set impl_template [get_runs impl_1]
set impl_flow [get_property FLOW $impl_template]
set impl_strategy [get_property STRATEGY $impl_template]
set impl_run [get_runs -quiet impl_d0r2]
if {![llength $impl_run]} {
    create_run impl_d0r2 -flow $impl_flow -strategy $impl_strategy -constrset constrs_1 -parent_run synth_d0r2
    set impl_run [get_runs impl_d0r2]
}
if {$phase ne "alternate_only"} {set_property STRATEGY "Vivado Implementation Defaults" $impl_run}
set best_slack -1.0e30
set best_round -1
set final_status "NOT_RUN"
set round 0
set round_limit 2
if {$phase eq "default_only"} {set round_limit 1}
if {$phase eq "alternate_only"} {
    set default_checkpoint [file join $build_root round_0_routed.dcp]
    if {![file exists $default_checkpoint]} {error "Missing default routed checkpoint: $default_checkpoint"}
    open_checkpoint $default_checkpoint
    set path [get_timing_paths -delay_type max -max_paths 1]
    if {![llength $path]} {error "Default routed checkpoint has no max-delay paths"}
    set best_slack [get_property SLACK [lindex $path 0]]
    set best_round 0
    set final_status "default_route_complete"
    close_design
    set round 1
}
while {$round < $round_limit} {
    if {$round == 0} {
        puts "D0R2_IMPL_ROUND 0 strategy=default"
    } else {
        set_property STRATEGY Performance_Explore $impl_run
        puts "D0R2_IMPL_ROUND 1 strategy=Performance_Explore"
    }
    wait_for_vivado_slot
    reset_run impl_d0r2
    launch_runs impl_d0r2 -to_step route_design -jobs 8
    wait_on_run impl_d0r2
    set final_status [get_property STATUS $impl_run]
    puts "D0R2_IMPL_STATUS round=$round status=$final_status"
    if {![string match "*route_design Complete*" $final_status]} {
        set fd [open [file join $reports_dir "round_${round}_failure.txt"] w]
        puts $fd "IMPLEMENTATION_FAIL round=$round status=$final_status"
        close $fd
        break
    }

    open_run impl_d0r2
    report_timing_summary -delay_type min_max -report_unconstrained -file [file join $reports_dir "round_${round}_timing_summary.rpt"]
    report_timing -delay_type max -max_paths 10 -path_type full_clock_expanded -file [file join $reports_dir "round_${round}_worst_paths_setup.rpt"]
    report_timing -delay_type min -max_paths 10 -path_type full_clock_expanded -file [file join $reports_dir "round_${round}_worst_paths_hold.rpt"]
    set path [get_timing_paths -delay_type max -max_paths 1]
    set slack [get_property SLACK [lindex $path 0]]
    puts "D0R2_ROUND_WNS round=$round wns=$slack"
    if {$slack > $best_slack} {
        set best_slack $slack
        set best_round $round
        write_checkpoint -force [file join $build_root "round_${round}_routed.dcp"]
    }
    close_design
    if {$slack >= 0.0} {break}
    incr round
}

if {$best_round < 0} {
    error "D0R2 implementation produced no routed checkpoint"
}
open_checkpoint [file join $build_root "round_${best_round}_routed.dcp"]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $reports_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 10 -path_type full_clock_expanded -file [file join $reports_dir worst_paths_setup.rpt]
report_timing -delay_type min -max_paths 10 -path_type full_clock_expanded -file [file join $reports_dir worst_paths_hold.rpt]
report_utilization -hierarchical -file [file join $reports_dir utilization.rpt]
report_clock_utilization -file [file join $reports_dir clock_utilization.rpt]
report_clock_interaction -delay_type min_max -file [file join $reports_dir clock_interaction.rpt]
check_timing -verbose -file [file join $reports_dir check_timing.rpt]
report_methodology -file [file join $reports_dir methodology.rpt]
report_cdc -file [file join $reports_dir cdc.rpt]
report_drc -file [file join $reports_dir drc.rpt]
report_route_status -file [file join $reports_dir route_status.rpt]
set util [report_utilization -return_string]
set uf [open [file join $reports_dir utilization_returned.txt] w]
puts $uf $util
close $uf
close_design
close_project

puts "D0R2_BUILD_COMPLETE best_round=$best_round best_wns=$best_slack implementation=$final_status reports=$reports_dir"
