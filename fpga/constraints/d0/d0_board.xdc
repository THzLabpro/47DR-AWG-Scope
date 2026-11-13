# D0 board clocks and the two LEDs, matching the v1 board snapshot.
set_property PACKAGE_PIN E12 [get_ports pl_clk_p]
set_property PACKAGE_PIN D12 [get_ports pl_clk_n]
set_property IOSTANDARD LVPECL [get_ports {pl_clk_p pl_clk_n}]
set_property PACKAGE_PIN E14 [get_ports pl_sysref_p]
set_property PACKAGE_PIN D14 [get_ports pl_sysref_n]
set_property IOSTANDARD LVPECL [get_ports {pl_sysref_p pl_sysref_n}]
set_property PACKAGE_PIN B12 [get_ports {led[0]}]
set_property PACKAGE_PIN A12 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[0] led[1]}]

create_clock -name pl_clk_p -period 5.000 -waveform {0.000 2.500} [get_ports pl_clk_p]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -hierarchical -quiet *pl_clk_raw]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
