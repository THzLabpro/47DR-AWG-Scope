`default_nettype none
`timescale 1ns/1ps

// Pad an Ethernet AXI4-Stream frame to the MAC-safe 32-byte boundary.
// IPv4 and UDP lengths are not modified; the inserted zero bytes are Ethernet
// padding after the L3 payload.  The output has a full TKEEP on every beat.
module axis_eth_frame_align_pad_64 #(
    parameter [15:0] MIN_FRAME_BYTES = 16'd64
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [63:0]  s_tdata,
    input  wire [7:0]   s_tkeep,
    input  wire         s_tvalid,
    output wire         s_tready,
    input  wire         s_tlast,
    input  wire         s_tuser,
    output wire [63:0]  m_tdata,
    output wire [7:0]   m_tkeep,
    output wire         m_tvalid,
    input  wire         m_tready,
    output wire         m_tlast,
    output wire         m_tuser
);

    reg [63:0] out_data_reg;
    reg [7:0] out_keep_reg;
    reg out_valid_reg;
    reg out_last_reg;
    reg out_user_reg;
    reg pad_mode_reg;
    reg [15:0] frame_bytes_reg;
    reg [15:0] pad_remaining_reg;
    reg pad_user_reg;

    reg [3:0] input_byte_count;
    reg [15:0] frame_total_bytes;
    reg [15:0] minimum_total_bytes;
    reg [15:0] aligned_total_bytes;
    reg [15:0] padding_total_bytes;
    reg [15:0] padding_after_first_beat;
    reg [63:0] padded_input_data;
    integer lane;

    function [3:0] count_keep_bytes;
        input [7:0] keep;
        integer index;
        begin
            count_keep_bytes = 4'd0;
            for (index = 0; index < 8; index = index + 1) begin
                count_keep_bytes = count_keep_bytes + keep[index];
            end
        end
    endfunction

    always @(*) begin
        input_byte_count = count_keep_bytes(s_tkeep);
        frame_total_bytes = frame_bytes_reg + input_byte_count;
        if (frame_total_bytes < MIN_FRAME_BYTES) begin
            minimum_total_bytes = MIN_FRAME_BYTES;
        end else begin
            minimum_total_bytes = frame_total_bytes;
        end

        // The 40GbE MAC is driven only with complete 256-bit words.  The
        // minimum is also a multiple of 32, so this remains a byte-aligned
        // and synthesizable add-and-mask operation.
        aligned_total_bytes = (minimum_total_bytes + 16'd31) & 16'hffe0;
        padding_total_bytes = aligned_total_bytes - frame_total_bytes;
        padding_after_first_beat = padding_total_bytes -
            (16'd8 - input_byte_count);

        padded_input_data = s_tdata;
        for (lane = 0; lane < 8; lane = lane + 1) begin
            if (lane >= input_byte_count) begin
                padded_input_data[lane*8 +: 8] = 8'd0;
            end
        end
    end

    assign s_tready = !pad_mode_reg && (!out_valid_reg || m_tready);
    assign m_tdata = out_data_reg;
    assign m_tkeep = out_keep_reg;
    assign m_tvalid = out_valid_reg;
    assign m_tlast = out_last_reg;
    assign m_tuser = out_user_reg;

    always @(posedge clk) begin
        if (rst) begin
            out_data_reg <= 64'd0;
            out_keep_reg <= 8'd0;
            out_valid_reg <= 1'b0;
            out_last_reg <= 1'b0;
            out_user_reg <= 1'b0;
            pad_mode_reg <= 1'b0;
            frame_bytes_reg <= 16'd0;
            pad_remaining_reg <= 16'd0;
            pad_user_reg <= 1'b0;
        end else if (pad_mode_reg) begin
            if (!out_valid_reg || m_tready) begin
                out_data_reg <= 64'd0;
                out_keep_reg <= 8'hff;
                out_valid_reg <= 1'b1;
                out_last_reg <= (pad_remaining_reg == 16'd8);
                out_user_reg <= (pad_remaining_reg == 16'd8) ? pad_user_reg : 1'b0;
                if (pad_remaining_reg == 16'd8) begin
                    pad_mode_reg <= 1'b0;
                    pad_remaining_reg <= 16'd0;
                    pad_user_reg <= 1'b0;
                end else begin
                    pad_remaining_reg <= pad_remaining_reg - 16'd8;
                end
            end
        end else if (s_tvalid && s_tready) begin
            out_valid_reg <= 1'b1;
            if (s_tlast) begin
                frame_bytes_reg <= 16'd0;
                if (padding_total_bytes == 16'd0) begin
                    out_data_reg <= s_tdata;
                    out_keep_reg <= s_tkeep;
                    out_last_reg <= 1'b1;
                    out_user_reg <= s_tuser;
                    pad_mode_reg <= 1'b0;
                    pad_remaining_reg <= 16'd0;
                    pad_user_reg <= 1'b0;
                end else begin
                    out_data_reg <= padded_input_data;
                    out_keep_reg <= 8'hff;
                    out_last_reg <= (padding_after_first_beat == 16'd0);
                    out_user_reg <= (padding_after_first_beat == 16'd0) ? s_tuser : 1'b0;
                    pad_mode_reg <= (padding_after_first_beat != 16'd0);
                    pad_remaining_reg <= padding_after_first_beat;
                    pad_user_reg <= s_tuser;
                end
            end else begin
                out_data_reg <= s_tdata;
                out_keep_reg <= s_tkeep;
                out_last_reg <= 1'b0;
                out_user_reg <= s_tuser;
                frame_bytes_reg <= frame_total_bytes;
            end
        end else if (out_valid_reg && m_tready) begin
            out_valid_reg <= 1'b0;
        end
    end

endmodule

`default_nettype wire
