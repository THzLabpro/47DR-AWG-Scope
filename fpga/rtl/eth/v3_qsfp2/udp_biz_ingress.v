`default_nettype none
`timescale 1ns/1ps
// =============================================================
// 模块：udp_biz_ingress
// 功能：锁存 header 的业务开关，写 META/长度检查，再整帧提交到 URAM
// 时钟/复位：clk，rst 同步高有效
// 输入：UDP header 与 64 bit payload，s_length 含 8 B UDP header
// 输出：META + payload；深度包含输入暂存、URAM、读流水及输出暂存
// 关键参数：FIFO_BYTES 为 8 B 槽容量；缺省 1 MiB
// =============================================================
module udp_biz_ingress #(parameter FIFO_BYTES = 1048576)(
    input wire clk, rst, ctrl_biz_tx_enable,
    input wire s_hdr_valid, output wire s_hdr_ready,
    input wire [31:0] s_source_ip,
    input wire [15:0] s_source_port, s_length,
    input wire [63:0] s_data, input wire [7:0] s_keep,
    input wire s_valid, output wire s_ready, input wire s_last, s_user,
    output wire [63:0] m_data, output wire [7:0] m_keep,
    output wire [3:0] m_keep_byte_count, output wire m_keep_prefix,
    output wire m_valid, input wire m_ready, output wire m_last,
    output reg [31:0] host_ip, output reg [15:0] host_port,
    output wire drop_event, output wire malformed_event,
    output wire overflow_event,
    output wire [31:0] ram_allocated_words,
    output wire [31:0] total_buffered_bytes,
    output wire [1:0] dbg_state
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_META = 2'd1;
    localparam [1:0] ST_PAYLOAD = 2'd2;
    localparam [1:0] ST_DRAIN = 2'd3;

    reg [1:0] state;
    reg [31:0] source_ip;
    reg [15:0] source_port, payload_len, received;
    reg bad_seen;

    // Stage 0 registers keep popcount; stage 1 registers FIFO write controls.
    reg [63:0] payload_stage_data;
    reg [7:0] payload_stage_keep;
    reg payload_stage_valid;
    reg payload_stage_last;
    reg payload_stage_user;
    reg [3:0] payload_stage_bytes;
    reg [63:0] fifo_stage_data;
    reg [7:0] fifo_stage_keep;
    reg fifo_stage_valid;
    reg fifo_stage_last;
    reg fifo_stage_user;

    wire [63:0] fifo_s_data = state == ST_META ?
        {payload_len, source_port, source_ip} : fifo_stage_data;
    wire [7:0] fifo_s_keep = state == ST_META ? 8'hff : fifo_stage_keep;
    wire fifo_s_valid = state == ST_META ||
                        (state == ST_PAYLOAD && fifo_stage_valid);
    wire fifo_s_ready;
    wire fifo_s_last = state == ST_META ? payload_len == 0 : fifo_stage_last;
    wire fifo_s_fire = fifo_s_valid && fifo_s_ready;
    wire fifo_stage_ready = !fifo_stage_valid || fifo_s_ready;
    wire payload_stage_fire = payload_stage_valid && fifo_stage_ready &&
                              state == ST_PAYLOAD;
    wire payload_stage_ready = !payload_stage_valid ||
        (payload_stage_fire && !payload_stage_last);
    wire s_fire = s_valid && s_ready;
    wire [3:0] s_keep_byte_count;
    wire [16:0] staged_received_total = {1'b0, received} + payload_stage_bytes;
    wire staged_bad_length = staged_received_total != {1'b0, payload_len};
    wire payload_stage_user_next = payload_stage_user || bad_seen ||
                                   (payload_stage_last && staged_bad_length);
    wire fifo_s_user = state == ST_PAYLOAD && fifo_stage_user;

    wire overflow, bad_frame, good_frame;
    wire [63:0] fifo_m_data;
    wire [7:0] fifo_m_keep;
    wire fifo_m_valid;
    wire fifo_m_last;
    wire fifo_m_ready;
    wire [31:0] fifo_buffered_bytes;
    wire [3:0] staged_words;
    reg [63:0] output_data_reg;
    reg [7:0] output_keep_reg;
    reg [3:0] output_keep_byte_count_reg;
    reg output_keep_prefix_reg;
    reg output_valid_reg;
    reg output_last_reg;

    function [3:0] count_keep;
        input [7:0] keep;
        reg [1:0] pair0, pair1, pair2, pair3;
        reg [2:0] low_count, high_count;
        begin
            pair0 = {1'b0, keep[0]} + {1'b0, keep[1]};
            pair1 = {1'b0, keep[2]} + {1'b0, keep[3]};
            pair2 = {1'b0, keep[4]} + {1'b0, keep[5]};
            pair3 = {1'b0, keep[6]} + {1'b0, keep[7]};
            low_count = {1'b0, pair0} + {1'b0, pair1};
            high_count = {1'b0, pair2} + {1'b0, pair3};
            count_keep = {1'b0, low_count} + {1'b0, high_count};
        end
    endfunction

    function keep_is_prefix;
        input [7:0] keep;
        begin
            keep_is_prefix = (keep == 8'hff) || (keep == 8'h7f) ||
                             (keep == 8'h3f) || (keep == 8'h1f) ||
                             (keep == 8'h0f) || (keep == 8'h07) ||
                             (keep == 8'h03) || (keep == 8'h01);
        end
    endfunction

    assign s_keep_byte_count = count_keep(s_keep);
    assign s_hdr_ready = state == ST_IDLE;
    assign s_ready = state == ST_DRAIN ||
                     (state == ST_PAYLOAD && payload_stage_ready &&
                      !(fifo_stage_valid && fifo_stage_last));
    assign drop_event = overflow || bad_frame ||
                        (s_hdr_valid && s_hdr_ready && !ctrl_biz_tx_enable);
    assign malformed_event = bad_frame;
    assign overflow_event = overflow;
    assign dbg_state = state;
    assign staged_words = {3'd0, payload_stage_valid} + {3'd0, fifo_stage_valid} +
                          {3'd0, output_valid_reg} + {3'd0, (state == ST_META)};
    assign total_buffered_bytes = fifo_buffered_bytes + (staged_words << 3);

    assign m_data = output_data_reg;
    assign m_keep = output_keep_reg;
    assign m_keep_byte_count = output_keep_byte_count_reg;
    assign m_keep_prefix = output_keep_prefix_reg;
    assign m_valid = output_valid_reg;
    assign m_last = output_last_reg;
    assign fifo_m_ready = !output_valid_reg || m_ready;

    uram_frame_fifo #(.DEPTH_WORDS(FIFO_BYTES / 8), .READ_LATENCY(7)) fifo (
        .clk(clk), .rst(rst), .s_axis_tdata(fifo_s_data), .s_axis_tkeep(fifo_s_keep),
        .s_axis_tvalid(fifo_s_valid), .s_axis_tready(fifo_s_ready), .s_axis_tlast(fifo_s_last),
        .s_axis_tuser(fifo_s_user),
        .m_axis_tdata(fifo_m_data), .m_axis_tkeep(fifo_m_keep), .m_axis_tvalid(fifo_m_valid),
        .m_axis_tready(fifo_m_ready), .m_axis_tlast(fifo_m_last), .m_axis_tuser(),
        .status_ram_words(ram_allocated_words), .status_buffered_bytes(fifo_buffered_bytes),
        .status_overflow(overflow), .status_bad_frame(bad_frame),
        .status_good_frame(good_frame), .dbg_state());

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            source_ip <= 32'd0;
            source_port <= 16'd0;
            payload_len <= 16'd0;
            received <= 16'd0;
            bad_seen <= 1'b0;
            payload_stage_data <= 64'd0;
            payload_stage_keep <= 8'd0;
            payload_stage_valid <= 1'b0;
            payload_stage_last <= 1'b0;
            payload_stage_user <= 1'b0;
            payload_stage_bytes <= 4'd0;
            fifo_stage_data <= 64'd0;
            fifo_stage_keep <= 8'd0;
            fifo_stage_valid <= 1'b0;
            fifo_stage_last <= 1'b0;
            fifo_stage_user <= 1'b0;
            host_ip <= 32'hc0a82a0a;
            host_port <= 16'd9000;
        end else begin
            if (good_frame) begin
                host_ip <= source_ip;
                host_port <= source_port;
            end

            if (s_fire && state == ST_PAYLOAD) begin
                payload_stage_data <= s_data;
                payload_stage_keep <= s_keep;
                payload_stage_valid <= 1'b1;
                payload_stage_last <= s_last;
                payload_stage_user <= s_user;
                payload_stage_bytes <= s_keep_byte_count;
            end else if (payload_stage_fire) begin
                payload_stage_valid <= 1'b0;
            end

            if (payload_stage_fire) begin
                fifo_stage_data <= payload_stage_data;
                fifo_stage_keep <= payload_stage_keep;
                fifo_stage_valid <= 1'b1;
                fifo_stage_last <= payload_stage_last;
                fifo_stage_user <= payload_stage_user_next;
            end else if (fifo_s_fire && state == ST_PAYLOAD) begin
                fifo_stage_valid <= 1'b0;
            end

            case (state)
                ST_IDLE: begin
                    if (s_hdr_valid && s_hdr_ready) begin
                        source_ip <= s_source_ip;
                        source_port <= s_source_port;
                        payload_len <= s_length - 16'd8;
                        received <= 16'd0;
                        bad_seen <= 1'b0;
                        if (!ctrl_biz_tx_enable && s_length > 16'd8)
                            state <= ST_DRAIN;
                        else if (ctrl_biz_tx_enable)
                            state <= ST_META;
                    end
                end
                ST_META: begin
                    if (fifo_s_fire)
                        state <= payload_len == 0 ? ST_IDLE : ST_PAYLOAD;
                end
                ST_PAYLOAD: begin
                    if (payload_stage_fire) begin
                        received <= received + payload_stage_bytes;
                        bad_seen <= bad_seen || payload_stage_user;
                    end
                    if (fifo_s_fire && fifo_stage_last)
                        state <= ST_IDLE;
                end
                ST_DRAIN: begin
                    if (s_valid && s_ready && s_last)
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    // Hold the FIFO read beat while the downstream AXIS consumer is stalled.
    always @(posedge clk) begin
        if (rst) begin
            output_data_reg <= 64'd0;
            output_keep_reg <= 8'd0;
            output_keep_byte_count_reg <= 4'd0;
            output_keep_prefix_reg <= 1'b0;
            output_valid_reg <= 1'b0;
            output_last_reg <= 1'b0;
        end else if (!output_valid_reg || m_ready) begin
            output_valid_reg <= fifo_m_valid;
            if (fifo_m_valid) begin
                output_data_reg <= fifo_m_data;
                output_keep_reg <= fifo_m_keep;
                output_keep_byte_count_reg <= count_keep(fifo_m_keep);
                output_keep_prefix_reg <= keep_is_prefix(fifo_m_keep);
                output_last_reg <= fifo_m_last;
            end
        end
    end
endmodule
`default_nettype wire
