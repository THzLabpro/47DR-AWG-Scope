set_param general.maxThreads 20
set repo [lindex $argv 0]
set build [lindex $argv 1]
set reports [lindex $argv 2]
file mkdir $build/ooc $reports
set part xczu47dr-fsve1156-2-i

proc constrain_gray_bus {source_pattern sync_pattern max_delay skew label} {
    set source_cells [get_cells -hier -quiet -filter "NAME =~ $source_pattern"]
    set sync_cells [get_cells -hier -quiet -filter "NAME =~ $sync_pattern"]
    if {[llength $source_cells] == 0 || [llength $sync_cells] == 0} {
        puts "WARNING: CDC constraint endpoints missing for $label ($source_pattern -> $sync_pattern)"
        return 0
    }
    set_property ASYNC_REG TRUE $sync_cells
    set_max_delay -datapath_only $max_delay -from $source_cells -to $sync_cells
    set_bus_skew $skew -from $source_cells -to $sync_cells
    puts "CDC_CONSTRAINT crossing=$label max_delay_ns=$max_delay bus_skew_ns=$skew"
    return 1
}

proc run_ooc {repo build reports top name files clocks} {
    set proj_dir [file join $build ooc $name]
    create_project ${name}_proj $proj_dir -part $::part -force
    set_property target_language Verilog [current_project]
    foreach f $files {
        read_verilog -sv [file join $repo $f]
    }

    synth_design -top $top -part $::part -mode out_of_context -flatten_hierarchy none
    foreach c $clocks {
        set port [lindex $c 0]
        set period [lindex $c 1]
        set clock_port [get_ports -quiet $port]
        if {[llength $clock_port] != 1} {
            error "Expected one OOC clock port '$port' on $top"
        }
        create_clock -name ${top}_${port} -period $period $clock_port
    }

    set async_cells {}
    foreach pattern {*sync1_reg_reg* *sync2_reg_reg* *sync3_reg_reg* *sync4_reg_reg* *drop_gray_meta_reg*} {
        foreach c [get_cells -hier -quiet -filter "NAME =~ $pattern"] {
            lappend async_cells $c
        }
    }
    if {[llength $async_cells] > 0} {
        set_property ASYNC_REG TRUE $async_cells
    }
    if {$top eq "awg_eth_bridge"} {
        set rx_constraints 0
        foreach crossing {
            {u_rx_fifo *u_rx_fifo/rd_ptr_gray_reg_reg* *u_rx_fifo/rd_ptr_gray_sync1_reg_reg*}
            {u_tx_fifo *u_tx_fifo/rd_ptr_gray_reg_reg* *u_tx_fifo/rd_ptr_gray_sync1_reg_reg*}
        } {
            lassign $crossing label source_pattern sync_pattern
            incr rx_constraints [constrain_gray_bus $source_pattern $sync_pattern 3.2 0.5 $label]
        }
        if {$rx_constraints != 2} {
            puts "WARNING: Applied $rx_constraints of 2 instantiated FIFO Gray-pointer constraints"
        }
        constrain_gray_bus *rx_drop_gray_eth_reg* *drop_gray_meta_reg* 3.2 0.5 rx_drop_counter
    }

    report_utilization -file [file join $reports ${name}_synth_utilization.rpt]
    report_cdc -details -file [file join $reports ${name}_synth_cdc.rpt]
    opt_design
    place_design
    phys_opt_design
    route_design
    report_utilization -file [file join $reports ${name}_utilization.rpt]
    report_timing_summary -delay_type min_max -max_paths 20 -file [file join $reports ${name}_timing.rpt]
    report_timing -delay_type max -max_paths 20 -file [file join $reports ${name}_setup_paths.rpt]
    report_timing -delay_type min -max_paths 20 -file [file join $reports ${name}_hold_paths.rpt]
    report_cdc -details -file [file join $reports ${name}_cdc.rpt]
    report_clock_interaction -file [file join $reports ${name}_clock_interaction.rpt]
    write_checkpoint -force [file join $build ooc ${name}_routed.dcp]
    close_project
}

run_ooc $repo $build $reports awg_eth_bridge bridge {
    rtl/eth/vendor/verilog-ethernet/lib/axis/rtl/axis_async_fifo.v
    rtl/eth/awg_eth_bridge.sv
} {{clk_eth 3.2} {host_clk 10.0}}

run_ooc $repo $build $reports axil_arb2 arb {
    rtl/eth/axil_arb2.sv
} {{clk 10.0}}
