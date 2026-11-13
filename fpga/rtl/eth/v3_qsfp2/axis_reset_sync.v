`default_nettype none
`timescale 1ns/1ps
// Per-clock reset bridge: asynchronous assertion and synchronous release.
module axis_reset_sync #(
    parameter integer STAGES = 4
) (
    input  wire clk,
    input  wire arst,
    output wire srst
);
    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync_reg;

    always @(posedge clk or posedge arst) begin
        if (arst) begin
            sync_reg <= {STAGES{1'b1}};
        end else begin
            sync_reg <= {sync_reg[STAGES-2:0], 1'b0};
        end
    end

    assign srst = sync_reg[STAGES-1];
endmodule
`default_nettype wire
