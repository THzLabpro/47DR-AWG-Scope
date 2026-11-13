`timescale 1ns/1ps

module tb_awg_udp_port;
    localparam [47:0] FPGA_MAC = 48'h024741000002;
    localparam [31:0] FPGA_IP = 32'hc0a82a02;
    localparam [47:0] HOST_MAC = 48'h6cb311217d8e;
    localparam [31:0] HOST_IP = 32'hc0a82a0a;
    localparam integer MAX_FRAME_BYTES = 9000;
    localparam integer FIFO_DEPTH = 65536;
    localparam integer APP_IDLE = 0;
    localparam integer APP_HEADER = 1;
    localparam integer APP_PAYLOAD = 2;

    reg clk = 1'b0;
    always #5 clk = !clk;

    reg rst = 1'b1;
    reg [255:0] rx_in_data = 256'd0;
    reg [31:0] rx_in_keep = 32'd0;
    reg rx_in_valid = 1'b0;
    wire rx_in_ready;
    reg rx_in_last = 1'b0;
    reg rx_in_user = 1'b0;

    wire [255:0] rx_fifo_data;
    wire [31:0] rx_fifo_keep;
    wire rx_fifo_valid;
    wire rx_fifo_ready;
    wire rx_fifo_last;
    wire rx_fifo_user;

    wire [255:0] port_tx_data;
    wire [31:0] port_tx_keep;
    wire port_tx_valid;
    wire port_tx_ready;
    wire port_tx_last;
    wire port_tx_user;

    wire [255:0] tx_fifo_data;
    wire [31:0] tx_fifo_keep;
    wire tx_fifo_valid;
    wire tx_fifo_ready;
    wire tx_fifo_last;
    wire tx_fifo_user;

    wire rx_hdr_valid;
    wire rx_hdr_ready;
    wire [31:0] rx_src_ip;
    wire [15:0] rx_src_port;
    wire [15:0] rx_length;
    wire [63:0] rx_payload_tdata;
    wire [7:0] rx_payload_tkeep;
    wire rx_payload_tvalid;
    wire rx_payload_tready;
    wire rx_payload_tlast;
    wire rx_payload_tuser;

    wire tx_hdr_valid;
    wire tx_hdr_ready;
    wire [31:0] tx_dst_ip;
    wire [15:0] tx_dst_port;
    wire [15:0] tx_length;
    wire [63:0] tx_payload_tdata;
    wire [7:0] tx_payload_tkeep;
    wire tx_payload_tvalid;
    wire tx_payload_tready;
    wire tx_payload_tlast;
    wire tx_payload_tuser;

    wire [31:0] rx_frames_count;
    wire [31:0] rx_udp_9100_count;
    wire [31:0] rx_udp_other_count;
    wire [31:0] rx_non_ip_count;
    wire [31:0] tx_frames_count;

    reg [7:0] frame_bytes [0:MAX_FRAME_BYTES-1];
    reg [7:0] tx_frames [0:40][0:MAX_FRAME_BYTES-1];
    integer tx_lengths [0:40];
    integer tx_frame_count = 0;
    integer tx_byte_count = 0;
    integer app_hdr_count = 0;
    integer app_payload_count = 0;
    integer app_payload_byte_count = 0;
    integer app_payload_pos = 0;
    integer app_state = APP_IDLE;
    integer expected_payload_length = 0;
    integer error_count = 0;
    integer frame_size = 0;
    reg [31:0] packet_sequence = 32'd1;

    reg tx_app_hdr_valid = 1'b0;
    reg [31:0] tx_app_dst_ip = 32'd0;
    reg [15:0] tx_app_dst_port = 16'd0;
    reg [15:0] tx_app_length = 16'd0;

    function automatic [7:0] expected_payload_byte;
        input integer length;
        input integer index;
        begin
            expected_payload_byte = (index * 17 + length * 3 + 8'h5a) & 8'hff;
        end
    endfunction

    function automatic [15:0] read_frame_u16;
        input integer index;
        begin
            read_frame_u16 = {frame_bytes[index], frame_bytes[index+1]};
        end
    endfunction

    function automatic [31:0] ip_checksum_input;
        integer i;
        reg [31:0] sum;
        reg [15:0] word_value;
        begin
            sum = 32'd0;
            for (i = 0; i < 20; i = i + 2) begin
                word_value = {frame_bytes[14+i], frame_bytes[15+i]};
                sum = sum + word_value;
                sum = (sum & 32'hffff) + (sum >> 16);
            end
            sum = (sum & 32'hffff) + (sum >> 16);
            ip_checksum_input = ~sum[15:0];
        end
    endfunction

    function automatic [15:0] udp_checksum_input;
        input integer udp_length_bytes;
        integer i;
        reg [31:0] sum;
        reg [15:0] word_value;
        begin
            sum = 32'd0;
            for (i = 26; i < 34; i = i + 2) begin
                word_value = {frame_bytes[i], frame_bytes[i+1]};
                sum = sum + word_value;
                sum = (sum & 32'hffff) + (sum >> 16);
            end
            sum = sum + 16'h0011 + udp_length_bytes;
            for (i = 0; i < udp_length_bytes; i = i + 2) begin
                if (i + 1 < udp_length_bytes)
                    word_value = {frame_bytes[34+i], frame_bytes[35+i]};
                else
                    word_value = {frame_bytes[34+i], 8'd0};
                sum = sum + word_value;
                sum = (sum & 32'hffff) + (sum >> 16);
            end
            sum = (sum & 32'hffff) + (sum >> 16);
            sum = (sum & 32'hffff) + (sum >> 16);
            udp_checksum_input = ~sum[15:0];
        end
    endfunction

    function automatic [15:0] tx_ip_checksum_fold;
        input integer frame_index;
        integer i;
        reg [31:0] sum;
        reg [15:0] word_value;
        begin
            sum = 32'd0;
            for (i = 14; i < 34; i = i + 2) begin
                word_value = {tx_frames[frame_index][i], tx_frames[frame_index][i+1]};
                sum = sum + word_value;
                sum = (sum & 32'hffff) + (sum >> 16);
            end
            sum = (sum & 32'hffff) + (sum >> 16);
            tx_ip_checksum_fold = sum[15:0];
        end
    endfunction

    function automatic [15:0] tx_udp_checksum_fold;
        input integer frame_index;
        input integer udp_length_bytes;
        integer i;
        reg [31:0] sum;
        reg [15:0] word_value;
        begin
            sum = 32'd0;
            for (i = 26; i < 34; i = i + 2) begin
                word_value = {tx_frames[frame_index][i], tx_frames[frame_index][i+1]};
                sum = sum + word_value;
                sum = (sum & 32'hffff) + (sum >> 16);
            end
            sum = sum + 16'h0011 + udp_length_bytes;
            for (i = 0; i < udp_length_bytes; i = i + 2) begin
                if (i + 1 < udp_length_bytes)
                    word_value = {tx_frames[frame_index][34+i], tx_frames[frame_index][35+i]};
                else
                    word_value = {tx_frames[frame_index][34+i], 8'd0};
                sum = sum + word_value;
                sum = (sum & 32'hffff) + (sum >> 16);
            end
            sum = (sum & 32'hffff) + (sum >> 16);
            sum = (sum & 32'hffff) + (sum >> 16);
            tx_udp_checksum_fold = sum[15:0];
        end
    endfunction

    axis_fifo #(
        .DEPTH(FIFO_DEPTH), .DATA_WIDTH(256), .KEEP_ENABLE(1), .KEEP_WIDTH(32),
        .LAST_ENABLE(1), .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1),
        .USER_WIDTH(1), .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(1),
        .DROP_BAD_FRAME(1), .DROP_WHEN_FULL(1)
    ) u_rx_frame_fifo (
        .clk(clk), .rst(rst),
        .s_axis_tdata(rx_in_data), .s_axis_tkeep(rx_in_keep),
        .s_axis_tvalid(rx_in_valid), .s_axis_tready(rx_in_ready),
        .s_axis_tlast(rx_in_last), .s_axis_tid(8'd0), .s_axis_tdest(8'd0),
        .s_axis_tuser(rx_in_user),
        .m_axis_tdata(rx_fifo_data), .m_axis_tkeep(rx_fifo_keep),
        .m_axis_tvalid(rx_fifo_valid), .m_axis_tready(rx_fifo_ready),
        .m_axis_tlast(rx_fifo_last), .m_axis_tid(), .m_axis_tdest(),
        .m_axis_tuser(rx_fifo_user), .pause_req(1'b0),
        .status_overflow(), .status_bad_frame(), .status_good_frame()
    );

    awg_udp_port #(
        .LOCAL_MAC(FPGA_MAC), .LOCAL_IP(FPGA_IP),
        .STATIC_ARP_IP(HOST_IP), .STATIC_ARP_MAC(HOST_MAC),
        .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(32768)
    ) dut (
        .clk_eth(clk), .rst_eth(rst),
        .s_axis_tdata(rx_fifo_data), .s_axis_tkeep(rx_fifo_keep),
        .s_axis_tvalid(rx_fifo_valid), .s_axis_tready(rx_fifo_ready),
        .s_axis_tlast(rx_fifo_last), .s_axis_tuser(rx_fifo_user),
        .m_axis_tdata(port_tx_data), .m_axis_tkeep(port_tx_keep),
        .m_axis_tvalid(port_tx_valid), .m_axis_tready(port_tx_ready),
        .m_axis_tlast(port_tx_last), .m_axis_tuser(port_tx_user),
        .rx_hdr_valid(rx_hdr_valid), .rx_hdr_ready(rx_hdr_ready),
        .rx_src_ip(rx_src_ip), .rx_src_port(rx_src_port), .rx_length(rx_length),
        .rx_payload_tdata(rx_payload_tdata), .rx_payload_tkeep(rx_payload_tkeep),
        .rx_payload_tvalid(rx_payload_tvalid), .rx_payload_tready(rx_payload_tready),
        .rx_payload_tlast(rx_payload_tlast), .rx_payload_tuser(rx_payload_tuser),
        .tx_hdr_valid(tx_hdr_valid), .tx_hdr_ready(tx_hdr_ready),
        .tx_dst_ip(tx_dst_ip), .tx_dst_port(tx_dst_port), .tx_length(tx_length),
        .tx_payload_tdata(tx_payload_tdata), .tx_payload_tkeep(tx_payload_tkeep),
        .tx_payload_tvalid(tx_payload_tvalid), .tx_payload_tready(tx_payload_tready),
        .tx_payload_tlast(tx_payload_tlast), .tx_payload_tuser(tx_payload_tuser),
        .rx_frames(rx_frames_count), .rx_udp_9100(rx_udp_9100_count),
        .rx_udp_other(rx_udp_other_count), .rx_non_ip(rx_non_ip_count),
        .tx_frames(tx_frames_count)
    );

    axis_fifo #(
        .DEPTH(FIFO_DEPTH), .DATA_WIDTH(256), .KEEP_ENABLE(1), .KEEP_WIDTH(32),
        .LAST_ENABLE(1), .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1),
        .USER_WIDTH(1), .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(0),
        .DROP_BAD_FRAME(0), .DROP_WHEN_FULL(0)
    ) u_tx_frame_fifo (
        .clk(clk), .rst(rst),
        .s_axis_tdata(port_tx_data), .s_axis_tkeep(port_tx_keep),
        .s_axis_tvalid(port_tx_valid), .s_axis_tready(port_tx_ready),
        .s_axis_tlast(port_tx_last), .s_axis_tid(8'd0), .s_axis_tdest(8'd0),
        .s_axis_tuser(port_tx_user),
        .m_axis_tdata(tx_fifo_data), .m_axis_tkeep(tx_fifo_keep),
        .m_axis_tvalid(tx_fifo_valid), .m_axis_tready(tx_fifo_ready),
        .m_axis_tlast(tx_fifo_last), .m_axis_tid(), .m_axis_tdest(),
        .m_axis_tuser(tx_fifo_user), .pause_req(1'b0),
        .status_overflow(), .status_bad_frame(), .status_good_frame()
    );

    assign tx_fifo_ready = 1'b1;
    assign rx_hdr_ready = (app_state == APP_IDLE);
    assign rx_payload_tready = (app_state == APP_PAYLOAD) && tx_payload_tready;
    assign tx_payload_tdata = rx_payload_tdata;
    assign tx_payload_tkeep = rx_payload_tkeep;
    assign tx_payload_tvalid = (app_state == APP_PAYLOAD) && rx_payload_tvalid;
    assign tx_payload_tlast = rx_payload_tlast;
    assign tx_payload_tuser = rx_payload_tuser;
    assign tx_hdr_valid = tx_app_hdr_valid;
    assign tx_dst_ip = tx_app_dst_ip;
    assign tx_dst_port = tx_app_dst_port;
    assign tx_length = tx_app_length;

    always @(posedge clk) begin
        integer app_kept_bytes;
        if (rst) begin
            app_state <= APP_IDLE;
            tx_app_hdr_valid <= 1'b0;
            tx_app_dst_ip <= 32'd0;
            tx_app_dst_port <= 16'd0;
            tx_app_length <= 16'd0;
            app_hdr_count <= 0;
            app_payload_count <= 0;
            app_payload_byte_count <= 0;
            app_payload_pos <= 0;
        end else begin
            if (rx_hdr_valid && rx_hdr_ready) begin
                app_hdr_count <= app_hdr_count + 1;
                app_payload_pos = 0;
                tx_app_dst_ip <= rx_src_ip;
                tx_app_dst_port <= rx_src_port;
                tx_app_length <= rx_length;
                tx_app_hdr_valid <= 1'b1;
                app_state <= APP_HEADER;
                if (rx_src_ip != HOST_IP || rx_src_port != 16'd40000 ||
                    rx_length != expected_payload_length) begin
                    error_count = error_count + 1;
                    $display("CHECK_FAIL app_header idx=%0d ip=%h port=%0d length=%0d expected_length=%0d",
                        app_hdr_count, rx_src_ip, rx_src_port, rx_length, expected_payload_length);
                end
            end

            if (app_state == APP_HEADER && tx_app_hdr_valid && tx_hdr_ready) begin
                tx_app_hdr_valid <= 1'b0;
                app_state <= APP_PAYLOAD;
            end

            if (rx_payload_tvalid && rx_payload_tready) begin
                app_kept_bytes = 0;
                for (integer app_lane = 0; app_lane < 8; app_lane = app_lane + 1) begin
                    if (rx_payload_tkeep[app_lane]) begin
                        if (rx_payload_tdata[app_lane*8 +: 8] !==
                            expected_payload_byte(expected_payload_length, app_payload_pos)) begin
                            error_count = error_count + 1;
                            $display("CHECK_FAIL app_payload byte=%0d expected=%02x got=%02x",
                                app_payload_pos,
                                expected_payload_byte(expected_payload_length, app_payload_pos),
                                rx_payload_tdata[app_lane*8 +: 8]);
                        end
                        app_payload_pos = app_payload_pos + 1;
                        app_kept_bytes = app_kept_bytes + 1;
                    end
                end
                app_payload_byte_count <= app_payload_byte_count + app_kept_bytes;
                if (rx_payload_tlast) begin
                    app_payload_count <= app_payload_count + 1;
                    if (app_payload_pos != expected_payload_length) begin
                        error_count = error_count + 1;
                        $display("CHECK_FAIL app_payload_length got=%0d expected=%0d",
                            app_payload_pos, expected_payload_length);
                    end
                end
            end

            if (app_state == APP_PAYLOAD && rx_payload_tvalid &&
                rx_payload_tready && rx_payload_tlast)
                app_state <= APP_IDLE;
        end
    end

    always @(posedge clk) begin
        integer kept_bytes;
        if (rst) begin
            tx_frame_count <= 0;
            tx_byte_count <= 0;
        end else if (tx_fifo_valid && tx_fifo_ready) begin
            kept_bytes = 0;
            for (integer tx_lane = 0; tx_lane < 32; tx_lane = tx_lane + 1) begin
                if (tx_fifo_keep[tx_lane]) begin
                    if (tx_frame_count < 41 && tx_byte_count + kept_bytes < MAX_FRAME_BYTES)
                        tx_frames[tx_frame_count][tx_byte_count + kept_bytes] <= tx_fifo_data[tx_lane*8 +: 8];
                    kept_bytes = kept_bytes + 1;
                end
            end
            if (tx_fifo_last) begin
                tx_lengths[tx_frame_count] <= tx_byte_count + kept_bytes;
                tx_frame_count <= tx_frame_count + 1;
                tx_byte_count <= 0;
            end else begin
                tx_byte_count <= tx_byte_count + kept_bytes;
            end
        end
    end

    task automatic check;
        input condition;
        input [8*160-1:0] message;
        begin
            if (!condition) begin
                error_count = error_count + 1;
                $display("CHECK_FAIL %0s", message);
            end
        end
    endtask

    task automatic write_u16;
        input integer offset;
        input [15:0] value;
        begin
            frame_bytes[offset] = value[15:8];
            frame_bytes[offset+1] = value[7:0];
        end
    endtask

    task automatic write_u32;
        input integer offset;
        input [31:0] value;
        begin
            frame_bytes[offset] = value[31:24];
            frame_bytes[offset+1] = value[23:16];
            frame_bytes[offset+2] = value[15:8];
            frame_bytes[offset+3] = value[7:0];
        end
    endtask

    task automatic make_arp_request;
        begin
            for (integer i = 0; i < 60; i = i + 1) frame_bytes[i] = 8'd0;
            for (integer i = 0; i < 6; i = i + 1) begin
                frame_bytes[i] = 8'hff;
                frame_bytes[6+i] = HOST_MAC[47-i*8 -: 8];
            end
            frame_bytes[12] = 8'h08; frame_bytes[13] = 8'h06;
            frame_bytes[14] = 8'h00; frame_bytes[15] = 8'h01;
            frame_bytes[16] = 8'h08; frame_bytes[17] = 8'h00;
            frame_bytes[18] = 8'h06; frame_bytes[19] = 8'h04;
            frame_bytes[20] = 8'h00; frame_bytes[21] = 8'h01;
            for (integer i = 0; i < 6; i = i + 1)
                frame_bytes[22+i] = HOST_MAC[47-i*8 -: 8];
            write_u32(28, HOST_IP);
            write_u32(38, FPGA_IP);
            frame_size = 42;
        end
    endtask

    task automatic make_udp_frame;
        input integer payload_length;
        input [15:0] destination_port;
        integer udp_length_bytes;
        begin
            udp_length_bytes = payload_length + 8;
            frame_size = payload_length + 42;
            for (integer i = 0; i < frame_size; i = i + 1) frame_bytes[i] = 8'd0;

            for (integer i = 0; i < 6; i = i + 1) begin
                frame_bytes[i] = FPGA_MAC[47-i*8 -: 8];
                frame_bytes[6+i] = HOST_MAC[47-i*8 -: 8];
            end
            frame_bytes[12] = 8'h08; frame_bytes[13] = 8'h00;
            frame_bytes[14] = 8'h45; frame_bytes[15] = 8'h00;
            write_u16(16, payload_length + 28);
            write_u16(18, packet_sequence[15:0]);
            write_u16(20, 16'h4000);
            frame_bytes[22] = 8'd64; frame_bytes[23] = 8'd17;
            frame_bytes[24] = 8'd0; frame_bytes[25] = 8'd0;
            write_u32(26, HOST_IP);
            write_u32(30, FPGA_IP);
            write_u16(34, 16'd40000);
            write_u16(36, destination_port);
            write_u16(38, udp_length_bytes[15:0]);
            write_u16(40, 16'd0);
            for (integer i = 0; i < payload_length; i = i + 1)
                frame_bytes[42+i] = expected_payload_byte(payload_length, i);

            write_u16(24, ip_checksum_input());
            write_u16(40, udp_checksum_input(udp_length_bytes));
            if (read_frame_u16(40) == 16'd0) write_u16(40, 16'hffff);
            packet_sequence = packet_sequence + 1'b1;
        end
    endtask

    task automatic send_current_frame;
        input bad_frame;
        integer beats;
        integer byte_index;
        reg [255:0] beat_data;
        reg [31:0] beat_keep;
        begin
            beats = (frame_size + 31) / 32;
            for (integer beat = 0; beat < beats; beat = beat + 1) begin
                @(negedge clk);
                beat_data = 256'd0;
                beat_keep = 32'd0;
                for (integer lane = 0; lane < 32; lane = lane + 1) begin
                    byte_index = beat * 32 + lane;
                    if (byte_index < frame_size) begin
                        beat_data[lane*8 +: 8] = frame_bytes[byte_index];
                        beat_keep[lane] = 1'b1;
                    end
                end
                rx_in_data = beat_data;
                rx_in_keep = beat_keep;
                rx_in_valid = 1'b1;
                rx_in_last = (beat == beats - 1);
                rx_in_user = bad_frame && rx_in_last;
                do @(posedge clk); while (!rx_in_ready);
            end
        end
    endtask

    task automatic stop_source;
        begin
            @(negedge clk);
            rx_in_valid = 1'b0;
            rx_in_keep = 32'd0;
            rx_in_last = 1'b0;
            rx_in_user = 1'b0;
        end
    endtask

    task automatic wait_for_results;
        input integer expected_headers;
        input integer expected_payloads;
        input integer expected_frames;
        integer cycles;
        begin
            cycles = 0;
            while ((app_hdr_count < expected_headers ||
                    app_payload_count < expected_payloads ||
                    tx_frame_count < expected_frames) && cycles < 300000) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            check(app_hdr_count >= expected_headers, "app_header_watchdog");
            check(app_payload_count >= expected_payloads, "app_payload_watchdog");
            check(tx_frame_count >= expected_frames, "tx_frame_watchdog");
        end
    endtask

    task automatic check_arp_reply;
        input integer frame_index;
        begin
            check(tx_lengths[frame_index] >= 42, "T1_arp_reply_frame_length");
            check(tx_frames[frame_index][0] == HOST_MAC[47:40] &&
                  tx_frames[frame_index][5] == HOST_MAC[7:0], "T1_arp_reply_destination_mac");
            check(tx_frames[frame_index][6] == FPGA_MAC[47:40] &&
                  tx_frames[frame_index][11] == FPGA_MAC[7:0], "T1_arp_reply_source_mac");
            check(tx_frames[frame_index][12] == 8'h08 &&
                  tx_frames[frame_index][13] == 8'h06, "T1_arp_reply_ethertype");
            check(tx_frames[frame_index][20] == 8'h00 &&
                  tx_frames[frame_index][21] == 8'h02, "T1_arp_reply_opcode");
            check(tx_frames[frame_index][22] == FPGA_MAC[47:40] &&
                  tx_frames[frame_index][27] == FPGA_MAC[7:0], "T1_arp_reply_sender_mac");
            check(tx_frames[frame_index][28] == 8'hc0 &&
                  tx_frames[frame_index][31] == 8'h02, "T1_arp_reply_sender_ip");
            check(tx_frames[frame_index][32] == HOST_MAC[47:40] &&
                  tx_frames[frame_index][37] == HOST_MAC[7:0], "T1_arp_reply_target_mac");
            check(tx_frames[frame_index][38] == 8'hc0 &&
                  tx_frames[frame_index][41] == 8'h0a, "T1_arp_reply_target_ip");
        end
    endtask

    task automatic check_udp_reply;
        input integer frame_index;
        input integer payload_length;
        integer udp_length_bytes;
        begin
            udp_length_bytes = payload_length + 8;
            check(tx_lengths[frame_index] >= payload_length + 42, "UDP_reply_frame_length");
            check(tx_frames[frame_index][0] == HOST_MAC[47:40] &&
                  tx_frames[frame_index][5] == HOST_MAC[7:0], "UDP_reply_destination_mac");
            check(tx_frames[frame_index][6] == FPGA_MAC[47:40] &&
                  tx_frames[frame_index][11] == FPGA_MAC[7:0], "UDP_reply_source_mac");
            check(tx_frames[frame_index][12] == 8'h08 &&
                  tx_frames[frame_index][13] == 8'h00, "UDP_reply_ethertype");
            check(tx_frames[frame_index][26] == 8'hc0 &&
                  tx_frames[frame_index][29] == 8'h02 &&
                  tx_frames[frame_index][30] == 8'hc0 &&
                  tx_frames[frame_index][33] == 8'h0a, "UDP_reply_ip_addresses");
            check(tx_ip_checksum_fold(frame_index) == 16'hffff, "UDP_reply_ip_checksum");
            check({tx_frames[frame_index][34], tx_frames[frame_index][35]} == 16'd9100,
                  "UDP_reply_source_port");
            check({tx_frames[frame_index][36], tx_frames[frame_index][37]} == 16'd40000,
                  "UDP_reply_destination_port");
            check({tx_frames[frame_index][38], tx_frames[frame_index][39]} == udp_length_bytes,
                  "UDP_reply_udp_length");
            check(({tx_frames[frame_index][40], tx_frames[frame_index][41]} == 16'd0) ||
                  (tx_udp_checksum_fold(frame_index, udp_length_bytes) == 16'hffff),
                  "UDP_reply_udp_checksum");
            if (frame_index >= 1 && frame_index <= 3) begin
                if ({tx_frames[frame_index][40], tx_frames[frame_index][41]} == 16'd0)
                    $display("UDP_CHECKSUM frame=%0d mode=zero", frame_index);
                else
                    $display("UDP_CHECKSUM frame=%0d mode=calculated value=%04x fold=%04x",
                        frame_index,
                        {tx_frames[frame_index][40], tx_frames[frame_index][41]},
                        tx_udp_checksum_fold(frame_index, udp_length_bytes));
            end
            for (integer i = 0; i < payload_length; i = i + 1) begin
                if (tx_frames[frame_index][42+i] !== expected_payload_byte(payload_length, i)) begin
                    error_count = error_count + 1;
                    $display("CHECK_FAIL UDP_reply_payload frame=%0d byte=%0d expected=%02x got=%02x",
                        frame_index, i, expected_payload_byte(payload_length, i),
                        tx_frames[frame_index][42+i]);
                    i = payload_length;
                end
            end
        end
    endtask

    task automatic report_test;
        input [8*8-1:0] test_name;
        input integer errors_before;
        begin
            if (error_count == errors_before)
                $display("RESULT name=%0s PASS", test_name);
            else
                $display("RESULT name=%0s FAIL errors=%0d", test_name, error_count-errors_before);
        end
    endtask

    initial begin
        integer errors_before;
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (8) @(posedge clk);

        errors_before = error_count;
        make_arp_request();
        send_current_frame(1'b0);
        stop_source();
        wait_for_results(0, 0, 1);
        check_arp_reply(0);
        check(rx_non_ip_count == 1, "T1_rx_non_ip_counts_arp");
        report_test("T1", errors_before);

        errors_before = error_count;
        expected_payload_length = 24;
        make_udp_frame(24, 16'd9100);
        send_current_frame(1'b0);
        stop_source();
        wait_for_results(1, 1, 2);
        check_udp_reply(1, 24);

        expected_payload_length = 1048;
        make_udp_frame(1048, 16'd9100);
        send_current_frame(1'b0);
        stop_source();
        wait_for_results(2, 2, 3);
        check_udp_reply(2, 1048);

        expected_payload_length = 8216;
        make_udp_frame(8216, 16'd9100);
        send_current_frame(1'b0);
        stop_source();
        wait_for_results(3, 3, 4);
        check_udp_reply(3, 8216);
        check(rx_udp_9100_count == 3, "T2_rx_udp_9100_count");
        report_test("T2", errors_before);

        errors_before = error_count;
        expected_payload_length = 24;
        make_udp_frame(24, 16'd9000);
        send_current_frame(1'b0);
        stop_source();
        repeat (2000) @(posedge clk);
        check(app_hdr_count == 3, "T3_no_app_header");
        check(tx_frame_count == 4, "T3_no_tx_frame");
        check(rx_udp_other_count == 1, "T3_other_udp_count");
        report_test("T3", errors_before);

        errors_before = error_count;
        expected_payload_length = 24;
        make_udp_frame(24, 16'd9100);
        send_current_frame(1'b1);
        stop_source();
        repeat (2000) @(posedge clk);
        check(app_hdr_count == 3, "T4_bad_fcs_no_app_header");
        check(tx_frame_count == 4, "T4_bad_fcs_no_echo");
        check(rx_udp_9100_count == 3, "T4_bad_fcs_not_counted_as_good_udp");
        report_test("T4", errors_before);

        errors_before = error_count;
        expected_payload_length = 1048;
        for (integer packet = 0; packet < 32; packet = packet + 1) begin
            make_udp_frame(1048, 16'd9100);
            send_current_frame(1'b0);
        end
        stop_source();
        wait_for_results(35, 35, 36);
        for (integer frame_index = 4; frame_index < 36; frame_index = frame_index + 1)
            check_udp_reply(frame_index, 1048);
        check(rx_udp_9100_count == 35, "T5_udp_9100_count");
        check(app_payload_count == 35, "T5_all_payloads_echoed");
        check(app_payload_byte_count == 24 + 1048 + 8216 + 32*1048,
            "T5_total_app_payload_bytes");
        report_test("T5", errors_before);

        errors_before = error_count;
        for (integer i = 0; i < 60; i = i + 1) frame_bytes[i] = 8'd0;
        frame_bytes[12] = 8'h86;
        frame_bytes[13] = 8'hdd;
        frame_size = 60;
        send_current_frame(1'b0);
        stop_source();
        repeat (2000) @(posedge clk);
        check(app_hdr_count == 35, "T6_no_app_header");
        check(tx_frame_count == 36, "T6_no_tx_frame");
        check(rx_non_ip_count == 2, "T6_ipv6_non_ip_count");
        check(rx_frames_count == 38, "RX_frame_count");
        check(tx_frames_count == 36, "TX_frame_count");
        report_test("T6", errors_before);

        $display("COUNTS rx_frames=%0d rx_udp_9100=%0d rx_udp_other=%0d rx_non_ip=%0d tx_frames=%0d app_headers=%0d app_payloads=%0d app_payload_bytes=%0d",
            rx_frames_count, rx_udp_9100_count, rx_udp_other_count, rx_non_ip_count,
            tx_frames_count, app_hdr_count, app_payload_count, app_payload_byte_count);
        if (error_count != 0) begin
            $display("RESULT name=tb_awg_udp_port FAIL errors=%0d", error_count);
            $fatal(1, "E2 Ethernet core acceptance failed");
        end
        $display("RESULT name=tb_awg_udp_port PASS errors=0");
        $finish;
    end
endmodule
