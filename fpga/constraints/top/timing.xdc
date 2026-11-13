# Board timing clocks are defined by d0_board.xdc and the imported IP XDCs.
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -hierarchical -quiet *pl_clk_raw*]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
