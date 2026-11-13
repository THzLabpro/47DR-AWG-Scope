`timescale 1ns/1ps
`default_nettype none

module tb_eth_bridge;
    localparam integer MAX_WORDS = 2048;
    localparam integer MAX_BYTES = 24 + 4*MAX_WORDS;
    localparam [31:0] IP_PC = 32'hC0A8_2A0A;
    localparam [15:0] PORT_PC = 16'd49152;

    reg clk_eth = 1'b0;
    reg host_clk = 1'b0;
    reg sample_clk = 1'b0;
    reg ram_clk = 1'b0;
    reg adc_clk = 1'b0;
    reg adc_ram_clk = 1'b0;
    always #1.6 clk_eth = ~clk_eth;
    always #5.0 host_clk = ~host_clk;
    always #0.888888 sample_clk = ~sample_clk;
    always #3.555552 ram_clk = ~ram_clk;
    always #1.2 adc_clk = ~adc_clk;
    always #4.8 adc_ram_clk = ~adc_ram_clk;

    reg rst_eth = 1'b1;
    reg host_resetn = 1'b0;
    reg sample_resetn = 1'b0;
    reg ram_resetn = 1'b0;
    reg adc_resetn = 1'b0;
    reg adc_ram_resetn = 1'b0;

    reg        rx_hdr_valid;
    wire       rx_hdr_ready;
    reg [31:0] rx_src_ip;
    reg [15:0] rx_src_port;
    reg [15:0] rx_length;
    reg [63:0] rx_payload_tdata;
    reg [7:0]  rx_payload_tkeep;
    reg        rx_payload_tvalid;
    wire       rx_payload_tready;
    reg        rx_payload_tlast;
    reg        rx_payload_tuser;
    wire       tx_hdr_valid;
    reg        tx_hdr_ready = 1'b1;
    wire [31:0] tx_dst_ip;
    wire [15:0] tx_dst_port;
    wire [15:0] tx_length;
    wire [63:0] tx_payload_tdata;
    wire [7:0]  tx_payload_tkeep;
    wire        tx_payload_tvalid;
    reg         tx_payload_tready = 1'b1;
    wire        tx_payload_tlast;
    wire        tx_payload_tuser;

    wire [31:0] e_awaddr, e_wdata, e_araddr, e_rdata;
    wire [3:0]  e_wstrb;
    wire [1:0]  e_bresp, e_rresp;
    wire e_awvalid, e_awready, e_wvalid, e_wready, e_bvalid, e_bready;
    wire e_arvalid, e_arready, e_rvalid, e_rready;
    reg  [31:0] j_awaddr, j_wdata, j_araddr;
    reg  [3:0]  j_wstrb;
    wire [31:0] j_rdata;
    wire [1:0]  j_bresp, j_rresp;
    reg j_awvalid, j_wvalid, j_bready, j_arvalid, j_rready;
    wire j_awready, j_wready, j_bvalid, j_arready, j_rvalid;

    wire [31:0] m_awaddr, m_wdata, m_araddr, m_rdata;
    wire [3:0]  m_wstrb;
    wire [1:0]  m_bresp, m_rresp;
    wire m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
    wire m_arvalid, m_arready, m_rvalid, m_rready;

    reg ps_config_done = 1'b1;
    wire [2047:0] dac_data;
    wire [7:0] dac_valid;
    reg [7:0] dac_ready = 8'hff;
    wire running, start_marker, capture_marker, ps_ready;
    wire [7:0] active, fault_channels;
    wire [31:0] wrap_count;
    wire capture_read_req, capture_read_valid, capture_busy, capture_done;
    wire [17:0] capture_read_addr, capture_samples;
    wire [31:0] capture_read_data;

    reg [1535:0] adc_data;
    reg [7:0] adc_valid;
    integer ac, as;
    reg [31:0] adc_counter;
    always @* begin
        adc_data = 1536'd0;
        for (ac=0; ac<8; ac=ac+1)
            for (as=0; as<12; as=as+1)
                adc_data[ac*192 + as*16 +: 16] = adc_counter[15:0] + ac*16'd100 + as;
    end
    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            adc_counter <= 0;
            adc_valid <= 0;
        end else begin
            adc_counter <= adc_counter + 1'b1;
            adc_valid <= 8'hff;
        end
    end

    awg_eth_bridge #(
        .MAX_WORDS(MAX_WORDS),
        .BUILD_ID(32'hE1_2026_11),
        .AXI_TIMEOUT_CYCLES(4096)
    ) dut_bridge (
        .clk_eth(clk_eth), .rst_eth(rst_eth),
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
        .host_clk(host_clk), .host_resetn(host_resetn),
        .m_awaddr(e_awaddr), .m_awvalid(e_awvalid), .m_awready(e_awready),
        .m_wdata(e_wdata), .m_wstrb(e_wstrb), .m_wvalid(e_wvalid), .m_wready(e_wready),
        .m_bresp(e_bresp), .m_bvalid(e_bvalid), .m_bready(e_bready),
        .m_araddr(e_araddr), .m_arvalid(e_arvalid), .m_arready(e_arready),
        .m_rdata(e_rdata), .m_rresp(e_rresp), .m_rvalid(e_rvalid), .m_rready(e_rready)
    );

    axil_arb2 dut_arb (
        .clk(host_clk), .resetn(host_resetn),
        .s0_awaddr(j_awaddr), .s0_awvalid(j_awvalid), .s0_awready(j_awready),
        .s0_wdata(j_wdata), .s0_wstrb(j_wstrb), .s0_wvalid(j_wvalid), .s0_wready(j_wready),
        .s0_bresp(j_bresp), .s0_bvalid(j_bvalid), .s0_bready(j_bready),
        .s0_araddr(j_araddr), .s0_arvalid(j_arvalid), .s0_arready(j_arready),
        .s0_rdata(j_rdata), .s0_rresp(j_rresp), .s0_rvalid(j_rvalid), .s0_rready(j_rready),
        .s1_awaddr(e_awaddr), .s1_awvalid(e_awvalid), .s1_awready(e_awready),
        .s1_wdata(e_wdata), .s1_wstrb(e_wstrb), .s1_wvalid(e_wvalid), .s1_wready(e_wready),
        .s1_bresp(e_bresp), .s1_bvalid(e_bvalid), .s1_bready(e_bready),
        .s1_araddr(e_araddr), .s1_arvalid(e_arvalid), .s1_arready(e_arready),
        .s1_rdata(e_rdata), .s1_rresp(e_rresp), .s1_rvalid(e_rvalid), .s1_rready(e_rready),
        .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid), .m_rready(m_rready)
    );

    awg_subsystem dut_awg (
        .host_clk(host_clk), .host_resetn(host_resetn),
        .sample_clk(sample_clk), .sample_resetn(sample_resetn),
        .ram_clk(ram_clk), .ram_resetn(ram_resetn), .ps_config_done(ps_config_done),
        .s_awaddr(m_awaddr), .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wvalid(m_wvalid), .s_wready(m_wready),
        .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready),
        .s_araddr(m_araddr), .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rvalid(m_rvalid), .s_rready(m_rready),
        .capture_read_req(capture_read_req), .capture_read_addr(capture_read_addr),
        .capture_read_data(capture_read_data), .capture_read_valid(capture_read_valid),
        .capture_busy(capture_busy), .capture_done(capture_done), .capture_samples(capture_samples),
        .dac_data(dac_data), .dac_valid(dac_valid), .dac_ready(dac_ready),
        .running(running), .start_marker(start_marker), .capture_marker(capture_marker),
        .active(active), .fault_channels(fault_channels), .wrap_count(wrap_count), .ps_ready(ps_ready)
    );

    adc_capture dut_capture (
        .adc_clk(adc_clk), .adc_resetn(adc_resetn),
        .ram_clk(adc_ram_clk), .ram_resetn(adc_ram_resetn),
        .host_clk(host_clk), .host_resetn(host_resetn), .arm(capture_marker),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .host_word_addr(capture_read_addr), .host_read(capture_read_req),
        .host_read_data(capture_read_data), .host_read_valid(capture_read_valid),
        .busy(capture_busy), .done(capture_done), .captured_samples(capture_samples)
    );

    reg [7:0] req_buf [0:MAX_BYTES-1];
    reg [31:0] req_words [0:MAX_WORDS-1];
    reg [7:0] resp_buf [0:MAX_BYTES-1];
    integer req_payload_bytes;
    integer resp_bytes_seen;
    integer i, j, timeout;
    integer pass_count, fail_count;
    integer s10_start_cycle, s10_end_cycle;
    real s10_mbps;
    integer s10_bad_replies;
    integer host_cycles;
    reg s9_tracking;
    integer s9_backpressure_cycles;
    integer s9_accepted_count, s9_success_count;
    reg [31:0] s9_reply_seq [0:15];
    integer s9_success_index [0:15];
    reg [31:0] s9_drop_before, s9_eth_drop_before;
    reg [31:0] s9_expected_drops, s9_observed_drops;
    reg s6_channel_ok;
    reg [31:0] s6_expected_word, s6_actual_word;
    reg [31:0] last_resp_seq;
    reg [15:0] last_resp_count, last_resp_status, last_resp_err;
    reg [7:0] last_resp_opcode;
    reg [15:0] last_resp_len;
    reg got_response;
    reg [15:0] cap_model [0:7][0:65519];
    integer cap_model_beats;
    integer cc, ss;

    always @(posedge adc_clk) begin
        if (!adc_resetn)
            cap_model_beats <= 0;
        else if (dut_capture.capture_write && cap_model_beats < 5460) begin
            for (cc=0; cc<8; cc=cc+1)
                for (ss=0; ss<12; ss=ss+1)
                    cap_model[cc][cap_model_beats*12+ss] <= dut_capture.adc_data_pipe[cc][ss*16 +: 16];
            cap_model_beats <= cap_model_beats + 1;
        end
    end

    always @(posedge host_clk) begin
        if (!host_resetn)
            host_cycles <= 0;
        else
            host_cycles <= host_cycles + 1;
    end

    always @(posedge clk_eth) begin
        if (rst_eth)
            s9_backpressure_cycles <= 0;
        else if (s9_tracking &&
                 ((rx_hdr_valid && !rx_hdr_ready) ||
                  (rx_payload_tvalid && !rx_payload_tready)))
            s9_backpressure_cycles <= s9_backpressure_cycles + 1;
    end

    task automatic set_req_u16(input integer off, input [15:0] value);
        begin req_buf[off] = value[7:0]; req_buf[off+1] = value[15:8]; end
    endtask
    task automatic set_req_u32(input integer off, input [31:0] value);
        begin
            req_buf[off] = value[7:0]; req_buf[off+1] = value[15:8];
            req_buf[off+2] = value[23:16]; req_buf[off+3] = value[31:24];
        end
    endtask
    task automatic check(input bit condition, input string name);
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("PASS %s", name);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL %s", name);
            end
        end
    endtask

    task automatic udp_send(
        input [7:0] opcode,
        input [31:0] seq,
        input [31:0] addr,
        input integer count,
        input [15:0] flags,
        input [15:0] magic,
        input [7:0] version,
        input integer length_override,
        input bit bad_user
    );
        integer payload_len, emit_len, beat, b, n;
        reg [63:0] beat_data;
        begin
            for (n=0; n<MAX_BYTES; n=n+1) req_buf[n] = 0;
            set_req_u16(0, magic);
            req_buf[2] = version;
            req_buf[3] = opcode;
            set_req_u32(4, seq);
            set_req_u32(8, addr);
            set_req_u16(12, count);
            set_req_u16(14, flags);
            set_req_u16(16, 0);
            set_req_u16(18, 0);
            set_req_u32(20, 0);
            payload_len = (opcode == 8'd2 && count > 0 && count <= MAX_WORDS) ? 24 + count*4 : 24;
            emit_len = payload_len;
            if (length_override >= 0)
                rx_length = length_override;
            else
                rx_length = payload_len[15:0];
            if (opcode == 8'd2 && count > 0 && count <= MAX_WORDS)
                for (n=0; n<count; n=n+1)
                    set_req_u32(24+n*4, req_words[n]);
            rx_src_ip = IP_PC;
            rx_src_port = PORT_PC;
            @(negedge clk_eth);
            rx_hdr_valid = 1'b1;
            timeout = 0;
            while (timeout < 10000) begin
                @(posedge clk_eth);
                if (rx_hdr_valid && rx_hdr_ready) break;
                timeout = timeout + 1;
            end
            if (timeout >= 10000) begin
                $display("DBG RX header deadlock ready=%0d fifo_ready=%0d rst=%0d sent=%0d", rx_hdr_ready,
                         dut_bridge.rx_fifo_s_ready, rst_eth, dut_bridge.rx_header_sent);
                $fatal(1, "RX header ready timeout");
            end
            @(negedge clk_eth);
            rx_hdr_valid = 1'b0;
            @(negedge clk_eth);
            beat = 0;
            while (beat*8 < emit_len) begin
                beat_data = 64'd0;
                n = 0;
                for (b=0; b<8; b=b+1) begin
                    if (beat*8+b < emit_len) begin
                        beat_data[b*8 +: 8] = req_buf[beat*8+b];
                        n = n + 1;
                    end
                end
                rx_payload_tdata = beat_data;
                rx_payload_tkeep = (n == 8) ? 8'hff : (8'hff >> (8-n));
                rx_payload_tlast = (beat*8 + n >= emit_len);
                rx_payload_tuser = bad_user && rx_payload_tlast;
                rx_payload_tvalid = 1'b1;
                timeout = 0;
                while (timeout < 10000) begin
                    @(posedge clk_eth);
                    if (rx_payload_tvalid && rx_payload_tready) break;
                    timeout = timeout + 1;
                end
                if (timeout >= 10000) $fatal(1, "RX payload ready timeout beat=%0d", beat);
                @(negedge clk_eth);
                rx_payload_tvalid = 1'b0;
                rx_payload_tlast = 1'b0;
                rx_payload_tuser = 1'b0;
                beat = beat + 1;
            end
        end
    endtask

    task automatic udp_receive(output bit received);
        integer wait_cycles, k, valid_bytes;
        begin
            received = 1'b0;
            resp_bytes_seen = 0;
            for (k=0; k<MAX_BYTES; k=k+1) resp_buf[k] = 0;
            wait_cycles = 0;
            while (!tx_hdr_valid && wait_cycles < 200000) begin
                @(negedge clk_eth);
                wait_cycles = wait_cycles + 1;
            end
            if (!tx_hdr_valid) begin
                last_resp_len = 0;
            end else begin
                received = 1'b1;
                last_resp_len = tx_length;
                while (!tx_payload_tvalid && wait_cycles < 220000) begin
                    @(posedge clk_eth);
                    wait_cycles = wait_cycles + 1;
                end
                while (tx_payload_tvalid && wait_cycles < 230000) begin
                    valid_bytes = 0;
                    for (k=0; k<8; k=k+1)
                        if (tx_payload_tkeep[k]) begin
                            resp_buf[resp_bytes_seen] = tx_payload_tdata[k*8 +: 8];
                            resp_bytes_seen = resp_bytes_seen + 1;
                            valid_bytes = valid_bytes + 1;
                        end
                    if (tx_payload_tlast)
                        break;
                    @(posedge clk_eth);
                    wait_cycles = wait_cycles + 1;
                end
                @(negedge clk_eth);
                last_resp_opcode = resp_buf[3];
                last_resp_seq = {resp_buf[7],resp_buf[6],resp_buf[5],resp_buf[4]};
                last_resp_count = {resp_buf[13],resp_buf[12]};
                last_resp_status = {resp_buf[17],resp_buf[16]};
                last_resp_err = {resp_buf[19],resp_buf[18]};
            end
        end
    endtask

    task automatic jtag_write(input [31:0] addr, input [31:0] data,
                              input bit aw_first, output [1:0] resp);
        reg first_done, second_done;
        integer watchdog;
        begin
            j_awaddr = addr;
            j_wdata = data;
            j_wstrb = 4'hf;
            first_done = 0;
            second_done = 0;
            @(negedge host_clk);
            j_awvalid = aw_first;
            j_wvalid = !aw_first;
            j_bready = 0;
            watchdog = 0;
            while (!first_done && watchdog < 10000) begin
                @(posedge host_clk);
                if (aw_first && j_awvalid && j_awready) begin
                    first_done = 1;
                    $display("S11_TRACE kind=AW addr=%08x ready=%0d", j_awaddr, j_awready);
                end else if (!aw_first && j_wvalid && j_wready) begin
                    first_done = 1;
                    $display("S11_TRACE kind=W data=%08x ready=%0d", j_wdata, j_wready);
                end
                watchdog = watchdog + 1;
            end
            if (!first_done) begin
                $display("S11_TRACE timeout=first addr=%08x aw_first=%0d awvalid=%0d wvalid=%0d awready=%0d wready=%0d s0_aw_hold=%0d s0_w_hold=%0d s0_bvalid=%0d s0_rvalid=%0d arb_state=%0d active_src=%0d m_awvalid=%0d m_wvalid=%0d m_bvalid=%0d m_rvalid=%0d",
                         addr, aw_first, j_awvalid, j_wvalid, j_awready, j_wready,
                         dut_arb.s0_aw_hold, dut_arb.s0_w_hold, j_bvalid, j_rvalid,
                         dut_arb.state, dut_arb.active_src,
                         m_awvalid, m_wvalid, m_bvalid, m_rvalid);
                $fatal(1, "JTAG first write channel timeout address=%08x", addr);
            end
            @(negedge host_clk);
            if (aw_first) begin j_awvalid = 0; j_wvalid = 1; end
            else begin j_awvalid = 1; j_wvalid = 0; end
            watchdog = 0;
            while (!second_done && watchdog < 10000) begin
                @(posedge host_clk);
                if (aw_first && j_wvalid && j_wready) begin
                    second_done = 1;
                    $display("S11_TRACE kind=W data=%08x ready=%0d", j_wdata, j_wready);
                end else if (!aw_first && j_awvalid && j_awready) begin
                    second_done = 1;
                    $display("S11_TRACE kind=AW addr=%08x ready=%0d", j_awaddr, j_awready);
                end
                watchdog = watchdog + 1;
            end
            if (!second_done) begin
                $display("JTAG timeout first_done=%0d second_done=%0d awready=%0d wready=%0d arb_aw_hold=%0d arb_w_hold=%0d bvalid=%0d rvalid=%0d", first_done, second_done, j_awready, j_wready, dut_arb.s0_aw_hold, dut_arb.s0_w_hold, j_bvalid, j_rvalid);
                $fatal(1, "JTAG second write channel timeout address=%08x", addr);
            end
            @(negedge host_clk);
            j_awvalid = 0; j_wvalid = 0;
            j_bready = 1;
            watchdog = 0;
            while (watchdog < 10000) begin
                @(posedge host_clk);
                if (j_bvalid && j_bready) begin
                    resp = j_bresp;
                    $display("S11_TRACE kind=B resp=%0d ready=%0d", j_bresp, j_bready);
                    break;
                end
                watchdog = watchdog + 1;
            end
            if (watchdog >= 10000) $fatal(1, "JTAG write response timeout address=%08x", addr);
            @(negedge host_clk);
            j_bready = 0;
        end
    endtask
    task automatic jtag_read(input [31:0] addr, output [31:0] data, output [1:0] resp);
        integer watchdog;
        begin
            j_araddr = addr;
            @(negedge host_clk);
            j_arvalid = 1; j_rready = 0;
            watchdog = 0;
            while (watchdog < 10000) begin
                @(posedge host_clk);
                if (j_arvalid && j_arready) break;
                watchdog = watchdog + 1;
            end
            if (watchdog >= 10000) $fatal(1, "JTAG read request timeout address=%08x", addr);
            @(negedge host_clk);
            j_arvalid = 0; j_rready = 1;
            watchdog = 0;
            while (watchdog < 10000) begin
                @(posedge host_clk);
                if (j_rvalid && j_rready) begin
                    data = j_rdata;
                    resp = j_rresp;
                    $display("S11_TRACE kind=R data=%08x resp=%0d ready=%0d", j_rdata, j_rresp, j_rready);
                    break;
                end
                watchdog = watchdog + 1;
            end
            if (watchdog >= 10000) $fatal(1, "JTAG read response timeout address=%08x", addr);
            @(negedge host_clk);
            j_rready = 0;
        end
    endtask

    task automatic write_packet(input [31:0] base, input integer nwords, input [31:0] seed, input [31:0] seq);
        integer q;
        bit got;
        begin
            for (q=0; q<nwords; q=q+1) req_words[q] = seed + q;
            udp_send(8'd2, seq, base, nwords, 0, 16'hA7E1, 1, -1, 0);
            udp_receive(got);
            check(got && last_resp_status == 0 && last_resp_count == nwords, "write response");
        end
    endtask

    task automatic read_packet(input [31:0] base, input integer nwords, input [31:0] seed, input [31:0] seq);
        integer q;
        bit got;
        reg [31:0] value;
        begin
            udp_send(8'd1, seq, base, nwords, 0, 16'hA7E1, 1, -1, 0);
            udp_receive(got);
            check(got && last_resp_status == 0 && last_resp_count == nwords, "read response");
            for (q=0; q<nwords; q=q+1) begin
                value = {resp_buf[24+q*4+3],resp_buf[24+q*4+2],resp_buf[24+q*4+1],resp_buf[24+q*4]};
                if (value !== seed + q) begin
                    $display("MISMATCH read idx=%0d exp=%08x got=%08x", q, seed+q, value);
                    fail_count = fail_count + 1;
                    q = nwords;
                end
            end
        end
    endtask

    initial begin
        rx_hdr_valid = 0; rx_src_ip = 0; rx_src_port = 0; rx_length = 0;
        rx_payload_tdata = 0; rx_payload_tkeep = 0; rx_payload_tvalid = 0;
        rx_payload_tlast = 0; rx_payload_tuser = 0;
        j_awvalid = 0; j_wvalid = 0; j_bready = 0; j_arvalid = 0; j_rready = 0;
        pass_count = 0; fail_count = 0; cap_model_beats = 0;
        s9_tracking = 0; s9_backpressure_cycles = 0;
        repeat (20) @(posedge host_clk);
        rst_eth = 0; host_resetn = 1; sample_resetn = 1; ram_resetn = 1; adc_resetn = 1; adc_ram_resetn = 1;
        repeat (100) @(posedge host_clk);

        // S1: PING and INFO.
        udp_send(8'd4, 32'h1001, 0, 0, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0 && last_resp_count == 0 && last_resp_seq == 32'h1001, "S1 PING");
        udp_send(8'd3, 32'h1002, 0, 0, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0 && last_resp_count == 16 &&
              {resp_buf[27],resp_buf[26],resp_buf[25],resp_buf[24]} == 32'h4157_4531 &&
              {resp_buf[35],resp_buf[34],resp_buf[33],resp_buf[32]} == MAX_WORDS, "S1 INFO");
        if ($test$plusargs("SMOKE_ONLY")) begin
            $display("RESULT name=tb_eth_bridge_smoke PASS=%0d FAIL=%0d", pass_count, fail_count);
            $finish;
        end

        // S2: 8 packets per channel, then readback.
        for (i=0; i<8; i=i+1) begin
            write_packet(32'h9000_0000 + i*32'h400, 256, 32'h1000_0000+i*32'h1000, 32'h2000+i);
            write_packet(32'h900E_0000 + i*32'h400, 256, 32'h7000_0000+i*32'h1000, 32'h2100+i);
        end
        for (i=0; i<8; i=i+1) begin
            read_packet(32'h9000_0000 + i*32'h400, 256, 32'h1000_0000+i*32'h1000, 32'h2200+i);
            read_packet(32'h900E_0000 + i*32'h400, 256, 32'h7000_0000+i*32'h1000, 32'h2300+i);
        end
        $display("PASS S2 waveform RAM CH0/CH7"); pass_count = pass_count + 1;
        if ($test$plusargs("S2_ONLY")) begin
            $display("RESULT name=tb_eth_bridge_s2 PASS=%0d FAIL=%0d", pass_count, fail_count);
            $finish;
        end

        // S3: one jumbo request.
        write_packet(32'h9000_8000, 2048, 32'h3100_0000, 32'h3001);
        read_packet(32'h9000_8000, 2048, 32'h3100_0000, 32'h3002);
        $display("PASS S3 jumbo"); pass_count = pass_count + 1;
        if ($test$plusargs("S3_ONLY")) begin
            $display("RESULT name=tb_eth_bridge_s3 PASS=%0d FAIL=%0d", pass_count, fail_count);
            $finish;
        end
        if ($test$plusargs("S11_ONLY")) begin
            fork
                begin
                    integer k;
                    reg [1:0] jr;
                    reg [31:0] jd;
                    for (k=0; k<8; k=k+1) begin
                        $display("S11 JTAG transaction=%0d write", k);
                        jtag_write(32'h9020_000C, 32'd32+k, (k % 2) == 0, jr);
                        check(jr == 0, "S11 JTAG write response");
                        $display("S11 JTAG transaction=%0d readback", k);
                        jtag_read(32'h9020_000C, jd, jr);
                        check(jr == 0 && jd == 32'd32+k, "S11 JTAG length readback");
                        jtag_read(32'h9020_0004, jd, jr);
                        check(jr == 0 && jd[2], "S11 JTAG status read");
                        jtag_read(32'h9020_0000, jd, jr);
                        check(jr == 0 && jd == 32'h4157_4731, "S11 JTAG ID read");
                    end
                end
                begin
                    integer k;
                    for (k=0; k<8; k=k+1) begin
                        for (j=0; j<256; j=j+1) req_words[j] = 32'hB000_0000 + k*256+j;
                        udp_send(8'd2, 32'hB000+k, 32'h9002_0000+k*32'h400, 256, 0, 16'hA7E1, 1, -1, 0);
                        udp_receive(got_response);
                        check(got_response && last_resp_status == 0 && last_resp_count == 256, "S11 Ethernet write");
                    end
                end
            join
                    if (fail_count != 0) $fatal(1, "S11 acceptance failed");
                    $display("RESULT name=tb_eth_bridge_s11 PASS=%0d FAIL=%0d", pass_count, fail_count);
            $finish;
        end

        // S4: control registers and an AXI error.
        write_packet(32'h9020_000C, 1, 32'd64, 32'h4001);
        write_packet(32'h9020_0010, 1, 32'h0000_00a5, 32'h4002);
        read_packet(32'h9020_000C, 1, 32'd64, 32'h4003);
        read_packet(32'h9020_0010, 1, 32'h0000_00a5, 32'h4004);
        req_words[0] = 32'd0;
        udp_send(8'd2, 32'h4005, 32'h9020_000C, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 1 && last_resp_err == 0, "S4 invalid register");

        // S5: start, observe running, reject RAM write while running, stop.
        req_words[0] = 32'd2;
        udp_send(8'd2, 32'h5001, 32'h9020_0008, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0, "S5 start");
        udp_send(8'd1, 32'h5002, 32'h9020_0004, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0 && (resp_buf[24] & 8'h01), "S5 running");
        req_words[0] = 32'hdead_beef;
        udp_send(8'd2, 32'h5003, 32'h9000_0000, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 1, "S5 RAM locked");
        req_words[0] = 32'd1;
        udp_send(8'd2, 32'h5004, 32'h9020_0008, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0, "S5 stop");

        // S6: capture, poll done, compare two channels of packed samples.
        req_words[0] = 32'd8;
        udp_send(8'd2, 32'h6001, 32'h9020_0008, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0, "S6 arm");
        timeout = 0;
        while (timeout < 20000) begin
            udp_send(8'd1, 32'h6100+timeout, 32'h9020_0028, 1, 0, 16'hA7E1, 1, -1, 0);
            udp_receive(got_response);
            if (got_response && resp_buf[24] == 2) break;
            timeout = timeout + 1;
        end
        check(timeout < 20000, "S6 capture done");
        udp_send(8'd1, 32'h6200, 32'h9100_0000, 96, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0 && last_resp_count == 96, "S6 CH0 read");
        s6_channel_ok = 1;
        for (i=0; i<96; i=i+1) begin
            s6_actual_word = {resp_buf[24+i*4+3],resp_buf[24+i*4+2],resp_buf[24+i*4+1],resp_buf[24+i*4]};
            s6_expected_word = {cap_model[0][i*2+1],cap_model[0][i*2]};
            if (s6_actual_word !== s6_expected_word) begin
                s6_channel_ok = 0;
                $display("MISMATCH S6 CH0 word=%0d exp=%08x got=%08x", i, s6_expected_word, s6_actual_word);
                i = 96;
            end
        end
        check(s6_channel_ok, "S6 CH0 first 96 words");
        udp_send(8'd1, 32'h6201, 32'h9106_0000, 96, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0 && last_resp_count == 96, "S6 CH3 read");
        s6_channel_ok = 1;
        for (i=0; i<96; i=i+1) begin
            s6_actual_word = {resp_buf[24+i*4+3],resp_buf[24+i*4+2],resp_buf[24+i*4+1],resp_buf[24+i*4]};
            s6_expected_word = {cap_model[3][i*2+1],cap_model[3][i*2]};
            if (s6_actual_word !== s6_expected_word) begin
                s6_channel_ok = 0;
                $display("MISMATCH S6 CH3 word=%0d exp=%08x got=%08x", i, s6_expected_word, s6_actual_word);
                i = 96;
            end
        end
        check(s6_channel_ok, "S6 CH3 first 96 words");

        // S7: duplicate sequence is not executed twice.
        req_words[0] = 32'h1122_3344;
        udp_send(8'd2, 32'h7001, 32'h9001_0000, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0, "S7 first write");
        req_words[0] = 32'h5566_7788;
        udp_send(8'd2, 32'h7001, 32'h9001_0000, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response);
        check(got_response && last_resp_status == 0, "S7 duplicate write");
        read_packet(32'h9001_0000, 1, 32'h1122_3344, 32'h7002);

        // S8: malformed requests.
        udp_send(8'd4, 32'h8001, 0, 0, 0, 16'h1234, 1, -1, 0);
        udp_receive(got_response); check(!got_response, "S8 bad magic drop");
        udp_send(8'd2, 32'h8002, 32'h9000_0000, 1, 0, 16'hA7E1, 1, 24, 0);
        udp_receive(got_response); check(got_response && last_resp_status == 2, "S8 length mismatch");
        udp_send(8'd1, 32'h8003, 32'h9000_0000, MAX_WORDS+1, 0, 16'hA7E1, 1, 24, 0);
        udp_receive(got_response); check(got_response && last_resp_status == 2, "S8 count overflow");
        udp_send(8'd4, 32'h8004, 0, 0, 16'h2, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response); check(got_response && last_resp_status == 2, "S8 flags");
        udp_send(8'd1, 32'h8005, 32'h9000_0002, 1, 0, 16'hA7E1, 1, -1, 0);
        udp_receive(got_response); check(got_response && last_resp_status == 2, "S8 alignment");
        udp_send(8'd4, 32'h8006, 0, 0, 0, 16'hA7E1, 1, -1, 1);
        udp_receive(got_response); check(!got_response, "S8 tuser drop");

        // S9: queue sixteen maximum writes, drain unique replies, then read back each accepted range.
        s9_drop_before = dut_bridge.rx_dropped_count;
        s9_eth_drop_before = dut_bridge.rx_drop_count_eth;
        s9_backpressure_cycles = 0;
        s9_tracking = 1;
        for (i=0; i<16; i=i+1) begin
            for (j=0; j<MAX_WORDS; j=j+1) req_words[j] = 32'h9000_0000 + i*MAX_WORDS+j;
            udp_send(8'd2, 32'h9000+i, 32'h9000_0000 + i*32'h2000, MAX_WORDS, 0, 16'hA7E1, 1, -1, 0);
        end
        s9_tracking = 0;
        repeat (8) @(posedge host_clk);
        s9_expected_drops = dut_bridge.rx_drop_count_eth - s9_eth_drop_before;
        s9_observed_drops = dut_bridge.rx_dropped_count - s9_drop_before;
        check(s9_observed_drops == s9_expected_drops && s9_expected_drops <= 16,
              "S9 drop counter equals dropped packet events");
        s9_accepted_count = 16 - s9_expected_drops;
        s9_success_count = 0;
        for (i=0; i<s9_accepted_count; i=i+1) begin
            udp_receive(got_response);
            check(got_response && last_resp_seq >= 32'h9000 && last_resp_seq < 32'h9010 &&
                  last_resp_status == 0 && last_resp_count == MAX_WORDS, "S9 successful WRITE reply");
            if (got_response && last_resp_status == 0 && last_resp_count == MAX_WORDS &&
                last_resp_seq >= 32'h9000 && last_resp_seq < 32'h9010) begin
                s9_reply_seq[s9_success_count] = last_resp_seq;
                s9_success_index[s9_success_count] = last_resp_seq - 32'h9000;
                s9_success_count = s9_success_count + 1;
            end
        end
        s6_channel_ok = 1;
        for (i=0; i<s9_success_count; i=i+1)
            for (j=i+1; j<s9_success_count; j=j+1)
                if (s9_reply_seq[i] == s9_reply_seq[j]) s6_channel_ok = 0;
        check(s6_channel_ok && s9_success_count == s9_accepted_count, "S9 unique reply sequences");
        for (i=0; i<s9_success_count; i=i+1)
            read_packet(32'h9000_0000 + s9_success_index[i]*32'h2000, MAX_WORDS,
                        32'h9000_0000 + s9_success_index[i]*MAX_WORDS,
                        32'h9100+s9_success_index[i]);
        $display("PASS S9 backpressure_cycles=%0d dropped_packets=%0d replies=%0d readback_packets=%0d",
                 s9_backpressure_cycles, s9_observed_drops, s9_success_count, s9_success_count);

        // S10: throughput measurement.
        s10_bad_replies = 0;
        s10_start_cycle = host_cycles;
        for (i=0; i<64; i=i+1) begin
            for (j=0; j<256; j=j+1) req_words[j] = 32'hA000_0000 + i*256+j;
            udp_send(8'd2, 32'hA000+i, 32'h9000_0000+i*32'h400, 256, 0, 16'hA7E1, 1, -1, 0);
            udp_receive(got_response);
            if (!got_response || {resp_buf[17], resp_buf[16]} != 16'd0)
                s10_bad_replies = s10_bad_replies + 1;
        end
        check(s10_bad_replies == 0, "S10 all replies status OK");
        s10_end_cycle = host_cycles;
        s10_mbps = (64.0*256.0*4.0*100.0e6)/(s10_end_cycle-s10_start_cycle)/1.0e6;
        check(s10_mbps >= 40.0, "S10 throughput >=40 MB/s");
        $display("S10 throughput cycles=%0d bytes=%0d MBps=%0f", s10_end_cycle-s10_start_cycle,
                 64*256*4, s10_mbps);

        // S11: JTAG traffic overlaps Ethernet writes.
        fork
            begin
                integer k;
                for (k=0; k<8; k=k+1) begin
                    reg [1:0] jr;
                    reg [31:0] jd;
                    jtag_write(32'h9020_000C, 32'd32+k, (k % 2) == 0, jr);
                    check(jr == 0, "S11 JTAG write response");
                    jtag_read(32'h9020_000C, jd, jr);
                    check(jr == 0 && jd == 32'd32+k, "S11 JTAG length readback");
                    jtag_read(32'h9020_0004, jd, jr);
                    check(jr == 0 && jd[2], "S11 JTAG status read");
                    jtag_read(32'h9020_0000, jd, jr);
                    check(jr == 0 && jd == 32'h4157_4731, "S11 JTAG ID read");
                end
            end
            begin
                integer k;
                for (k=0; k<8; k=k+1) begin
                    for (j=0; j<256; j=j+1) req_words[j] = 32'hB000_0000 + k*256+j;
                    udp_send(8'd2, 32'hB000+k, 32'h9002_0000+k*32'h400, 256, 0, 16'hA7E1, 1, -1, 0);
                    udp_receive(got_response);
                end
            end
        join
        if (fail_count != 0) $fatal(1, "S11 acceptance failed");
        $display("PASS S11 arbitration overlap"); pass_count = pass_count + 1;

        $display("RESULT name=tb_eth_bridge PASS=%0d FAIL=%0d", pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "E1 acceptance failed");
        $finish;
    end
endmodule

`default_nettype wire
