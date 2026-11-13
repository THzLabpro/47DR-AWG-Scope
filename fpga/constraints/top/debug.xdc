# JTAG fallback debug hub: same settings as the on-board rf_awg_scope_v1 build.
# dbg_hub exists only after opt_design inserts it: implementation-only file.
set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets fclk_100m]
