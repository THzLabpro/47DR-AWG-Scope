# Source-pin clock lookup and non-empty assertions are performed by the
# D0R2 build Tcl. Keep this XDC within Vivado's timing-constraint command set.
set host_pins [get_pins -hierarchical *system_i/fclk_100m]
set host_clks [get_clocks -of_objects $host_pins]

set dac_pins [get_pins -hierarchical *system_i/data_clk]
set dac_clks [get_clocks -of_objects $dac_pins]

set tx_pins [get_pins -hierarchical *tx_clk_div/O]
set tx_clks [get_clocks -of_objects $tx_pins]

set adc_pins [get_pins -hierarchical *system_i/adc_capture_clk]
set adc_clks [get_clocks -of_objects $adc_pins]

set rx_pins [get_pins -hierarchical *rx_clk_div/O]
set rx_clks [get_clocks -of_objects $rx_pins]

set pl_pins [get_pins -hierarchical *pl_clk_bufg/O]
set pl_clks [get_clocks -of_objects $pl_pins]

# Keep all RF clocks in one group so divided 2:1 clocks remain synchronous.
set rf_pins [get_pins -hierarchical -filter {NAME =~ *system_i/data_clk || NAME =~ *tx_clk_div/O || NAME =~ *system_i/adc_capture_clk || NAME =~ *rx_clk_div/O}]
set rf_clks [get_clocks -of_objects $rf_pins]
set_clock_groups -asynchronous -group $host_clks -group $rf_clks

# Constrain only the first SYSREF synchronizer stage by its destination period.
set sysref_source_cell [get_cells -hierarchical *pl_sysref_r_reg]
set sysref_dac_meta_cell [get_cells -hierarchical *sysref_dac_meta_reg]
set sysref_adc_meta_cell [get_cells -hierarchical *sysref_adc_meta_reg]
set_max_delay -datapath_only [get_property PERIOD $dac_clks] -from $sysref_source_cell -to $sysref_dac_meta_cell
set_max_delay -datapath_only [get_property PERIOD $adc_clks] -from $sysref_source_cell -to $sysref_adc_meta_cell
