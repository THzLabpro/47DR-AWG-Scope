# Lab adapter helper; never executed by client or by offline tests against hardware.
# xsdb rfudp_control.tcl <identity|stop_output|start_output|lms> <cable_serial> [2|6]
# Uses only the already running local hw_server. No reset/program commands.
if {[llength $argv] < 2} { error "mode and cable serial required" }
set mode [lindex $argv 0]
set serial [lindex $argv 1]
if {$mode ni {identity stop_output start_output lms}} { error "unsupported operation" }
if {![regexp {^[A-Za-z0-9_-]+$} $serial]} { error "invalid cable serial" }
if {$mode eq "lms"} {
    set value [lindex $argv 2]
    if {$value ni {2 6}} { error "LMS requires 2 or 6" }
}
connect -url tcp:127.0.0.1:3121
try {
    # Resolve the cable from explicit properties, as the vendor programming
    # wrapper does. XSDB filter matching can miss the serial just after connect.
    for {set attempt 0} {$attempt < 10} {incr attempt} {
        set matches {}
        foreach target [targets -target-properties] {
            if {[dict exists $target jtag_cable_serial] &&
                [dict get $target jtag_cable_serial] eq $serial &&
                [string equal -nocase [dict get $target name] "PSU"]} {
                lappend matches $target
            }
        }
        if {[llength $matches] > 0} break
        after 500
    }
    if {[llength $matches] != 1} { error "Expected one PSU on cable $serial; found [llength $matches]" }
    targets -set [dict get [lindex $matches 0] target_id]
    configparams force-mem-accesses 1
    proc rd {a} { return [lindex [mrd -force -value $a 1] 0] }
    set id [rd 0x80100000]
    if {$id != 0x56335246} { error "RFUDP ID mismatch" }
    if {$mode eq "identity"} {
        foreach {label address} {ID 0x80100000 VERSION 0x80100004 BUILD_ID 0x80100008 SRC_HASH 0x8010000C} {
            puts [format "%s=0x%08X" $label [rd $address]]
        }
        puts "IDENTITY_READ_PASS"
    } elseif {$mode eq "lms"} {
        mwr -force 0x80100010 $value
        set actual [rd 0x80100010]
        if {$actual != $value} { error "LMS readback mismatch" }
        puts [format "AFTER 0x%08X" $actual]
        puts "LMS_PASS $value"
    } elseif {$mode eq "start_output"} {
        mwr -force 0x80100010 [expr {[rd 0x80100010] | 2}]
        mwr -force 0x80100018 [expr {[rd 0x80100018] | 1}]
        if {![expr {[rd 0x80100010] & 2}] || ![expr {[rd 0x80100018] & 1}]} { error "TX enable readback failed" }
        puts "START_OUTPUT_REGISTERS_PASS"
    } else {
        # Stop business generator and PHY TX, preserving unrelated bits.
        set business [expr {[rd 0x80100018] & ~1}]
        mwr -force 0x80100018 $business
        set ctrl [expr {[rd 0x80100010] & ~2}]
        mwr -force 0x80100010 $ctrl
        if {([rd 0x80100018] & 1) || ([rd 0x80100010] & 2)} { error "TX disable readback failed" }
        puts "STOP_OUTPUT_REGISTERS_PASS"
        # This proves register readback only; RF output cessation needs bench acceptance.
    }
} finally {
    disconnect
}
