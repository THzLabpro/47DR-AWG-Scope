set_param general.maxThreads 20
set root [file normalize [file join [file dirname [info script]] ../..]]
set checkpoint [file join $root build D3B0_REVIEW awg_eth_top.dcp]
set report_dir [file join $root reports D3B0_REVIEW]
file mkdir $report_dir

if {![file exists $checkpoint]} {error "Copied synth checkpoint is missing: $checkpoint"}
open_checkpoint $checkpoint

# Match the implementation run's OPT_DESIGN.TCL.PRE constraints.
source [file join $root constraints top cdc.tcl]

report_drc -file [file join $report_dir drc_synth.rpt]
report_methodology -file [file join $report_dir methodology_synth.rpt]
report_io -file [file join $report_dir io_synth.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $report_dir utilization_hier_synth.rpt]
report_utilization -file [file join $report_dir utilization_synth.rpt]
report_clocks -file [file join $report_dir clocks_synth.rpt]
report_exceptions -ignored -file [file join $report_dir exceptions_ignored_synth.rpt]
report_clock_interaction -delay_type min_max -file [file join $report_dir clock_interaction_synth.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $report_dir timing_summary_synth.rpt]
report_timing -delay_type max -max_paths 20 -path_type full_clock_expanded -input_pins -file [file join $report_dir worst_20_setup_synth.rpt]
report_high_fanout_nets -timing -max_nets 100 -file [file join $report_dir high_fanout_synth.rpt]
report_design_analysis -logic_level_distribution -logic_level_dist_paths 5000 -file [file join $report_dir logic_level_synth.rpt]
report_cdc -details -file [file join $report_dir cdc_synth.rpt]
report_power -file [file join $report_dir power_synth.rpt]

set fd [open [file join $report_dir netlist_probe.txt] w]
puts $fd "checkpoint=$checkpoint"
puts $fd "part=[get_property PART [current_design]]"
foreach port [get_ports -quiet] {
    puts $fd "PORT name=[get_property NAME $port] direction=[get_property DIRECTION $port] package_pin=[get_property -quiet PACKAGE_PIN $port] iostandard=[get_property -quiet IOSTANDARD $port]"
}
foreach clk [get_clocks -quiet] {
    puts $fd "CLOCK name=[get_property NAME $clk] period_ns=[get_property PERIOD $clk] waveform=[get_property WAVEFORM $clk] source_pins=[get_property -quiet SOURCE_PINS $clk]"
}
foreach pat {*tx_phase_tog_reg* *tog_q_reg* *first_half* *dac_tdata_reg_reg* *start_event* *crc*reg* *gray*reg* *capture_word_gray*} {
    set cells [get_cells -hierarchical -quiet $pat]
    puts $fd "CELL_PATTERN pattern=$pat count=[llength $cells]"
    foreach cell $cells {
        set clk_pins [get_pins -of_objects $cell -filter {REF_PIN_NAME == C || REF_PIN_NAME == CLK}]
        set clocks [get_clocks -quiet -of_objects $clk_pins]
        set outputs [get_pins -of_objects $cell -filter {DIRECTION == OUT}]
        foreach pin $outputs {
            set nets [get_nets -quiet -of_objects $pin]
            foreach net $nets {
                puts $fd "CELL_OUTPUT cell=$cell pin=$pin net=$net flat_pin_count=[get_property -quiet FLAT_PIN_COUNT $net] clocks=$clocks"
            }
        }
    }
}
set phase_cells [get_cells -hierarchical -quiet *tx_phase_tog_reg*]
set tog_cells [get_cells -hierarchical -quiet *tog_q_reg*]
set dac_cells [get_cells -hierarchical -quiet *dac_tdata_reg_reg*]
if {[llength $phase_cells] && [llength $dac_cells]} {
    puts $fd "PATH_TX_PHASE_TO_DAC"
    puts $fd [report_timing -from $phase_cells -to $dac_cells -max_paths 20 -path_type full_clock_expanded -input_pins -return_string]
}
if {[llength $tog_cells] && [llength $dac_cells]} {
    puts $fd "PATH_TOG_Q_TO_DAC"
    puts $fd [report_timing -from $tog_cells -to $dac_cells -max_paths 20 -path_type full_clock_expanded -input_pins -return_string]
}
close $fd

puts "D3B0_REVIEW_REPORTS_DONE checkpoint=$checkpoint reports=$report_dir"
close_design
