set_param general.maxThreads 20
set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir .. ..]]
set checkpoint [file join $repo_root build D0R2_TIMING round_0_routed.dcp]
set reports_dir [file join $repo_root reports D0R2_TIMING]
if {![file exists $checkpoint]} {error "Missing routed checkpoint for XDC validation: $checkpoint"}
open_checkpoint $checkpoint
read_xdc [file join $repo_root constraints d0 d0_timing.xdc]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $reports_dir xdc_validation_timing_summary.rpt]
report_clock_interaction -delay_type min_max -file [file join $reports_dir xdc_validation_clock_interaction.rpt]
report_cdc -details -file [file join $reports_dir cdc_details.rpt]
close_design
puts "D0R2_XDC_VALIDATION_PASS checkpoint=$checkpoint"
