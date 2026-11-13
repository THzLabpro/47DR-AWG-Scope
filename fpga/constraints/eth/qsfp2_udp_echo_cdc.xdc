# The generated L-Ethernet IP supplies the GT/PCS clock and reset constraints.
# The old v2 u_qsfp2_endpoint/u_protocol_reset hierarchy is absent in v3 and
# must not be referenced here; the remaining exception matches the v3 MAC.
set_false_path -from [get_clocks -quiet clk_out1_demo_management_clock] \
    -to [get_pins -hier -regexp {.*u_qsfp2_mac/restart_tx_rx_sync_0_reg\[0\]/D}]
