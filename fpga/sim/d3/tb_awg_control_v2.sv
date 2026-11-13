`timescale 1ns/1ps
`default_nettype none

module tb_awg_control_v2;
    reg clk = 1'b0;
    always #5.0 clk = ~clk;

    reg resetn = 1'b0;
    reg [31:0] awaddr = 0;
    reg awvalid = 0;
    wire awready;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 4'hf;
    reg wvalid = 0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    reg bready = 0;
    reg [31:0] araddr = 0;
    reg arvalid = 0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    reg rready = 0;

    reg ps_ready = 1'b1;
    wire [2:0] tx_wr_ch;
    wire tx_wr_rewind;
    wire [31:0] tx_wr_data;
    wire tx_wr_valid;
    reg tx_wr_ready = 1'b1;
    reg [17:0] tx_wr_ptr = 0;
    wire tx_crc_start;
    wire [2:0] tx_crc_ch;
    reg tx_crc_busy = 1'b0;
    reg [31:0] tx_crc_value = 32'hD49307A0;
    wire tx_start, tx_stop, tx_clear_fault;
    wire [12:0] tx_length_words;
    wire [7:0] tx_mask;
    reg tx_running = 1'b0;
    reg tx_started = 1'b0;
    reg [7:0] tx_faults = 0;
    reg [31:0] tx_wrap_count = 0;
    reg tx_locked = 1'b0;
    reg tx_start_rejected = 1'b0;

    wire rx_arm;
    wire rx_abort;
    wire rx_trig_mode;
    wire [11:0] rx_cap_words;
    reg rx_busy = 1'b0;
    reg rx_armed = 1'b0;
    reg rx_done = 1'b0;
    reg [16:0] rx_captured_samples = 0;
    reg [11:0] rx_cap_tx_word = 12'h123;
    wire [2:0] rx_rd_ch;
    wire [14:0] rx_rd_pair;
    wire rx_rd_req;
    reg [31:0] rx_rd_data = 32'hCAFE_BABE;
    reg rx_rd_valid = 1'b0;
    reg abort_seen = 1'b0;

    awg_control_v2 #(.BUILD_ID(32'hD3A3_2026)) dut (
        .host_clk(clk), .host_resetn(resetn),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
        .ps_ready(ps_ready),
        .tx_h_wr_ch(tx_wr_ch), .tx_h_wr_rewind(tx_wr_rewind), .tx_h_wr_data(tx_wr_data),
        .tx_h_wr_valid(tx_wr_valid), .tx_h_wr_ready(tx_wr_ready), .tx_h_wr_ptr(tx_wr_ptr),
        .tx_h_crc_start(tx_crc_start), .tx_h_crc_ch(tx_crc_ch), .tx_h_crc_busy(tx_crc_busy),
        .tx_h_crc_value(tx_crc_value), .tx_h_start(tx_start), .tx_h_stop(tx_stop),
        .tx_h_clear_fault(tx_clear_fault), .tx_h_length_words(tx_length_words), .tx_h_mask(tx_mask),
        .tx_h_running(tx_running), .tx_h_started(tx_started), .tx_h_faults(tx_faults),
        .tx_h_wrap_count(tx_wrap_count), .tx_h_locked(tx_locked), .tx_h_start_rejected(tx_start_rejected),
        .rx_h_arm(rx_arm), .rx_h_abort(rx_abort), .rx_h_trig_mode(rx_trig_mode), .rx_h_cap_words(rx_cap_words),
        .rx_h_busy(rx_busy), .rx_h_armed(rx_armed), .rx_h_done(rx_done), .rx_h_captured_samples(rx_captured_samples),
        .rx_h_cap_tx_word(rx_cap_tx_word), .rx_h_rd_ch(rx_rd_ch), .rx_h_rd_pair(rx_rd_pair),
        .rx_h_rd_req(rx_rd_req), .rx_h_rd_data(rx_rd_data), .rx_h_rd_valid(rx_rd_valid),
        .dbg_cmd_busy()
    );

    // Like awg_rx: a request with the pointer past the buffer is ignored (no valid).
    reg rx_drop = 1'b0;
    always @(posedge clk) begin
        rx_rd_valid <= rx_rd_req && !rx_drop && (rx_rd_pair < 15'd32760);
        if (rx_abort) abort_seen <= 1'b1;
    end

    integer pass_count = 0;
    integer fail_count = 0;
    integer timeout;
    reg [31:0] rd_value;
    reg [1:0] rd_resp;
    reg [1:0] wr_resp;

    task automatic check(input bit condition, input string name);
        begin
            if (condition) begin pass_count = pass_count + 1; $display("PASS %s", name); end
            else begin fail_count = fail_count + 1; $display("FAIL %s", name); end
        end
    endtask

    task automatic axi_write(input [31:0] addr, input [31:0] data, output [1:0] resp);
        bit aw_done;
        bit w_done;
        begin
            aw_done = 0; w_done = 0;
            @(negedge clk); awaddr = addr; wdata = data; awvalid = 1; wvalid = 1; bready = 0;
            timeout = 0;
            while ((!aw_done || !w_done) && timeout < 100) begin
                @(posedge clk);
                if (awvalid && awready) aw_done = 1;
                if (wvalid && wready) w_done = 1;
                timeout = timeout + 1;
            end
            @(negedge clk); awvalid = 0; wvalid = 0; bready = 1;
            timeout = 0;
            while (!bvalid && timeout < 100) begin @(posedge clk); timeout = timeout + 1; end
            resp = bresp;
            if (!bvalid) fail_count = fail_count + 1;
            @(posedge clk); bready = 0;
        end
    endtask

    task automatic axi_read(input [31:0] addr, output [31:0] data, output [1:0] resp);
        begin
            @(negedge clk); araddr = addr; arvalid = 1; rready = 0;
            timeout = 0;
            while (!arready && timeout < 100) begin @(posedge clk); timeout = timeout + 1; end
            @(negedge clk); arvalid = 0; rready = 1;
            timeout = 0;
            while (!rvalid && timeout < 100) begin @(posedge clk); timeout = timeout + 1; end
            data = rdata; resp = rresp;
            if (!rvalid) fail_count = fail_count + 1;
            @(posedge clk); rready = 0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);

        axi_read(32'h9020_0000, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'h4157_4732, "ID read");
        axi_read(32'h9020_0014, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'd9800000, "DAC FS read");
        axi_read(32'h9020_0018, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'd5000000, "ADC FS read");
        axi_read(32'h9020_0020, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'h00030001, "ABI read");
        axi_read(32'h9020_0054, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'hD3A3_2026, "BUILD_ID read");
        axi_read(32'h9020_0058, rd_value, rd_resp); check(rd_resp == 2, "undefined read SLVERR");

        axi_write(32'h9020_000c, 32'd1, wr_resp); check(wr_resp == 0 && tx_length_words == 1, "TX_LENGTH write");
        axi_write(32'h9020_0010, 32'h1, wr_resp); check(wr_resp == 0 && tx_mask == 1, "TX_MASK write");
        axi_write(32'h9020_0030, 32'd0, wr_resp); check(wr_resp == 0 && dut.selected_wr_ch == 0 && dut.written_samples[0] == 0, "TX_WR_CH rewind");
        repeat (16) begin axi_write(32'h9020_0038, 32'h0001_0002, wr_resp); check(wr_resp == 0, "TX_WR_DATA write"); end
        axi_write(32'h9020_0008, 32'd2, wr_resp); check(wr_resp == 0 && dut.last_cmd_result == 0, "COMMAND start");
        tx_running = 1'b1;
        axi_write(32'h9020_000c, 32'd2, wr_resp); check(wr_resp == 2, "TX_LENGTH while running SLVERR");
        tx_running = 1'b0;
        axi_write(32'h9020_0008, 32'd1, wr_resp); check(wr_resp == 0 && dut.last_cmd_result == 0, "COMMAND stop");
        axi_write(32'h9020_0008, 32'd16, wr_resp); check(wr_resp == 0 && dut.last_cmd_result == 0, "COMMAND CRC");

        // TX_WR_DATA must hold valid/data during FIFO backpressure.
        tx_wr_ready = 1'b0;
        @(negedge clk); awaddr = 32'h9020_0038; wdata = 32'h1234_5678; awvalid = 1'b1; wvalid = 1'b1; bready = 1'b0;
        while (!(awvalid && awready && wvalid && wready)) @(posedge clk);
        @(negedge clk); awvalid = 1'b0; wvalid = 1'b0;
        repeat (4) @(posedge clk);
        check(tx_wr_valid && tx_wr_data == 32'h1234_5678, "TX_WR_DATA holds under backpressure");
        tx_wr_ready = 1'b1; bready = 1'b1;
        while (!bvalid) @(posedge clk);
        check(bresp == 0, "TX_WR_DATA backpressure response");
        @(posedge clk); bready = 1'b0;

        axi_write(32'h9020_0040, 32'd3, wr_resp); check(wr_resp == 0 && rx_rd_ch == 3, "CAP_RD_CH write");
        axi_write(32'h9020_0044, 32'd7, wr_resp); check(wr_resp == 0 && rx_rd_pair == 7, "CAP_RD_PTR write");
        axi_read(32'h9020_0048, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'hCAFE_BABE, "CAP_RD_DATA read");
        axi_write(32'h9020_004c, (32'd10 << 16) | 1, wr_resp); check(wr_resp == 0 && dut.cap_words_cfg == 10 && dut.cap_trig_cfg, "CAP_CTRL write");
        axi_write(32'h9020_0008, 32'd8, wr_resp); check(wr_resp == 0 && dut.last_cmd_result == 0, "COMMAND arm");
        rx_armed = 1'b1;
        axi_write(32'h9020_0008, 32'd32, wr_resp); check(wr_resp == 0 && abort_seen, "COMMAND abort");
        rx_busy = 1'b1;
        axi_write(32'h9020_004c, (12'd11 << 16), wr_resp); check(wr_resp == 2, "CAP_CTRL while busy SLVERR");
        rx_busy = 1'b0;
        rx_armed = 1'b0;
        axi_read(32'h9020_0048, rd_value, rd_resp); check(rd_resp == 0, "CAP_RD_DATA idle read");
        rx_busy = 1'b1;
        axi_read(32'h9020_0048, rd_value, rd_resp); check(rd_resp == 2, "CAP_RD_DATA busy SLVERR");
        rx_busy = 1'b0;
        axi_write(32'h9020_0040, 32'd8, wr_resp); check(wr_resp == 2, "CAP_RD_CH invalid SLVERR");
        axi_write(32'h9020_000c, 32'd0, wr_resp); check(wr_resp == 2, "TX_LENGTH zero SLVERR");
        axi_write(32'h9020_000c, 32'h0001_0001, wr_resp); check(wr_resp == 2, "TX_LENGTH reserved bits SLVERR");
        axi_write(32'h9020_0030, 32'h0000_0008, wr_resp); check(wr_resp == 2, "TX_WR_CH reserved bits SLVERR");
        axi_write(32'h9020_0044, 32'h0000_8000, wr_resp); check(wr_resp == 2, "CAP_RD_PTR reserved bits SLVERR");
        axi_write(32'h9020_004c, 32'h0000_0002, wr_resp); check(wr_resp == 2, "CAP_CTRL reserved bits SLVERR");
        axi_write(32'h9020_0058, 32'd1, wr_resp); check(wr_resp == 2, "undefined write SLVERR");

        // STATUS uses the frozen bit allocation from doc/01.
        tx_running = 1'b1; tx_locked = 1'b0; tx_faults = 8'h1; rx_busy = 1'b1; rx_done = 1'b1; tx_crc_busy = 1'b1;
        axi_read(32'h9020_0004, rd_value, rd_resp);
        check(rd_resp == 0 && rd_value[0] && rd_value[1] && rd_value[2] && rd_value[3] && rd_value[6] && rd_value[7] && rd_value[8], "STATUS bit allocation");
        tx_running = 1'b0; tx_locked = 1'b1; tx_crc_busy = 1'b0; rx_busy = 1'b0; rx_done = 1'b0;

        // D3C (E5 board findings): CAP_RD_CH rewinds the pointer; past-end and unanswered
        // CAP_RD_DATA reads return SLVERR instead of locking the AXI bus.
        axi_write(32'h9020_0044, 32'd5, wr_resp); check(wr_resp == 0 && rx_rd_pair == 5, "D3C CAP_RD_PTR set 5");
        axi_write(32'h9020_0040, 32'd2, wr_resp);
        axi_read(32'h9020_0044, rd_value, rd_resp);
        check(wr_resp == 0 && rd_resp == 0 && rd_value == 0 && rx_rd_pair == 0, "D3C CAP_RD_CH rewinds pointer");
        axi_write(32'h9020_0044, 32'd32759, wr_resp); check(wr_resp == 0, "D3C CAP_RD_PTR last pair");
        axi_read(32'h9020_0048, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'hCAFE_BABE, "D3C CAP_RD_DATA last pair");
        axi_read(32'h9020_0044, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32760, "D3C pointer past end");
        axi_read(32'h9020_0048, rd_value, rd_resp); check(rd_resp == 2, "D3C CAP_RD_DATA past end SLVERR");
        axi_read(32'h9020_0000, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'h4157_4732, "D3C bus alive after past-end read");
        axi_write(32'h9020_0044, 32'd0, wr_resp);
        rx_drop = 1'b1;
        axi_read(32'h9020_0048, rd_value, rd_resp); check(rd_resp == 2, "D3C unanswered CAP_RD_DATA SLVERR");
        rx_drop = 1'b0;
        axi_read(32'h9020_0048, rd_value, rd_resp); check(rd_resp == 0 && rd_value == 32'hCAFE_BABE, "D3C read after watchdog");

        $display("RESULT name=tb_awg_control_v2 PASS=%0d FAIL=%0d", pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "awg_control_v2 acceptance failed");
        $finish;
    end
endmodule

`default_nettype wire
