`default_nettype none
`timescale 1ns/1ps

// =============================================================
// 模組：awg_eth_frame_pad
// 功能：將短 Ethernet frame 補至 64 bytes，長幀原樣通過
// 時鐘/復位：clk_eth，rst_eth 同步高有效
// 輸入/輸出：64-bit AXIS frame，支援 ready 反壓
// 關鍵參數：byte 計數飽和於 64，補零不進入 IP/UDP 長度欄位
// =============================================================
module awg_eth_frame_pad (
    input  wire        clk_eth,
    input  wire        rst_eth,
    input  wire [63:0] s_tdata,
    input  wire [7:0]  s_tkeep,
    input  wire        s_tvalid,
    output reg         s_tready,
    input  wire        s_tlast,
    input  wire        s_tuser,
    output reg  [63:0] m_tdata,
    output reg  [7:0]  m_tkeep,
    output reg         m_tvalid,
    input  wire        m_tready,
    output reg         m_tlast,
    output reg         m_tuser
);

    localparam [1:0] ST_FRAME = 2'd0;
    localparam [1:0] ST_TAIL  = 2'd1;
    localparam [1:0] ST_PAD   = 2'd2;
    localparam [6:0] MIN_FRAME_BYTES = 7'd64;

    reg [1:0] state_reg;
    reg [6:0] frame_bytes_reg;
    reg [63:0] tail_data_reg;
    reg [7:0] tail_keep_reg;
    reg tail_user_reg;
    reg [6:0] pad_remaining_reg;

    integer lane;
    integer tail_lane;
    reg [3:0] input_keep_count;
    reg [7:0] input_total;
    reg [6:0] input_total_capped;
    reg [3:0] tail_keep_count;
    reg [3:0] tail_pad_capacity;
    reg [3:0] tail_pad_fill;
    reg [7:0] tail_pad_keep;
    reg [6:0] tail_pad_remaining;
    reg [3:0] pad_beat_count;
    reg [7:0] pad_beat_keep;

    always @* begin
        input_keep_count = 4'd0;
        for (lane = 0; lane < 8; lane = lane + 1)
            input_keep_count = input_keep_count + s_tkeep[lane];
        input_total = {1'b0, frame_bytes_reg} + input_keep_count;
        input_total_capped = input_total >= MIN_FRAME_BYTES ?
            MIN_FRAME_BYTES : input_total[6:0];

        tail_keep_count = 4'd0;
        for (tail_lane = 0; tail_lane < 8; tail_lane = tail_lane + 1)
            tail_keep_count = tail_keep_count + tail_keep_reg[tail_lane];
        tail_pad_capacity = 4'd8 - tail_keep_count;
        tail_pad_fill = pad_remaining_reg < tail_pad_capacity ?
            pad_remaining_reg[3:0] : tail_pad_capacity;
        tail_pad_remaining = pad_remaining_reg - tail_pad_fill;
        tail_pad_keep = tail_pad_fill == 0 ? 8'd0 :
            (8'hff >> (8 - tail_pad_fill)) << tail_keep_count;

        pad_beat_count = pad_remaining_reg > 7'd8 ? 4'd8 : pad_remaining_reg[3:0];
        pad_beat_keep = pad_beat_count == 0 ? 8'd0 : 8'hff >> (8 - pad_beat_count);

        s_tready = 1'b0;
        m_tdata = 64'd0;
        m_tkeep = 8'd0;
        m_tvalid = 1'b0;
        m_tlast = 1'b0;
        m_tuser = 1'b0;

        case (state_reg)
            ST_FRAME: begin
                if (s_tlast) begin
                    s_tready = 1'b1;
                end else begin
                    s_tready = m_tready;
                    m_tdata = s_tdata;
                    m_tkeep = s_tkeep;
                    m_tvalid = s_tvalid;
                    m_tuser = s_tuser;
                end
            end
            ST_TAIL: begin
                m_tdata = tail_data_reg;
                m_tkeep = tail_keep_reg | tail_pad_keep;
                m_tvalid = 1'b1;
                m_tlast = (tail_pad_remaining == 0);
                m_tuser = m_tlast ? tail_user_reg : 1'b0;
            end
            ST_PAD: begin
                m_tkeep = pad_beat_keep;
                m_tvalid = 1'b1;
                m_tlast = (pad_remaining_reg <= 7'd8);
                m_tuser = m_tlast ? tail_user_reg : 1'b0;
            end
            default: begin
                s_tready = 1'b0;
            end
        endcase
    end

    always @(posedge clk_eth) begin
        if (rst_eth) begin
            state_reg <= ST_FRAME;
            frame_bytes_reg <= 7'd0;
            tail_data_reg <= 64'd0;
            tail_keep_reg <= 8'd0;
            tail_user_reg <= 1'b0;
            pad_remaining_reg <= 7'd0;
        end else begin
            case (state_reg)
                ST_FRAME: begin
                    if (s_tvalid && s_tready) begin
                        if (s_tlast) begin
                            tail_data_reg <= s_tdata;
                            tail_keep_reg <= s_tkeep;
                            tail_user_reg <= s_tuser;
                            pad_remaining_reg <= MIN_FRAME_BYTES - input_total_capped;
                            state_reg <= ST_TAIL;
                        end else if (input_total >= MIN_FRAME_BYTES) begin
                            frame_bytes_reg <= MIN_FRAME_BYTES;
                        end else begin
                            frame_bytes_reg <= input_total[6:0];
                        end
                    end
                end
                ST_TAIL: begin
                    if (m_tvalid && m_tready) begin
                        if (tail_pad_remaining == 0) begin
                            frame_bytes_reg <= 7'd0;
                            pad_remaining_reg <= 7'd0;
                            state_reg <= ST_FRAME;
                        end else begin
                            pad_remaining_reg <= tail_pad_remaining;
                            state_reg <= ST_PAD;
                        end
                    end
                end
                ST_PAD: begin
                    if (m_tvalid && m_tready) begin
                        if (pad_remaining_reg <= 7'd8) begin
                            frame_bytes_reg <= 7'd0;
                            pad_remaining_reg <= 7'd0;
                            state_reg <= ST_FRAME;
                        end else begin
                            pad_remaining_reg <= pad_remaining_reg - 7'd8;
                        end
                    end
                end
                default: begin
                    state_reg <= ST_FRAME;
                    frame_bytes_reg <= 7'd0;
                    pad_remaining_reg <= 7'd0;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
