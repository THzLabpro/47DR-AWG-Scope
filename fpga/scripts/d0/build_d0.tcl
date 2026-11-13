# D0 complete build: extract XSA, reconstruct BD, synthesize, implement, report.

set_param general.maxThreads 20

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir .. ..]]
set build_root [expr {[llength $argv] ? [file normalize [lindex $argv 0]] : [file join $repo_root build D0]}]
set reports_dir [file join $repo_root reports D0]
file mkdir $build_root
file mkdir $reports_dir

proc wait_for_vivado_slot {} {
    set count [string trim [exec powershell -NoProfile -Command {(Get-Process vivado -ErrorAction SilentlyContinue).Count}]]
    if {$count >= 3} {
        puts "VIVADO_SLOTS busy=$count; waiting 60 seconds"
        exec powershell -NoProfile -Command {while ((Get-Process vivado -ErrorAction SilentlyContinue).Count -ge 3) { Start-Sleep -Seconds 60 }}
    }
}

set xsa [file normalize [file join $repo_root .. rf_awg_scope_v1 hardware dac9g_opt1 rf_awg_scope_v1.xsa]]
if {![file exists $xsa]} {error "Missing published XSA: $xsa"}
set extract_helper [file join $script_dir extract_hwh_params.py]
set published [file join $reports_dir published_bd_params.txt]
set xsa_extract [file join $build_root xsa]
set extract_cmd "\$env:PYTHONHOME=\$null; \$env:PYTHONPATH=\$null; py -X utf8 \"$extract_helper\" --xsa \"$xsa\" --extract-dir \"$xsa_extract\" --report \"$published\""
puts [exec powershell -NoProfile -Command $extract_cmd]

set project_file [file join $build_root vivado d0_clock_probe.xpr]
if {![file exists $project_file]} {
    # Rebuild the BD in the same Vivado process only for a clean build root.
    set create_script [file normalize [file join $repo_root scripts bd create_system_v2.tcl]]
    set saved_argv $argv
    set argv [list $build_root]
    source $create_script
    set argv $saved_argv
}
if {![file exists $project_file]} {error "BD reconstruction did not create $project_file"}
puts "OPEN_D0_PROJECT $project_file"
open_project $project_file

