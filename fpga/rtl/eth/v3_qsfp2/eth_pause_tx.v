`default_nettype none
`timescale 1ns/1ps

// =============================================================
// 模块：eth_pause_tx
// 功能：在 256 bit 数据帧边界优先插入 802.3x PAUSE，MAC 另加 FCS
// 时钟/复位：clk，rst 同步高有效；clear_stats 仅清统计
// 输入：pause_req、ctrl_pause_disable、TX FRAME_FIFO 的 AXIS
// 输出：60 B PAUSE / 原数据帧；计数只在 PAUSE last fire 时更新
// 关键参数：LOCAL_MAC，REFRESH_CYCLES=80000（312.5 MHz 下 256 us）
// 契约：首次呈现 valid 即锁定发送者/字段，直到 last fire
// =============================================================
module eth_pause_tx #(
    parameter [47:0] LOCAL_MAC = 48'h024741000002,
    parameter integer REFRESH_CYCLES = 80000
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         pause_req,
    input  wire         ctrl_pause_disable,
    input  wire         clear_stats,
    input  wire [255:0] s_axis_tdata,
    input  wire [31:0]  s_axis_tkeep,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tuser,
    output reg  [255:0] m_axis_tdata,
    output reg  [31:0]  m_axis_tkeep,
    output reg          m_axis_tvalid,
    input  wire         m_axis_tready,
    output reg          m_axis_tlast,
    output reg          m_axis_tuser,
    output reg  [31:0]  pause_xoff_frames,
    output reg  [31:0]  pause_xon_frames,
    output wire [1:0]   dbg_state
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_DATA = 2'd1;
    localparam [1:0] ST_PAUSE_FIRST = 2'd2;
    localparam [1:0] ST_PAUSE_LAST = 2'd3;
    localparam integer TIMER_WIDTH = $clog2(REFRESH_CYCLES + 1);
    localparam [31:0] FIRST_KEEP = 32'hffffffff;
    localparam [31:0] LAST_KEEP = 32'h0fffffff;
    reg [1:0] state;
    reg active_xoff;
    reg remote_paused;
    reg [TIMER_WIDTH-1:0] refresh_age;
    wire effective_request;
    wire refresh_due;
    wire pause_needed;
    wire select_pause;
    wire select_data;
    wire selected_xoff;
    wire output_fire;
    reg [255:0] pause_header;
    integer mac_byte;

    assign effective_request = pause_req && !ctrl_pause_disable;
    assign refresh_due = refresh_age == REFRESH_CYCLES-1;
    // 尚未呈现的请求直接由当前压力推导；反转时没有过期 XOFF 排队。
    // 已呈现的 XOFF 必须遵守 AXIS 稳定契约，完成后补 XON。
    assign pause_needed = effective_request ? (!remote_paused || refresh_due) : remote_paused;
    assign select_pause = state == ST_PAUSE_FIRST || state == ST_PAUSE_LAST ||
                          (state == ST_IDLE && pause_needed);
    assign select_data = state == ST_DATA || (state == ST_IDLE && !pause_needed);
    assign selected_xoff = state == ST_IDLE ? effective_request : active_xoff;
    assign s_axis_tready = select_data && m_axis_tready && !rst;
    assign output_fire = m_axis_tvalid && m_axis_tready;
    assign dbg_state = state;

    always @* begin
        pause_header = 256'd0;
        pause_header[47:0] = 48'h010000c28001;
        for (mac_byte = 0; mac_byte < 6; mac_byte = mac_byte + 1)
            pause_header[(mac_byte+6)*8 +: 8] = LOCAL_MAC[47-mac_byte*8 -: 8];
        pause_header[12*8 +: 16] = 16'h0888;
        pause_header[14*8 +: 16] = 16'h0100;
        pause_header[16*8 +: 16] = selected_xoff ? 16'hffff : 16'h0000;
        m_axis_tdata = s_axis_tdata;
        m_axis_tkeep = s_axis_tkeep;
        m_axis_tvalid = s_axis_tvalid && !rst;
        m_axis_tlast = s_axis_tlast;
        m_axis_tuser = s_axis_tuser;
        if (select_pause) begin
            m_axis_tdata = state == ST_PAUSE_LAST ? 256'd0 : pause_header;
            m_axis_tkeep = state == ST_PAUSE_LAST ? LAST_KEEP : FIRST_KEEP;
            m_axis_tvalid = !rst;
            m_axis_tlast = state == ST_PAUSE_LAST;
            m_axis_tuser = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            active_xoff <= 1'b0;
            remote_paused <= 1'b0;
            refresh_age <= {TIMER_WIDTH{1'b0}};
            pause_xoff_frames <= 32'd0;
            pause_xon_frames <= 32'd0;
        end else begin
            if (effective_request && remote_paused && !refresh_due)
                refresh_age <= refresh_age + 1'b1;
            if (clear_stats) begin
                pause_xoff_frames <= 32'd0;
                pause_xon_frames <= 32'd0;
            end
            case (state)
                ST_IDLE: begin
                    if (select_pause) begin
                        active_xoff <= effective_request;
                        state <= output_fire ? ST_PAUSE_LAST : ST_PAUSE_FIRST;
                    end else if (s_axis_tvalid && !(output_fire && m_axis_tlast)) begin
                        state <= ST_DATA;
                    end
                end
                ST_DATA: begin
                    if (output_fire && m_axis_tlast) state <= ST_IDLE;
                end
                ST_PAUSE_FIRST: begin
                    if (output_fire) state <= ST_PAUSE_LAST;
                end
                ST_PAUSE_LAST: begin
                    if (output_fire) begin
                        state <= ST_IDLE;
                        remote_paused <= active_xoff;
                        refresh_age <= {TIMER_WIDTH{1'b0}};
                        if (!clear_stats) begin
                            if (active_xoff && pause_xoff_frames != 32'hffffffff)
                                pause_xoff_frames <= pause_xoff_frames + 1'b1;
                            if (!active_xoff && pause_xon_frames != 32'hffffffff)
                                pause_xon_frames <= pause_xon_frames + 1'b1;
                        end
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
