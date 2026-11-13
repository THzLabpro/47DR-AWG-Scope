`default_nettype none
`timescale 1ns/1ps

module awg_tx_uram_block #(
    parameter integer ADDR_BITS = 12,
    parameter integer DATA_BITS = 72
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire [ADDR_BITS-1:0]  wr_addr,
    input  wire [DATA_BITS-1:0]  wr_data,
    input  wire                  rd_en,
    input  wire [ADDR_BITS-1:0]  rd_addr,
    output wire [DATA_BITS-1:0]  rd_data
);
    localparam integer DEPTH = (1 << ADDR_BITS);

    wire dbiterr_unused;
    wire sbiterr_unused;

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_BITS),
        .ADDR_WIDTH_B(ADDR_BITS),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(DATA_BITS),
        .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("ultra"),
        .MEMORY_SIZE(DATA_BITS*DEPTH),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(DATA_BITS),
        .READ_LATENCY_B(3),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("ASYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(DATA_BITS),
        .WRITE_MODE_B("read_first")
    ) memory_i (
        .clka(clk),
        .clkb(clk),
        .ena(1'b1),
        .enb(rd_en),
        .wea(wr_en),
        .addra(wr_addr),
        .addrb(rd_addr),
        .dina(wr_data),
        .doutb(rd_data),
        .regceb(1'b1),
        .rstb(1'b0),
        .sleep(1'b0),
        .injectdbiterra(1'b0),
        .injectsbiterra(1'b0),
        .dbiterrb(dbiterr_unused),
        .sbiterrb(sbiterr_unused)
    );
endmodule

`default_nettype wire
