set_param general.maxThreads 20
set repo_root [file normalize [file join [file dirname [info script]] .. ..]]
set build_root [file normalize [lindex $argv 0]]
set project_file [file join $build_root vivado d0_clock_probe.xpr]
set reports_dir [file join $repo_root reports D0]
open_project $project_file
set routed_dcp [file join $build_root vivado d0_clock_probe.runs impl_1 d0_probe_top_routed.dcp]
open_checkpoint $routed_dcp

report_timing_summary -delay_type min_max -report_unconstrained -file [file join $reports_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 10 -file [file join $reports_dir worst_paths_setup.rpt]
report_timing -delay_type min -max_paths 10 -file [file join $reports_dir worst_paths_hold.rpt]
report_utilization -hierarchical -file [file join $reports_dir utilization.rpt]
report_clock_utilization -file [file join $reports_dir clock_utilization.rpt]
report_methodology -file [file join $reports_dir methodology.rpt]
report_cdc -file [file join $reports_dir cdc.rpt]
report_drc -file [file join $reports_dir drc.rpt]

set fd [open [file join $reports_dir clock_metrics.rpt] w]
puts $fd "# D0 final routed clock metrics"
foreach item {{dac_clk {clk_out1_system_clk_wiz_0_0} 612.5} {tx_clk {tx_clk} 306.25} {adc_clk {clk_out1_system_clk_wiz_adc_0} 416.667} {rx_clk {rx_clk} 208.333}} {
    lassign $item label names expected
    set clocks [get_clocks -quiet $names]
    puts $fd "clock=$label expected_MHz=$expected clocks=$clocks"
    foreach kind {max min} {
        set paths [get_timing_paths -quiet -delay_type $kind -max_paths 10000 -to $clocks]
        set wns 1.0e9
        set tns 0.0
        foreach path $paths {
            set slack [get_property SLACK $path]
            if {$slack < $wns} {set wns $slack}
            if {$slack < 0.0} {set tns [expr {$tns + $slack}]}
        }
        if {$wns == 1.0e9} {set wns NA; set tns NA}
        if {$kind eq "max"} {puts $fd "  WNS=$wns TNS=$tns"}
        if {$kind eq "min"} {puts $fd "  WHS=$wns THS=$tns"}
    }
}
close $fd

set util [report_utilization -return_string]
set uf [open [file join $reports_dir utilization_returned.txt] w]
puts $uf $util
close $uf

set status [open [file join $reports_dir status.json] w]
puts $status "{"
puts $status "  \"task\": \"D0_CLOCK_PROBE\","
puts $status "  \"status\": \"NEEDS_PARENT_JUDGMENT\","
puts $status "  \"synthesis\": \"synth_design Complete!\","
puts $status "  \"implementation\": \"route_design Complete!\","
puts $status "  \"timing\": \"FAIL\","
puts $status "  \"reason\": \"Post-route WNS is negative; see timing_summary.rpt and worst_paths_setup.rpt\""
puts $status "}"
close $status
close_project
puts "D0_FINALIZED $reports_dir"
