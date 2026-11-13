# QSFP2 pins for XCZU47DR-FSVE1156; pin map from qsfp2_udp_echo.xdc.
set_property PACKAGE_PIN H28 [get_ports qsfp2_refclk_p]
set_property PACKAGE_PIN H29 [get_ports qsfp2_refclk_n]

set_property PACKAGE_PIN E30 [get_ports {qsfp2_tx_p[0]}]
set_property PACKAGE_PIN E31 [get_ports {qsfp2_tx_n[0]}]
set_property PACKAGE_PIN D28 [get_ports {qsfp2_tx_p[1]}]
set_property PACKAGE_PIN D29 [get_ports {qsfp2_tx_n[1]}]
set_property PACKAGE_PIN C30 [get_ports {qsfp2_tx_p[2]}]
set_property PACKAGE_PIN C31 [get_ports {qsfp2_tx_n[2]}]
set_property PACKAGE_PIN B28 [get_ports {qsfp2_tx_p[3]}]
set_property PACKAGE_PIN B29 [get_ports {qsfp2_tx_n[3]}]

set_property PACKAGE_PIN F33 [get_ports {qsfp2_rx_p[0]}]
set_property PACKAGE_PIN F34 [get_ports {qsfp2_rx_n[0]}]
set_property PACKAGE_PIN D33 [get_ports {qsfp2_rx_p[1]}]
set_property PACKAGE_PIN D34 [get_ports {qsfp2_rx_n[1]}]
set_property PACKAGE_PIN B33 [get_ports {qsfp2_rx_p[2]}]
set_property PACKAGE_PIN B34 [get_ports {qsfp2_rx_n[2]}]
set_property PACKAGE_PIN A31 [get_ports {qsfp2_rx_p[3]}]
set_property PACKAGE_PIN A32 [get_ports {qsfp2_rx_n[3]}]

set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS18} [get_ports qsfp2_reset_n]
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33} [get_ports qsfp2_lpmode]
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS33} [get_ports qsfp2_modsel_n]

set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CFGBVS GND [current_design]

# The imported optical_port2 XCI contributes the 156.25 MHz refclk constraint.
# Do not duplicate it here; the IP constraint targets qsfp2_refclk_p directly.

# The MAC management restart synchronizer is tied inactive in awg_eth_core.
# xpm_cdc_async_rst provides the asynchronous assertion/synchronous release
# for clk_eth; no additional timing exception is required for that XPM.