set top_file [file join $repo_root rtl d0 d0_probe_top.v]
set xdc_files [list [file join $repo_root constraints d0 d0_board.xdc] [file join $repo_root constraints d0 d0_timing.xdc]]
add_files -norecurse $top_file
add_files -fileset constrs_1 -norecurse $xdc_files
set_property top d0_probe_top [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset constrs_1

set synth_run [get_runs -quiet synth_1]
if {![llength $synth_run]} {error "synth_1 run missing"}
wait_for_vivado_slot
set synth_status [get_property STATUS $synth_run]
set synth_dcp [file join $build_root vivado d0_clock_probe.runs synth_1 d0_probe_top.dcp]
set source_mtime [file mtime $top_file]
foreach xdc $xdc_files {if {[file mtime $xdc] > $source_mtime} {set source_mtime [file mtime $xdc]}}
set needs_synth [expr {![file exists $synth_dcp] || $source_mtime > [file mtime $synth_dcp]}]
if {$needs_synth || ![string match "*Complete!*" $synth_status]} {
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    set synth_status [get_property STATUS $synth_run]
} else {
    puts "SYNTH_REUSE $synth_status"
}
puts "SYNTH_STATUS $synth_status"
if {![string match "*Complete!*" $synth_status]} {
    set fd [open [file join $reports_dir build_failure.txt] w]
    puts $fd "SYNTHESIS_FAIL $synth_status"
    close $fd
    close_project
    error "Synthesis failed: $synth_status"
}

open_run synth_1
report_utilization -hierarchical -file [file join $reports_dir utilization_synth.rpt]
report_cdc -file [file join $reports_dir cdc_synth.rpt]
close_design

set impl_run [get_runs -quiet impl_1]
if {![llength $impl_run]} {error "impl_1 run missing"}
set round 0
set converged 0
set worst_slack 0.0
while {$round <= 2} {
    if {$round == 0} {
        # Keep Vivado's default implementation strategy for the first pass.
        puts "IMPL_STRATEGY default"
    } elseif {$round == 1} {
        set_property STRATEGY Performance_Explore $impl_run
    } else {
        set_property STRATEGY Performance_Explore $impl_run
        set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
        set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $impl_run
    }
    wait_for_vivado_slot
    reset_run impl_1
    launch_runs impl_1 -to_step route_design -jobs 8
    wait_on_run impl_1
    set impl_status [get_property STATUS $impl_run]
    puts "IMPL_ROUND $round STATUS $impl_status"
    if {![string match "*Complete!*" $impl_status]} {
        set fd [open [file join $reports_dir "round_${round}_failure.txt"] w]
        puts $fd "IMPLEMENTATION_FAIL round=$round status=$impl_status"
        close $fd
        break
    }

    open_run impl_1
    set timing_file [file join $reports_dir "round_${round}_timing_summary.rpt"]
    report_timing_summary -delay_type min_max -report_unconstrained -file $timing_file
    set worst_path [get_timing_paths -quiet -delay_type max -max_paths 1]
    if {[llength $worst_path]} {set worst_slack [get_property SLACK [lindex $worst_path 0]]} else {set worst_slack 0.0}
    set worst_path_file [file join $reports_dir "round_${round}_worst_path.rpt"]
    report_timing -delay_type max -max_paths 10 -file $worst_path_file
    puts "IMPL_ROUND $round WNS $worst_slack"
    if {$worst_slack >= 0.0} {
        set converged 1
        break
    }
    close_design
    incr round
}

if {!$converged} {
    set fd [open [file join $reports_dir build_failure.txt] w]
    puts $fd "TIMING_NOT_CONVERGED rounds=$round worst_slack=$worst_slack"
    close $fd
    if {[llength [get_designs -quiet]]} {catch {close_design}}
    close_project
    error "Implementation completed without timing convergence"
}

# Final implementation reports.
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $reports_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $reports_dir utilization.rpt]
report_clock_utilization -file [file join $reports_dir clock_utilization.rpt]
report_methodology -file [file join $reports_dir methodology.rpt]
report_cdc -file [file join $reports_dir cdc.rpt]
report_drc -file [file join $reports_dir drc.rpt]

set metrics_file [file join $reports_dir clock_metrics.rpt]
set mf [open $metrics_file w]
puts $mf "# D0 clock metrics from final routed design"
foreach item {{dac_clk data_clk 612.5} {tx_clk tx_clk 306.25} {adc_clk adc_capture_clk 416.667} {rx_clk rx_clk 208.333}} {
    lassign $item label object expected
    set clocks [get_clocks -quiet $object]
    if {![llength $clocks] && $object in {data_clk adc_capture_clk}} {
        set clocks [get_clocks -quiet -of_objects [get_ports $object]]
    }
    puts $mf "clock=$label expected_MHz=$expected objects=$clocks"
    foreach kind {max min} {
        set paths [get_timing_paths -quiet -delay_type $kind -from $clocks -max_paths 10000]
        set min_slack 1.0e9
        set total_negative 0.0
        foreach path $paths {
            set slack [get_property SLACK $path]
            if {$slack < $min_slack} {set min_slack $slack}
            if {$slack < 0.0} {set total_negative [expr {$total_negative + $slack}]}
        }
        if {$min_slack == 1.0e9} {set min_slack NA; set total_negative NA}
        if {$kind eq "max"} {puts $mf "  WNS=$min_slack TNS=$total_negative"}
        if {$kind eq "min"} {puts $mf "  WHS=$min_slack THS=$total_negative"}
    }
}
close $mf

set util [report_utilization -return_string]
set uf [open [file join $reports_dir utilization_returned.txt] w]
puts $uf $util
close $uf

set status [open [file join $reports_dir status.json] w]
puts $status "{"
puts $status "  \"task\": \"D0_CLOCK_PROBE\","
puts $status "  \"status\": \"PASS\","
puts $status "  \"synthesis\": \"$synth_status\","
puts $status "  \"implementation\": \"[get_property STATUS $impl_run]\","
puts $status "  \"timing_round\": $round"
puts $status "}"
close $status

close_project
puts "D0_BUILD_PASS reports=$reports_dir"
