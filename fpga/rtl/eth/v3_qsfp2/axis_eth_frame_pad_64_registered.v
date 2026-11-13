`default_nettype none
`timescale 1ns/1ps

// =============================================================
// 模块：axis_eth_frame_pad_64_registered
// 功能：只把短帧补至 60 B，完整保留长帧精确尾 keep；MAC 另加 FCS
// 时钟/复位：clk，rst 同步高有效
// 输入/输出：64 bit Ethernet AXIS，允许任意输出停顿
// 流水：先寄存尾拍，再计算所需补零；非尾拍每 clk 一字
// =============================================================
module axis_eth_frame_pad_64_registered #(
    parameter [15:0] MIN_FRAME_BYTES = 16'd60
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [63:0] s_tdata,
    input  wire [7:0]  s_tkeep,
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire        s_tlast,
    input  wire        s_tuser,
    output wire [63:0] m_tdata,
    output wire [7:0]  m_tkeep,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,
    output wire        m_tuser
);

    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_PASS = 2'd1;
    localparam [1:0] STATE_TAIL = 2'd2;
    localparam [1:0] STATE_PAD  = 2'd3;

    reg [1:0]  state_reg;
    reg [15:0] frame_bytes_reg;
    reg [63:0] tail_data_reg;
    reg [7:0]  tail_keep_reg;
    reg        tail_user_reg;
    reg [15:0] tail_total_reg;
    reg [15:0] pad_remaining_reg;
    reg [63:0] out_data_reg;
    reg [7:0]  out_keep_reg;
    reg        out_valid_reg;
    reg        out_last_reg;
    reg        out_user_reg;

    integer keep_bytes;
    integer aligned_total;
    integer first_pad_bytes;
    integer remaining_bytes;
    integer required_padding;
    integer pad_beat_bytes;
    integer lane;
    reg [63:0] padded_tail_data;
    reg [7:0] padded_tail_keep;
    reg [7:0] pad_beat_keep;

    function integer count_keep_bytes;
        input [7:0] keep;
        integer index;
        begin
            count_keep_bytes = 0;
            for (index = 0; index < 8; index = index + 1) begin
                count_keep_bytes = count_keep_bytes + keep[index];
            end
        end
    endfunction

    always @(*) begin
        keep_bytes = count_keep_bytes(tail_keep_reg);
        if (tail_total_reg < MIN_FRAME_BYTES) begin
            aligned_total = MIN_FRAME_BYTES;
        end else begin
            aligned_total = tail_total_reg;
        end

        required_padding = aligned_total - tail_total_reg;
        first_pad_bytes = 8 - keep_bytes;
        if (first_pad_bytes > required_padding) first_pad_bytes = required_padding;
        remaining_bytes = aligned_total - tail_total_reg - first_pad_bytes;

        padded_tail_data = tail_data_reg;
        padded_tail_keep = tail_keep_reg;
        for (lane = 0; lane < 8; lane = lane + 1) begin
            if (lane >= keep_bytes) begin
                padded_tail_data[lane*8 +: 8] = 8'd0;
            end
            if (lane < keep_bytes + first_pad_bytes) padded_tail_keep[lane] = 1'b1;
        end
        pad_beat_bytes = pad_remaining_reg > 16'd8 ? 8 : pad_remaining_reg;
        pad_beat_keep = 8'hff >> (8 - pad_beat_bytes);
    end

    assign s_tready = ((state_reg == STATE_IDLE) || (state_reg == STATE_PASS)) &&
        (!out_valid_reg || m_tready);
    assign m_tdata = out_data_reg;
    assign m_tkeep = out_keep_reg;
    assign m_tvalid = out_valid_reg;
    assign m_tlast = out_last_reg;
    assign m_tuser = out_user_reg;

    always @(posedge clk) begin
        if (rst) begin
            state_reg <= STATE_IDLE;
            frame_bytes_reg <= 16'd0;
            tail_data_reg <= 64'd0;
            tail_keep_reg <= 8'd0;
            tail_user_reg <= 1'b0;
            tail_total_reg <= 16'd0;
            pad_remaining_reg <= 16'd0;
            out_data_reg <= 64'd0;
            out_keep_reg <= 8'd0;
            out_valid_reg <= 1'b0;
            out_last_reg <= 1'b0;
            out_user_reg <= 1'b0;
        end else begin
            case (state_reg)
                STATE_IDLE, STATE_PASS: begin
                    if (s_tvalid && s_tready) begin
                        if (s_tlast) begin
                            tail_data_reg <= s_tdata;
                            tail_keep_reg <= s_tkeep;
                            tail_user_reg <= s_tuser;
                            tail_total_reg <= frame_bytes_reg + count_keep_bytes(s_tkeep);
                            state_reg <= STATE_TAIL;
                            out_valid_reg <= 1'b0;
                        end else begin
                            frame_bytes_reg <= frame_bytes_reg + count_keep_bytes(s_tkeep);
                            out_data_reg <= s_tdata;
                            out_keep_reg <= s_tkeep;
                            out_valid_reg <= 1'b1;
                            out_last_reg <= 1'b0;
                            out_user_reg <= s_tuser;
                            state_reg <= STATE_PASS;
                        end
                    end else if (out_valid_reg && m_tready) begin
                        out_valid_reg <= 1'b0;
                    end
                end
                STATE_TAIL: begin
                    if (!out_valid_reg || m_tready) begin
                        out_data_reg <= padded_tail_data;
                        out_keep_reg <= padded_tail_keep;
                        out_valid_reg <= 1'b1;
                        out_last_reg <= (remaining_bytes == 0);
                        out_user_reg <= (remaining_bytes == 0) ? tail_user_reg : 1'b0;
                        pad_remaining_reg <= remaining_bytes;
                        if (remaining_bytes == 0) begin
                            state_reg <= STATE_IDLE;
                            frame_bytes_reg <= 16'd0;
                        end else begin
                            state_reg <= STATE_PAD;
                        end
                    end
                end
                STATE_PAD: begin
                    if (!out_valid_reg || m_tready) begin
                        out_data_reg <= 64'd0;
                        out_keep_reg <= pad_beat_keep;
                        out_valid_reg <= 1'b1;
                        out_last_reg <= (pad_remaining_reg <= 16'd8);
                        out_user_reg <= (pad_remaining_reg <= 16'd8) ? tail_user_reg : 1'b0;
                        if (pad_remaining_reg <= 16'd8) begin
                            state_reg <= STATE_IDLE;
                            frame_bytes_reg <= 16'd0;
                            pad_remaining_reg <= 16'd0;
                        end else begin
                            pad_remaining_reg <= pad_remaining_reg - 16'd8;
                        end
                    end
                end
                default: begin
                    state_reg <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
