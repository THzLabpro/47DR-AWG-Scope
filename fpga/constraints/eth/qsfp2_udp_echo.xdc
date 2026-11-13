# XCZU47DR QSFP2 only. Differential pins are from the board schematic and
# the verified Base47drPrj_v2.1 iBERT reference.
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
