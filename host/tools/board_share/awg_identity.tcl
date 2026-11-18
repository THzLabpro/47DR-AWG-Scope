# Read-only F3 identity/ready probe, run only by the owning service worker.
if {[llength $argv] != 1} {error "Cable serial required"}
set serial [lindex $argv 0]
if {![regexp {^[A-Za-z0-9_-]+$} $serial]} {error "Invalid cable serial"}
open_hw_manager
try {
    connect_hw_server -url localhost:3121
    set matches {}
    foreach target [get_hw_targets -quiet] {
        if {[lindex [split $target /] end] eq $serial} {lappend matches $target}
    }
    if {[llength $matches] != 1} {error "Expected one matching JTAG cable"}
    open_hw_target [lindex $matches 0]
    set devices [get_hw_devices -quiet -filter {PART =~ *zu47dr*}]
    if {[llength $devices] != 1} {error "Expected one 47DR on selected cable"}
    current_hw_device [lindex $devices 0]
    refresh_hw_device [lindex $devices 0]
    set axes [get_hw_axis -quiet]
    if {[llength $axes] != 1} {error "Expected one JTAG AXI core"}
    proc rd {address} {
        global axes
        set tx [create_hw_axi_txn probe_$address [lindex $axes 0] -type read -address $address -len 1]
        try {
            run_hw_axi $tx
            set data [get_property DATA $tx]
            if {![regexp {^[0-9a-fA-F]{8}$} $data]} {error "Invalid JTAG data"}
            puts "REG $address $data"
            return [expr 0x$data]
        } finally {delete_hw_axi_txn $tx}
    }
    foreach {address expected} {90200000 0x41574732 90200020 0x00050000 90200054 0xD4B02026 90200014 9800000 90200018 5000000 9020001c 0} {
        if {[rd $address] != $expected} {error "F3 identity/fault mismatch at $address"}
    }
    set status [rd 90200004]
    if {($status & 15) != 4 || ($status & 64)} {error "F3 not ready, busy, faulted or playing"}
    puts "AWG_F3_JTAG_READY"
} finally {
    catch {close_hw_target}
    catch {disconnect_hw_server}
    catch {close_hw_manager}
}
exit
