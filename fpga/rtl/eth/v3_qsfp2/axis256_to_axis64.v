`default_nettype none
`timescale 1ns/1ps
// Four-beat AXI-Stream downsizer for l_ethernet to udp_complete_64.
// Input words are little-endian byte lanes; output preserves lane order.
module axis256_to_axis64 (
    input  wire         clk,
    input  wire         rst,
    input  wire [255:0] s_tdata,
    input  wire [31:0]  s_tkeep,
    input  wire         s_tvalid,
    output wire         s_tready,
    input  wire         s_tlast,
    input  wire         s_tuser,
    output reg  [63:0]  m_tdata,
    output reg  [7:0]   m_tkeep,
    output reg          m_tvalid,
    input  wire         m_tready,
    output reg          m_tlast,
    output reg          m_tuser
);
    reg [255:0] data_reg;
    reg [31:0] keep_reg;
    reg [1:0]  beat_reg;
    reg        last_reg;
    reg        user_reg;
    wire       output_fire = m_tvalid && m_tready;
    wire       input_fire = s_tvalid && s_tready;
    assign s_tready = !m_tvalid || (output_fire && (beat_reg == 2'd3 || m_tlast));
    always @(*) begin
        m_tdata = data_reg[beat_reg*64 +: 64];
        m_tkeep = keep_reg[beat_reg*8 +: 8];
        m_tlast = 1'b0;
        if (last_reg) begin
            case (beat_reg)
                2'd0: m_tlast = (keep_reg[15:8] == 8'd0);
                2'd1: m_tlast = (keep_reg[23:16] == 8'd0);
                2'd2: m_tlast = (keep_reg[31:24] == 8'd0);
                default: m_tlast = 1'b1;
            endcase
        end
        // AXI tuser marks the frame termination only.  Propagating it onto
        // each of the four 64-bit fragments would make an errored MAC frame
        // look like four independent malformed fragments downstream.
        m_tuser = user_reg && m_tlast;
    end
    always @(posedge clk) begin
        if (rst) begin
            data_reg <= 256'd0;
            keep_reg <= 32'd0;
            beat_reg <= 2'd0;
            last_reg <= 1'b0;
            user_reg <= 1'b0;
            m_tvalid <= 1'b0;
        end else begin
            if (input_fire) begin
                data_reg <= s_tdata;
                keep_reg <= s_tkeep;
                beat_reg <= 2'd0;
                last_reg <= s_tlast;
                user_reg <= s_tuser;
                m_tvalid <= 1'b1;
            end else if (output_fire) begin
                if (beat_reg == 2'd3 || m_tlast) begin
                    m_tvalid <= 1'b0;
                    beat_reg <= 2'd0;
                end else begin
                    beat_reg <= beat_reg + 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
