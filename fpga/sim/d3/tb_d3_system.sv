`timescale 1ps/1fs
`default_nettype none

module tb_d3_system;
    localparam integer MAX_WORDS = 2048;
    localparam integer MAX_BYTES = 24 + MAX_WORDS*4;

    reg clk_eth = 0, host_clk = 0, tx_clk = 0, dac_clk = 0, adc_clk = 0, rx_clk = 0;
    always #1600 clk_eth = ~clk_eth;
    always #5000 host_clk = ~host_clk;
    always #816.32655 dac_clk = ~dac_clk;
    always @(posedge dac_clk) tx_clk <= ~tx_clk;
    always #1200 adc_clk = ~adc_clk;
    always @(posedge adc_clk) rx_clk <= ~rx_clk;

    reg rst_eth = 1, host_resetn = 0, tx_resetn = 0, dac_resetn = 0, adc_resetn = 0, rx_resetn = 0;
    reg rx_hdr_valid = 0;
    wire rx_hdr_ready;
    reg [31:0] rx_src_ip = 0;
    reg [15:0] rx_src_port = 0, rx_length = 0;
    reg [63:0] rx_payload_tdata = 0;
    reg [7:0] rx_payload_tkeep = 0;
    reg rx_payload_tvalid = 0, rx_payload_tlast = 0, rx_payload_tuser = 0;
    wire rx_payload_tready;
    wire tx_hdr_valid;
    reg tx_hdr_ready = 1;
    wire [31:0] tx_dst_ip;
    wire [15:0] tx_dst_port, tx_length;
    wire [63:0] tx_payload_tdata;
    wire [7:0] tx_payload_tkeep;
    wire tx_payload_tvalid, tx_payload_tlast, tx_payload_tuser;
    reg tx_payload_tready = 1;

    wire [31:0] e_awaddr, e_wdata, e_araddr, e_rdata;
    wire [3:0] e_wstrb;
    wire [1:0] e_bresp, e_rresp;
    wire e_awvalid, e_awready, e_wvalid, e_wready, e_bvalid, e_bready, e_arvalid, e_arready, e_rvalid, e_rready;
    reg [31:0] j_awaddr = 0, j_wdata = 0, j_araddr = 0;
    reg [3:0] j_wstrb = 4'hf;
    reg j_awvalid = 0, j_wvalid = 0, j_bready = 0, j_arvalid = 0, j_rready = 0;
    wire [31:0] j_rdata;
    wire [1:0] j_bresp, j_rresp;
    wire j_awready, j_wready, j_bvalid, j_arready, j_rvalid;
    wire [31:0] c_awaddr, c_wdata, c_araddr, c_rdata;
    wire [3:0] c_wstrb;
    wire [1:0] c_bresp, c_rresp;
    wire c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready, c_arvalid, c_arready, c_rvalid, c_rready;

    wire [2:0] tx_h_wr_ch;
    wire tx_h_wr_rewind;
    wire [31:0] tx_h_wr_data;
    wire tx_h_wr_valid, tx_h_wr_ready;
    wire tx_h_wr_ready_masked, tx_h_wr_valid_masked;
    wire [17:0] tx_h_wr_ptr;
    wire tx_h_crc_start;
    wire [2:0] tx_h_crc_ch;
    wire tx_h_crc_busy;
    wire [31:0] tx_h_crc_value;
    wire tx_h_start, tx_h_stop, tx_h_clear_fault;
    wire [12:0] tx_h_length_words;
    wire [7:0] tx_h_mask;
    wire tx_h_running, tx_h_started, tx_h_locked, tx_h_start_rejected;
    wire [7:0] tx_h_faults;
    wire [31:0] tx_h_wrap_count;
    wire tx_start_event_toggle;
    wire [11:0] tx_play_word;
    wire [8*256-1:0] dac_tdata;
    wire [7:0] dac_tvalid;
    reg [7:0] dac_tready = 8'hff;

    wire rx_h_arm, rx_h_abort, rx_h_trig_mode;
    wire [11:0] rx_h_cap_words;
    wire rx_h_busy, rx_h_armed, rx_h_done;
    wire [16:0] rx_h_captured_samples;
    wire [11:0] rx_h_cap_tx_word;
    wire [2:0] rx_h_rd_ch;
    wire [14:0] rx_h_rd_pair;
    wire rx_h_rd_req, rx_h_rd_valid;
    wire [31:0] rx_h_rd_data;
    localparam integer TX_SAMPLE_COUNT = 4096;
    localparam integer CAPTURE_WORDS = 64;
    localparam integer CAPTURE_SAMPLE_COUNT = CAPTURE_WORDS * 24;
    localparam integer CAPTURE_READ_WORDS = CAPTURE_SAMPLE_COUNT / 2;
    reg [15:0] tx_wave_ch0 [0:TX_SAMPLE_COUNT-1];
    reg [15:0] tx_wave_ch1 [0:TX_SAMPLE_COUNT-1];
    reg [15:0] capture_samples [0:CAPTURE_SAMPLE_COUNT-1];
    reg ready_mask_enable = 0;
    reg [31:0] ready_mask_lfsr = 32'h0000_0001;
    reg s9_active = 0;
    reg s7_write_measure = 0, s7_read_measure = 0;
    reg control_write_active = 0, control_read_active = 0;
    reg rx_read_active = 0;
    integer s9_backpressure_cycles = 0;
    integer s7_write_bridge_cycles = 0, s7_write_arb_cycles = 0;
    integer s7_write_control_cycles = 0, s7_write_tx_cycles = 0;
    integer s7_read_bridge_cycles = 0, s7_read_arb_cycles = 0;
    integer s7_read_control_cycles = 0, s7_read_rx_cycles = 0;
    wire tx_write_allow = !ready_mask_enable || (ready_mask_lfsr[2:0] >= 3);
    assign tx_h_wr_ready_masked = tx_h_wr_ready && tx_write_allow;
    assign tx_h_wr_valid_masked = tx_h_wr_valid && tx_write_allow;
    reg [8*192-1:0] adc_tdata = 0;
    reg [7:0] adc_tvalid = 8'hff;
    localparam integer LOOP_DEPTH = 65536;
    localparam [31:0] CRC_CH0 = 32'h9FB4_69E2;
    localparam [31:0] CRC_CH1 = 32'h7ACC_79A3;
    localparam [31:0] CRC_CH2 = 32'h55A0_6FF7;
    reg [13:0] dac_hist [0:7][0:LOOP_DEPTH-1];
    longint signed dac_D = 0;
    longint signed loop_A = 0;
    longint signed adc_n = 0;
    integer loop_distance_violations = 0;
    reg loop_model_started = 0;
    integer dac_ch, dac_lane, adc_ch, adc_lane;

    initial begin
        integer init_ch, init_sample;
        for (init_ch = 0; init_ch < 8; init_ch = init_ch + 1)
            for (init_sample = 0; init_sample < LOOP_DEPTH; init_sample = init_sample + 1)
                dac_hist[init_ch][init_sample] = 14'd0;
        wait (dac_resetn && adc_resetn);
        @(negedge adc_clk);
        loop_A = dac_D - 128;
        adc_n = 0;
        loop_model_started = 1;
        $display("LOOP_MODEL_START D=%0d A=%0d", dac_D, loop_A);
    end

    always @(posedge dac_clk) begin
        if (!dac_resetn) begin
            dac_D <= 0;
        end else begin
            for (dac_ch = 0; dac_ch < 8; dac_ch = dac_ch + 1)
                for (dac_lane = 0; dac_lane < 16; dac_lane = dac_lane + 1)
                    dac_hist[dac_ch][(dac_D + dac_lane) % LOOP_DEPTH] =
                        dac_tdata[dac_ch*256 + dac_lane*16 + 2 +: 14];
            dac_D <= dac_D + 16;
        end
    end

    always @(posedge adc_clk) begin
        if (!adc_resetn) begin
            adc_tvalid <= 0;
            adc_n <= 0;
        end else if (!loop_model_started) begin
            adc_tvalid <= 0;
        end else begin
            adc_tvalid <= 8'hff;
            begin : adc_model_beat
                longint signed first_source;
                longint signed sample_source;
                longint signed distance;
                integer hist_index;
                first_source = loop_A + ((adc_n * 49) / 25);
                distance = dac_D - first_source;
                if (distance < 64 || distance > 60000) begin
                    loop_distance_violations = loop_distance_violations + 1;
                    $display("FAIL LOOP_DISTANCE D=%0d A=%0d n=%0d source=%0d distance=%0d",
                             dac_D, loop_A, adc_n, first_source, distance);
                end
                for (adc_ch = 0; adc_ch < 8; adc_ch = adc_ch + 1) begin
                    for (adc_lane = 0; adc_lane < 12; adc_lane = adc_lane + 1) begin
                        sample_source = loop_A + (((adc_n + adc_lane) * 49) / 25);
                        hist_index = sample_source % LOOP_DEPTH;
                        if (hist_index < 0) hist_index = hist_index + LOOP_DEPTH;
                        adc_tdata[adc_ch*192 + adc_lane*16 +: 16] =
                            {dac_hist[adc_ch][hist_index], 2'b00};
                    end
                end
                adc_n <= adc_n + 12;
            end
        end
    end

    awg_eth_bridge #(.MAX_WORDS(MAX_WORDS), .BUILD_ID(32'hD3A5_2026), .RX_FIFO_DEPTH(32768), .TX_FIFO_DEPTH(32768)) bridge_i (
        .clk_eth(clk_eth), .rst_eth(rst_eth), .rx_hdr_valid(rx_hdr_valid), .rx_hdr_ready(rx_hdr_ready), .rx_src_ip(rx_src_ip), .rx_src_port(rx_src_port), .rx_length(rx_length), .rx_payload_tdata(rx_payload_tdata), .rx_payload_tkeep(rx_payload_tkeep), .rx_payload_tvalid(rx_payload_tvalid), .rx_payload_tready(rx_payload_tready), .rx_payload_tlast(rx_payload_tlast), .rx_payload_tuser(rx_payload_tuser), .tx_hdr_valid(tx_hdr_valid), .tx_hdr_ready(tx_hdr_ready), .tx_dst_ip(tx_dst_ip), .tx_dst_port(tx_dst_port), .tx_length(tx_length), .tx_payload_tdata(tx_payload_tdata), .tx_payload_tkeep(tx_payload_tkeep), .tx_payload_tvalid(tx_payload_tvalid), .tx_payload_tready(tx_payload_tready), .tx_payload_tlast(tx_payload_tlast), .tx_payload_tuser(tx_payload_tuser), .host_clk(host_clk), .host_resetn(host_resetn), .m_awaddr(e_awaddr), .m_awvalid(e_awvalid), .m_awready(e_awready), .m_wdata(e_wdata), .m_wstrb(e_wstrb), .m_wvalid(e_wvalid), .m_wready(e_wready), .m_bresp(e_bresp), .m_bvalid(e_bvalid), .m_bready(e_bready), .m_araddr(e_araddr), .m_arvalid(e_arvalid), .m_arready(e_arready), .m_rdata(e_rdata), .m_rresp(e_rresp), .m_rvalid(e_rvalid), .m_rready(e_rready)
    );
    axil_arb2 arb_i (
        .clk(host_clk), .resetn(host_resetn), .s0_awaddr(j_awaddr), .s0_awvalid(j_awvalid), .s0_awready(j_awready), .s0_wdata(j_wdata), .s0_wstrb(j_wstrb), .s0_wvalid(j_wvalid), .s0_wready(j_wready), .s0_bresp(j_bresp), .s0_bvalid(j_bvalid), .s0_bready(j_bready), .s0_araddr(j_araddr), .s0_arvalid(j_arvalid), .s0_arready(j_arready), .s0_rdata(j_rdata), .s0_rresp(j_rresp), .s0_rvalid(j_rvalid), .s0_rready(j_rready), .s1_awaddr(e_awaddr), .s1_awvalid(e_awvalid), .s1_awready(e_awready), .s1_wdata(e_wdata), .s1_wstrb(e_wstrb), .s1_wvalid(e_wvalid), .s1_wready(e_wready), .s1_bresp(e_bresp), .s1_bvalid(e_bvalid), .s1_bready(e_bready), .s1_araddr(e_araddr), .s1_arvalid(e_arvalid), .s1_arready(e_arready), .s1_rdata(e_rdata), .s1_rresp(e_rresp), .s1_rvalid(e_rvalid), .s1_rready(e_rready), .m_awaddr(c_awaddr), .m_awvalid(c_awvalid), .m_awready(c_awready), .m_wdata(c_wdata), .m_wstrb(c_wstrb), .m_wvalid(c_wvalid), .m_wready(c_wready), .m_bresp(c_bresp), .m_bvalid(c_bvalid), .m_bready(c_bready), .m_araddr(c_araddr), .m_arvalid(c_arvalid), .m_arready(c_arready), .m_rdata(c_rdata), .m_rresp(c_rresp), .m_rvalid(c_rvalid), .m_rready(c_rready)
    );
    awg_control_v2 #(.BUILD_ID(32'hD3A5_2026)) control_i (
        .host_clk(host_clk), .host_resetn(host_resetn), .s_awaddr(c_awaddr), .s_awvalid(c_awvalid), .s_awready(c_awready), .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wvalid(c_wvalid), .s_wready(c_wready), .s_bresp(c_bresp), .s_bvalid(c_bvalid), .s_bready(c_bready), .s_araddr(c_araddr), .s_arvalid(c_arvalid), .s_arready(c_arready), .s_rdata(c_rdata), .s_rresp(c_rresp), .s_rvalid(c_rvalid), .s_rready(c_rready), .ps_ready(1'b1), .tx_h_wr_ch(tx_h_wr_ch), .tx_h_wr_rewind(tx_h_wr_rewind), .tx_h_wr_data(tx_h_wr_data), .tx_h_wr_valid(tx_h_wr_valid), .tx_h_wr_ready(tx_h_wr_ready_masked), .tx_h_wr_ptr(tx_h_wr_ptr), .tx_h_crc_start(tx_h_crc_start), .tx_h_crc_ch(tx_h_crc_ch), .tx_h_crc_busy(tx_h_crc_busy), .tx_h_crc_value(tx_h_crc_value), .tx_h_start(tx_h_start), .tx_h_stop(tx_h_stop), .tx_h_clear_fault(tx_h_clear_fault), .tx_h_length_words(tx_h_length_words), .tx_h_mask(tx_h_mask), .tx_h_running(tx_h_running), .tx_h_started(tx_h_started), .tx_h_faults(tx_h_faults), .tx_h_wrap_count(tx_h_wrap_count), .tx_h_locked(tx_h_locked), .tx_h_start_rejected(tx_h_start_rejected), .rx_h_arm(rx_h_arm), .rx_h_abort(rx_h_abort), .rx_h_trig_mode(rx_h_trig_mode), .rx_h_cap_words(rx_h_cap_words), .rx_h_busy(rx_h_busy), .rx_h_armed(rx_h_armed), .rx_h_done(rx_h_done), .rx_h_captured_samples(rx_h_captured_samples), .rx_h_cap_tx_word(rx_h_cap_tx_word), .rx_h_rd_ch(rx_h_rd_ch), .rx_h_rd_pair(rx_h_rd_pair), .rx_h_rd_req(rx_h_rd_req), .rx_h_rd_data(rx_h_rd_data), .rx_h_rd_valid(rx_h_rd_valid), .dbg_cmd_busy()
    );
    awg_tx tx_i (.host_clk(host_clk), .host_resetn(host_resetn), .tx_clk(tx_clk), .tx_resetn(tx_resetn), .dac_clk(dac_clk), .dac_resetn(dac_resetn), .ps_config_done(1'b1), .h_wr_ch(tx_h_wr_ch), .h_wr_rewind(tx_h_wr_rewind), .h_wr_data(tx_h_wr_data), .h_wr_valid(tx_h_wr_valid_masked), .h_wr_ready(tx_h_wr_ready), .h_wr_ptr(tx_h_wr_ptr), .h_crc_start(tx_h_crc_start), .h_crc_ch(tx_h_crc_ch), .h_crc_busy(tx_h_crc_busy), .h_crc_value(tx_h_crc_value), .h_start(tx_h_start), .h_stop(tx_h_stop), .h_clear_fault(tx_h_clear_fault), .h_length_words(tx_h_length_words), .h_mask(tx_h_mask), .h_running(tx_h_running), .h_started(tx_h_started), .h_faults(tx_h_faults), .h_wrap_count(tx_h_wrap_count), .h_locked(tx_h_locked), .h_start_rejected(tx_h_start_rejected), .dac_tdata(dac_tdata), .dac_tvalid(dac_tvalid), .dac_tready(dac_tready), .tx_start_event(), .tx_start_event_toggle(tx_start_event_toggle), .tx_play_word(tx_play_word));
    awg_rx rx_i (.adc_clk(adc_clk), .adc_resetn(adc_resetn), .dac_clk(dac_clk), .tx_clk(tx_clk), .tx_resetn(tx_resetn), .rx_clk(rx_clk), .rx_resetn(rx_resetn), .host_clk(host_clk), .host_resetn(host_resetn), .h_arm(rx_h_arm), .h_abort(rx_h_abort), .h_trig_mode(rx_h_trig_mode), .h_cap_words(rx_h_cap_words), .h_busy(rx_h_busy), .h_armed(rx_h_armed), .h_done(rx_h_done), .h_captured_samples(rx_h_captured_samples), .h_cap_tx_word(rx_h_cap_tx_word), .h_rd_ch(rx_h_rd_ch), .h_rd_pair(rx_h_rd_pair), .h_rd_req(rx_h_rd_req), .h_rd_data(rx_h_rd_data), .h_rd_valid(rx_h_rd_valid), .adc_tdata(adc_tdata), .adc_tvalid(adc_tvalid), .tx_start_event_toggle(tx_start_event_toggle), .tx_play_word(tx_play_word));

    reg [7:0] req_buf [0:MAX_BYTES-1];
    reg [31:0] req_words [0:MAX_WORDS-1];
    reg [7:0] resp_buf [0:MAX_BYTES-1];
    integer pass_count = 0, fail_count = 0, timeout = 0, req_len = 0, resp_len = 0, host_cycles = 0;
    integer i, n, b, beat;
    integer cmd_seq_counter = 32'h1000;
    reg [31:0] last_seq, last_data;
    reg [15:0] last_status, last_count;

    always @(posedge host_clk) if (host_resetn) host_cycles <= host_cycles + 1;

    always @(posedge host_clk) begin
        if (!host_resetn) begin
            ready_mask_lfsr <= 32'h0000_0001;
            control_write_active <= 0;
            control_read_active <= 0;
            rx_read_active <= 0;
            s9_backpressure_cycles <= 0;
            s7_write_bridge_cycles <= 0;
            s7_write_arb_cycles <= 0;
            s7_write_control_cycles <= 0;
            s7_write_tx_cycles <= 0;
            s7_read_bridge_cycles <= 0;
            s7_read_arb_cycles <= 0;
            s7_read_control_cycles <= 0;
            s7_read_rx_cycles <= 0;
        end else begin
            ready_mask_lfsr <= {ready_mask_lfsr[30:0],
                                ready_mask_lfsr[31] ^ ready_mask_lfsr[21] ^
                                ready_mask_lfsr[1] ^ ready_mask_lfsr[0]};
            if ((c_awvalid && c_awready) || (c_wvalid && c_wready))
                control_write_active <= 1;
            if (c_bvalid && c_bready)
                control_write_active <= 0;
            if (c_arvalid && c_arready)
                control_read_active <= 1;
            if (c_rvalid && c_rready)
                control_read_active <= 0;
            if (rx_h_rd_req)
                rx_read_active <= 1;
            if (rx_h_rd_valid)
                rx_read_active <= 0;

            if (s9_active && tx_h_wr_valid && !tx_h_wr_ready_masked)
                s9_backpressure_cycles <= s9_backpressure_cycles + 1;

            if (s7_write_measure) begin
                if ((e_awvalid && (!c_awvalid || !c_awready)) ||
                    (e_wvalid && (!c_wvalid || !c_wready)))
                    s7_write_arb_cycles <= s7_write_arb_cycles + 1;
                else if (tx_h_wr_valid && !tx_h_wr_ready_masked)
                    s7_write_tx_cycles <= s7_write_tx_cycles + 1;
                else if (control_write_active)
                    s7_write_control_cycles <= s7_write_control_cycles + 1;
                else
                    s7_write_bridge_cycles <= s7_write_bridge_cycles + 1;
            end
            if (s7_read_measure) begin
                if (e_arvalid && (!c_arvalid || !c_arready))
                    s7_read_arb_cycles <= s7_read_arb_cycles + 1;
                else if (rx_read_active)
                    s7_read_rx_cycles <= s7_read_rx_cycles + 1;
                else if (control_read_active)
                    s7_read_control_cycles <= s7_read_control_cycles + 1;
                else
                    s7_read_bridge_cycles <= s7_read_bridge_cycles + 1;
            end
        end
    end

    task automatic set_u16(input integer off, input [15:0] v); begin req_buf[off]=v[7:0]; req_buf[off+1]=v[15:8]; end endtask
    task automatic set_u32(input integer off, input [31:0] v); begin req_buf[off]=v[7:0]; req_buf[off+1]=v[15:8]; req_buf[off+2]=v[23:16]; req_buf[off+3]=v[31:24]; end endtask
    task automatic check(input bit ok, input string name); begin if(ok) begin pass_count=pass_count+1; $display("PASS %s",name); end else begin fail_count=fail_count+1; $display("FAIL %s",name); end end endtask

    task automatic udp_send(input [7:0] opcode, input [31:0] seq, input [31:0] addr, input integer count, input [15:0] flags);
        reg [63:0] q; integer bytes, k;
        begin
            for(k=0;k<MAX_BYTES;k=k+1) req_buf[k]=0;
            bytes = (opcode==2 && count>0) ? 24+count*4 : 24;
            set_u16(0,16'hA7E1); req_buf[2]=1; req_buf[3]=opcode; set_u32(4,seq); set_u32(8,addr); set_u16(12,count); set_u16(14,flags); set_u16(16,0); set_u16(18,0); set_u32(20,0);
            if(opcode==2) for(k=0;k<count;k=k+1) set_u32(24+k*4,req_words[k]);
            rx_src_ip=32'hC0A8_2A0A; rx_src_port=16'd49152; rx_length=bytes[15:0];
            @(negedge clk_eth); rx_hdr_valid=1; timeout=0; while(!(rx_hdr_valid&&rx_hdr_ready)&&timeout<10000) begin @(posedge clk_eth); timeout=timeout+1; end
            @(negedge clk_eth); rx_hdr_valid=0;
            beat=0; while(beat*8<bytes) begin q=0; for(b=0;b<8;b=b+1) if(beat*8+b<bytes) q[b*8 +:8]=req_buf[beat*8+b]; rx_payload_tdata=q; rx_payload_tkeep=(beat*8+8<=bytes)?8'hff:((8'h1<<(bytes-beat*8))-8'h1); rx_payload_tlast=(beat*8+8>=bytes); rx_payload_tvalid=1; @(posedge clk_eth); while(!rx_payload_tready) @(posedge clk_eth); @(negedge clk_eth); rx_payload_tvalid=0; beat=beat+1; end
        end
    endtask

    task automatic udp_receive(output bit got);
        integer k; integer guard; bit done;
        begin
            got=0; resp_len=0; timeout=0; done=0;
            while(!tx_hdr_valid&&timeout<20000) begin @(posedge clk_eth); timeout=timeout+1; end
            if(!tx_hdr_valid) begin $display("UDP_RX_HEADER_TIMEOUT"); last_status=16'd1; last_count=0; fail_count=fail_count+1; disable udp_receive; end
            guard=0;
            while(!done&&guard<20000&&resp_len<MAX_BYTES) begin
                @(posedge clk_eth); guard=guard+1;
                if(tx_payload_tvalid&&tx_payload_tready) begin
                    for(k=0;k<8;k=k+1) if(tx_payload_tkeep[k]) begin resp_buf[resp_len]=tx_payload_tdata[k*8 +:8]; resp_len=resp_len+1; end
                    if(tx_payload_tlast) done=1;
                end
            end
            if(!done) begin $display("UDP_RX_PAYLOAD_TIMEOUT guard=%0d len=%0d hdr=%b valid=%b last=%b",guard,resp_len,tx_hdr_valid,tx_payload_tvalid,tx_payload_tlast); last_status=16'd1; last_count=0; fail_count=fail_count+1; disable udp_receive; end
            last_seq={resp_buf[7],resp_buf[6],resp_buf[5],resp_buf[4]}; last_count={resp_buf[13],resp_buf[12]}; last_status={resp_buf[17],resp_buf[16]}; got=1;
        end
    endtask

    task automatic cmd_write(input [31:0] addr, input [31:0] value, output [1:0] status); bit got; begin req_words[0]=value; cmd_seq_counter=cmd_seq_counter+1; udp_send(2,cmd_seq_counter,addr,1,0); udp_receive(got); status=last_status[1:0]; if(!got) $display("CMD_NO_RESPONSE addr=%08x",addr); end endtask
    task automatic reg_read(input [31:0] addr, output [31:0] value, output [1:0] status); bit got; begin udp_send(1,32'h2000+addr,addr,1,0); udp_receive(got); value={resp_buf[27],resp_buf[26],resp_buf[25],resp_buf[24]}; status=last_status[1:0]; end endtask
    task automatic data_write(input [31:0] addr, input integer count, input [31:0] seed, output [1:0] status); bit got; integer k; begin for(k=0;k<count;k=k+1) req_words[k]=seed+k; udp_send(2,32'h3000+seed,addr,count,1); udp_receive(got); status=last_status[1:0]; $display("DATA_WRITE addr=%08x count=%0d got=%b status=%0d resp_count=%0d resp_len=%0d",addr,count,got,status,last_count,resp_len); end endtask
    task automatic data_read(input [31:0] addr, input integer count, output [1:0] status); bit got; begin udp_send(1,32'h4000+addr,addr,count,1); udp_receive(got); status=last_status[1:0]; end endtask

    function automatic [15:0] wave_sample(input integer channel, input integer sample_index);
        integer sample_value;
        begin
            sample_value = (sample_index * 16'h02F1 + channel * 16'h1234 + 16'h0155) % 16384;
            wave_sample = sample_value << 2;
        end
    endfunction

    function automatic [31:0] wave_crc(input integer channel, input integer sample_count);
        reg [31:0] crc;
        reg [15:0] sample_value;
        reg [7:0] data_byte;
        integer sample_index, byte_index, bit_index;
        begin
            crc = 32'hFFFF_FFFF;
            for (sample_index = 0; sample_index < sample_count; sample_index = sample_index + 1) begin
                sample_value = wave_sample(channel, sample_index);
                for (byte_index = 0; byte_index < 2; byte_index = byte_index + 1) begin
                    data_byte = byte_index == 0 ? sample_value[7:0] : sample_value[15:8];
                    crc = crc ^ data_byte;
                    for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                        crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
                end
            end
            wave_crc = ~crc;
        end
    endfunction

    task automatic data_write_wave(input integer channel, input integer first_word,
                                   input integer count, output [1:0] status);
        bit got;
        integer word_index;
        reg [15:0] sample_lo, sample_hi;
        begin
            for (word_index = 0; word_index < count; word_index = word_index + 1) begin
                sample_lo = wave_sample(channel, (first_word + word_index) * 2);
                sample_hi = wave_sample(channel, (first_word + word_index) * 2 + 1);
                req_words[word_index] = {sample_hi, sample_lo};
            end
            udp_send(2, 32'h6000_0000 + channel * 2048 + first_word,
                     32'h9020_0038, count, 1);
            udp_receive(got);
            status = last_status[1:0];
            $display("DATA_WRITE_WAVE channel=%0d first_word=%0d count=%0d got=%b status=%0d resp_count=%0d",
                     channel, first_word, count, got, status, last_count);
        end
    endtask

    task automatic fill_expected_wave(input integer channel);
        integer sample_index;
        begin
            for (sample_index = 0; sample_index < TX_SAMPLE_COUNT; sample_index = sample_index + 1) begin
                if (channel == 0)
                    tx_wave_ch0[sample_index] = wave_sample(channel, sample_index);
                else
                    tx_wave_ch1[sample_index] = wave_sample(channel, sample_index);
            end
        end
    endtask

    task automatic wait_crc_idle(output bit idle);
        integer poll;
        reg [31:0] status_value;
        reg [1:0] status;
        begin
            idle = 0;
            repeat (64) @(posedge host_clk);
            for (poll = 0; poll < 500; poll = poll + 1) begin
                reg_read(32'h9020_0004, status_value, status);
                if (status == 0 && status_value[8] == 0) begin
                    idle = 1;
                    disable wait_crc_idle;
                end
                repeat (256) @(posedge host_clk);
            end
        end
    endtask

    task automatic read_capture_samples(input integer channel, output bit good);
        integer chunk_index;
        integer word_index;
        integer sample_base;
        bit got;
        reg [1:0] status;
        begin
            good = 1;
            cmd_write(32'h9020_0040, channel, status);
            check(status == 0, "capture channel select");
            cmd_write(32'h9020_0044, 0, status);
            check(status == 0, "capture pointer rewind");
            good = 1;
            for (chunk_index = 0; chunk_index < CAPTURE_READ_WORDS / 256; chunk_index = chunk_index + 1) begin
                udp_send(1, 32'hC000_0000 + channel * 16 + chunk_index,
                         32'h9020_0048, 256, 1);
                udp_receive(got);
                status = last_status[1:0];
                good = got && status == 0 && last_count == 256 && resp_len == 24 + 256 * 4;
                if (!good) begin
                    check(0, "capture chunk full response");
                    disable read_capture_samples;
                end
                check(good, "capture chunk full response");
                sample_base = chunk_index * 512;
                for (word_index = 0; word_index < 256; word_index = word_index + 1) begin
                    capture_samples[sample_base + word_index * 2] =
                        {resp_buf[25 + word_index * 4], resp_buf[24 + word_index * 4]};
                    capture_samples[sample_base + word_index * 2 + 1] =
                        {resp_buf[27 + word_index * 4], resp_buf[26 + word_index * 4]};
                end
            end
            good = 1;
            check(good, "capture full response");
        end
    endtask

    task automatic compare_capture(input integer channel, output integer found_offset,
                                   output integer found_phase, output integer mismatch_count,
                                   output integer match_count, output integer first_nonzero,
                                   output integer compared_count);
        integer phase;
        integer sample_index;
        integer source_offset;
        integer candidate_offset;
        integer occurrences;
        integer mismatches_here;
        integer best_mismatches;
        bit good;
        reg [15:0] wanted;
        begin
            read_capture_samples(channel, good);
            found_offset = -1;
            found_phase = -1;
            mismatch_count = CAPTURE_SAMPLE_COUNT + 1;
            match_count = 0;
            first_nonzero = -1;
            compared_count = 0;
            if (!good) disable compare_capture;
            for (sample_index = 0; sample_index < CAPTURE_SAMPLE_COUNT; sample_index = sample_index + 1)
                if (first_nonzero < 0 && capture_samples[sample_index] != 16'd0)
                    first_nonzero = sample_index;
            if (first_nonzero >= 0)
                compared_count = CAPTURE_SAMPLE_COUNT - first_nonzero;
            if (capture_samples[0] == 16'd0)
                $display("CAPTURE_FIRST_NONZERO channel=%0d index=%0d", channel, first_nonzero);

            source_offset = -1;
            occurrences = 0;
            for (sample_index = 0; sample_index < TX_SAMPLE_COUNT; sample_index = sample_index + 1) begin
                if (channel == 0)
                    wanted = tx_wave_ch0[sample_index];
                else
                    wanted = tx_wave_ch1[sample_index];
                if (first_nonzero >= 0 && capture_samples[first_nonzero] === wanted) begin
                    source_offset = sample_index;
                    occurrences = occurrences + 1;
                end
            end

            best_mismatches = compared_count + 1;
            if (occurrences == 1 && compared_count > 0) begin
                for (phase = 0; phase < 25; phase = phase + 1) begin
                    candidate_offset = source_offset - ((first_nonzero * 49 + phase) / 25);
                    if (candidate_offset < 0) candidate_offset = candidate_offset + TX_SAMPLE_COUNT;
                    mismatches_here = 0;
                    for (sample_index = first_nonzero; sample_index < CAPTURE_SAMPLE_COUNT; sample_index = sample_index + 1) begin
                        if (channel == 0)
                            wanted = tx_wave_ch0[(candidate_offset + ((sample_index * 49 + phase) / 25)) % TX_SAMPLE_COUNT];
                        else
                            wanted = tx_wave_ch1[(candidate_offset + ((sample_index * 49 + phase) / 25)) % TX_SAMPLE_COUNT];
                        if (capture_samples[sample_index] !== wanted)
                            mismatches_here = mismatches_here + 1;
                    end
                    if (mismatches_here < best_mismatches) begin
                        best_mismatches = mismatches_here;
                        found_offset = candidate_offset;
                        found_phase = phase;
                    end
                    if (mismatches_here == 0)
                        match_count = match_count + 1;
                end
            end
            mismatch_count = occurrences == 1 ? best_mismatches : compared_count;
            $display("CAPTURE_COMPARE channel=%0d o=%0d p=%0d solutions=%0d compared=%0d mismatches=%0d first_nonzero=%0d",
                     channel, found_offset, found_phase, match_count,
                     compared_count, mismatch_count, first_nonzero);
        end
    endtask

    task automatic jtag_write(input [31:0] addr, input [31:0] value); integer t; begin j_awaddr=addr; j_wdata=value; @(negedge host_clk); j_awvalid=1; j_wvalid=1; while(!(j_awvalid&&j_awready&&j_wvalid&&j_wready)) @(posedge host_clk); @(negedge host_clk); j_awvalid=0; j_wvalid=0; j_bready=1; t=0; while(!j_bvalid&&t<10000) begin @(posedge host_clk); t=t+1; end @(negedge host_clk); j_bready=0; end endtask
    task automatic jtag_read(input [31:0] addr, output [31:0] value); integer t; begin j_araddr=addr; @(negedge host_clk); j_arvalid=1; while(!(j_arvalid&&j_arready)) @(posedge host_clk); @(negedge host_clk); j_arvalid=0; j_rready=1; t=0; while(!j_rvalid&&t<10000) begin @(posedge host_clk); t=t+1; end value=j_rdata; @(negedge host_clk); j_rready=0; end endtask

    initial begin
        reg [31:0] v, status_value;
        reg [1:0] st;
        bit got, crc_idle, capture_good, valid_capture;
        integer k, j, start_cycle, end_cycle, offset0, offset1, mismatch0, mismatch1;
        integer phase0, phase1, solutions0, solutions1, first_nonzero0, first_nonzero1;
        integer compared0, compared1, s4_o_signed, s4_o_mod;
        integer cap_tx_word, observed_start_word, start_error_words;
        real mbps;

        repeat (20) @(posedge host_clk);
        rst_eth = 0;
        host_resetn = 1;
        tx_resetn = 1;
        dac_resetn = 1;
        adc_resetn = 1;
        rx_resetn = 1;
        repeat (100) @(posedge host_clk);

        $display("WAVE_CRC_REF ch0=%08x ch1=%08x ch2=%08x",
                 wave_crc(0, TX_SAMPLE_COUNT), wave_crc(1, TX_SAMPLE_COUNT),
                 wave_crc(2, TX_SAMPLE_COUNT));
        check(wave_crc(0, TX_SAMPLE_COUNT) == CRC_CH0 &&
              wave_crc(1, TX_SAMPLE_COUNT) == CRC_CH1 &&
              wave_crc(2, TX_SAMPLE_COUNT) == CRC_CH2,
              "waveform CRC reference constants");

        udp_send(4, 32'h1, 0, 0, 0);
        udp_receive(got);
        check(got && last_status == 0 && last_count == 0, "S1 PING");
        reg_read(32'h9020_0000, v, st);
        check(st == 0 && v == 32'h4157_4732, "S1 ID");
        reg_read(32'h9020_0020, v, st);
        check(st == 0 && v == 32'h0003_0001, "S1 ABI");

        cmd_write(32'h9020_0030, 0, st);
        check(st == 0, "S2 select ch0");
        for (k = 0; k < 8; k = k + 1) begin
            data_write_wave(0, k * 256, 256, st);
            check(st == 0 && last_count == 256, "S2 ch0 packet");
        end
        fill_expected_wave(0);
        repeat (128) @(posedge host_clk);
        reg_read(32'h9020_0034, v, st);
        check(st == 0 && v == 4096, "S2 ch0 TX_WR_PTR=4096");
        cmd_write(32'h9020_000c, 128, st);
        check(st == 0, "S2 length");
        cmd_write(32'h9020_0010, 3, st);
        check(st == 0, "S2 mask");
        cmd_write(32'h9020_0008, 16, st);
        check(st == 0, "S2 ch0 CRC command");
        wait_crc_idle(crc_idle);
        check(crc_idle, "S2 ch0 CRC STATUS bit8 clears");
        reg_read(32'h9020_003c, v, st);
        $display("S2_CRC channel=0 expected=%08x actual=%08x", CRC_CH0, v);
        check(st == 0 && v == CRC_CH0, "S2 ch0 CRC");

        cmd_write(32'h9020_0030, 1, st);
        check(st == 0, "S2 select ch1");
        for (k = 0; k < 8; k = k + 1) begin
            data_write_wave(1, k * 256, 256, st);
            check(st == 0 && last_count == 256, "S2 ch1 packet");
        end
        fill_expected_wave(1);
        repeat (128) @(posedge host_clk);
        reg_read(32'h9020_0034, v, st);
        check(st == 0 && v == 4096, "S2 ch1 TX_WR_PTR=4096");
        cmd_write(32'h9020_0008, 16, st);
        check(st == 0, "S2 ch1 CRC command");
        wait_crc_idle(crc_idle);
        check(crc_idle, "S2 ch1 CRC STATUS bit8 clears");
        reg_read(32'h9020_003c, v, st);
        $display("S2_CRC channel=1 expected=%08x actual=%08x", CRC_CH1, v);
        check(st == 0 && v == CRC_CH1, "S2 ch1 CRC");

        cmd_write(32'h9020_004c, (CAPTURE_WORDS << 16) | 1, st);
        check(st == 0, "S4 event capture config");
        cmd_write(32'h9020_0008, 8, st);
        check(st == 0, "S4 event arm");
        cmd_write(32'h9020_0008, 2, st);
        check(st == 0, "S4 start");
        for (k = 0; k < 200000 && !rx_h_done; k = k + 1) @(posedge host_clk);
        check(rx_h_done, "S4 capture done");
        reg_read(32'h9020_002c, v, st);
        check(st == 0 && v == CAPTURE_SAMPLE_COUNT, "S4 CAP_SAMPLES=1536");
        compare_capture(0, offset0, phase0, mismatch0, solutions0, first_nonzero0, compared0);
        check(offset0 >= 0 && solutions0 == 1 && mismatch0 == 0 && compared0 >= 1400, "S4 ch0 point comparison");
        compare_capture(1, offset1, phase1, mismatch1, solutions1, first_nonzero1, compared1);
        check(offset1 >= 0 && solutions1 == 1 && mismatch1 == 0 && compared1 >= 1400, "S4 ch1 point comparison");
        check(first_nonzero0 >= 0 && first_nonzero0 <= 120 &&
              first_nonzero1 >= 0 && first_nonzero1 <= 120, "S4 first_nonzero <=120");
        check(offset0 == offset1, "S4 channel offsets match");
        reg_read(32'h9020_0050, v, st);
        cap_tx_word = v[11:0];
        s4_o_signed = offset0;
        if (s4_o_signed > TX_SAMPLE_COUNT/2) s4_o_signed = s4_o_signed - TX_SAMPLE_COUNT;
        s4_o_mod = ((s4_o_signed % TX_SAMPLE_COUNT) + TX_SAMPLE_COUNT) % TX_SAMPLE_COUNT;
        observed_start_word = offset0 >= 0 ? s4_o_mod / 32 : -1;
        start_error_words = observed_start_word >= 0 ?
                            (observed_start_word - cap_tx_word + 128) % 128 : -1;
        if (start_error_words > 64) start_error_words = 128 - start_error_words;
        $display("S4_START o=%0d o_signed=%0d p=%0d first_nonzero_ch0=%0d compared_ch0=%0d first_nonzero_ch1=%0d compared_ch1=%0d cap_tx_word=%0d observed_start_word=%0d error_words=%0d",
                 offset0, s4_o_signed, phase0, first_nonzero0, compared0,
                 first_nonzero1, compared1,
                 cap_tx_word, observed_start_word, start_error_words);
        check(st == 0 && offset0 >= 0 && start_error_words <= 24, "S4 CAP_TX_WORD error <=24 words");

        cmd_write(32'h9020_0008, 1, st);
        check(st == 0, "S5 stop before manual run");
        cmd_write(32'h9020_004c, CAPTURE_WORDS << 16, st);
        check(st == 0, "S5 manual capture config");
        cmd_write(32'h9020_0008, 2, st);
        check(st == 0, "S5 start");
        cmd_write(32'h9020_0008, 8, st);
        check(st == 0, "S5 manual arm");
        for (k = 0; k < 200000 && !rx_h_done; k = k + 1) @(posedge host_clk);
        check(rx_h_done, "S5 manual done");
        reg_read(32'h9020_002c, v, st);
        check(st == 0 && v == CAPTURE_SAMPLE_COUNT, "S5 CAP_SAMPLES=1536");
        compare_capture(0, offset0, phase0, mismatch0, solutions0, first_nonzero0, compared0);
        check(offset0 >= 0 && solutions0 == 1 && mismatch0 == 0 && compared0 >= 1400, "S5 ch0 point comparison");
        compare_capture(1, offset1, phase1, mismatch1, solutions1, first_nonzero1, compared1);
        check(offset1 >= 0 && solutions1 == 1 && mismatch1 == 0 && compared1 >= 1400, "S5 ch1 point comparison");
        check(offset0 == offset1, "S5 channel offsets match");
        $display("S5_CAPTURE ch0_o=%0d ch0_p=%0d ch0_first_nonzero=%0d ch0_compared=%0d ch1_o=%0d ch1_p=%0d ch1_first_nonzero=%0d ch1_compared=%0d mismatches_ch0=%0d mismatches_ch1=%0d",
                 offset0, phase0, first_nonzero0, compared0,
                 offset1, phase1, first_nonzero1, compared1, mismatch0, mismatch1);
        cmd_write(32'h9020_0008, 1, st);
        check(st == 0, "S5 stop after capture");

        cmd_write(32'h9020_000c, 512, st);
        cmd_write(32'h9020_0008, 2, st);
        check(st == 1, "S3 insufficient start SLVERR");
        cmd_write(32'h9020_000c, 128, st);
        cmd_write(32'h9020_0008, 2, st);
        check(st == 0, "S3 valid start");
        cmd_write(32'h9020_000c, 64, st);
        check(st == 1, "S3 locked length SLVERR");
        cmd_write(32'h9020_0008, 1, st);
        check(st == 0, "S3 stop");

        fork
            jtag_write(32'h9020_0010, 32'h5);
            begin reg_read(32'h9020_0000, v, st); end
        join
        check(st == 0 && v == 32'h4157_4732, "S6 JTAG and Ethernet overlap");

        cmd_write(32'h9020_004c, (CAPTURE_WORDS << 16) | 1, st);
        cmd_write(32'h9020_0040, 0, st);
        cmd_write(32'h9020_0008, 8, st);
        check(st == 0, "S8 event arm without start");
        reg_read(32'h9020_0028, status_value, st);
        check(st == 0 && status_value[2] && status_value[0], "S8 CAP_STATUS armed and busy");
        data_read(32'h9020_0048, 1, st);
        check(st == 1 && last_count == 0, "S8 busy CAP_RD_DATA returns AXI_ERR");
        cmd_write(32'h9020_0008, 32, st);
        check(st == 0, "S8 abort");
        reg_read(32'h9020_0028, status_value, st);
        check(st == 0 && !status_value[2] && !status_value[0], "S8 abort clears armed and busy");
        cmd_write(32'h9020_0008, 8, st);
        check(st == 0, "S8 rearm succeeds");
        reg_read(32'h9020_0028, status_value, st);
        check(st == 0 && status_value[2], "S8 rearm armed status");
        cmd_write(32'h9020_0008, 32, st);
        check(st == 0, "S8 cleanup abort");

        cmd_write(32'h9020_0030, 2, st);
        check(st == 0, "S9 select ch2");
        s9_backpressure_cycles = 0;
        @(negedge host_clk);
        ready_mask_enable = 1;
        s9_active = 1;
        for (k = 0; k < 8; k = k + 1) begin
            data_write_wave(2, k * 256, 256, st);
            check(st == 0 && last_count == 256, "S9 backpressured write packet");
        end
        @(negedge host_clk);
        s9_active = 0;
        ready_mask_enable = 0;
        check(s9_backpressure_cycles > 0, "S9 randomized AWG TX backpressure observed");
        repeat (128) @(posedge host_clk);
        reg_read(32'h9020_0034, v, st);
        check(st == 0 && v == 4096, "S9 TX_WR_PTR=4096");
        cmd_write(32'h9020_000c, 128, st);
        cmd_write(32'h9020_0008, 16, st);
        check(st == 0, "S9 CRC command");
        wait_crc_idle(crc_idle);
        check(crc_idle, "S9 CRC STATUS bit8 clears");
        reg_read(32'h9020_003c, v, st);
        $display("S9_BACKPRESSURE cycles=%0d CRC_expected=%08x CRC_actual=%08x",
                 s9_backpressure_cycles, CRC_CH2, v);
        check(st == 0 && v == CRC_CH2, "S9 backpressured CRC");

        cmd_write(32'h9020_0008, 1, st);
        check(st == 0, "S7 stop before throughput write");
        cmd_write(32'h9020_0030, 0, st);
        check(st == 0, "S7 select ch0");
        s7_write_bridge_cycles = 0;
        s7_write_arb_cycles = 0;
        s7_write_control_cycles = 0;
        s7_write_tx_cycles = 0;
        @(negedge host_clk);
        s7_write_measure = 1;
        start_cycle = host_cycles;
        for (k = 0; k < 64; k = k + 1) begin
            data_write(32'h9020_0038, 256, 32'h5000_0000 + k * 256, st);
            check(st == 0 && last_count == 256, "S7 write packet");
        end
        @(negedge host_clk);
        s7_write_measure = 0;
        end_cycle = host_cycles;
        mbps = (65536.0 * 100.0) / (end_cycle - start_cycle);
        $display("S7_WRITE cycles=%0d bytes=65536 words=16384 MBps=%f", end_cycle - start_cycle, mbps);
        $display("S7_WRITE_CYCLES bridge=%0d (%.4f/word) arb=%0d (%.4f/word) control=%0d (%.4f/word) awg_tx=%0d (%.4f/word)",
                 s7_write_bridge_cycles, s7_write_bridge_cycles / 16384.0,
                 s7_write_arb_cycles, s7_write_arb_cycles / 16384.0,
                 s7_write_control_cycles, s7_write_control_cycles / 16384.0,
                 s7_write_tx_cycles, s7_write_tx_cycles / 16384.0);
        check(mbps >= 40.0, "S7 write throughput >=40MB/s");
        repeat (128) @(posedge host_clk);
        reg_read(32'h9020_0034, v, st);
        check(st == 0 && v == 32768, "S7 TX_WR_PTR=32768");
        cmd_write(32'h9020_000c, 1024, st);
        cmd_write(32'h9020_0010, 1, st);
        check(st == 0, "S7 configure single channel playback");
        cmd_write(32'h9020_0008, 2, st);
        check(st == 0, "S7 start playback");
        cmd_write(32'h9020_004c, (32'd1366 << 16), st);
        cmd_write(32'h9020_0008, 8, st);
        check(st == 0, "S7 valid capture arm");
        for (k = 0; k < 200000 && !rx_h_done; k = k + 1) @(posedge host_clk);
        check(rx_h_done, "S7 valid capture done");
        reg_read(32'h9020_002c, v, st);
        check(st == 0 && v == 1366 * 24, "S7 capture length covers read range");
        cmd_write(32'h9020_0008, 1, st);
        check(st == 0, "S7 stop playback after capture");
        cmd_write(32'h9020_0040, 0, st);
        check(st == 0, "S7 select capture channel");
        s7_read_bridge_cycles = 0;
        s7_read_arb_cycles = 0;
        s7_read_control_cycles = 0;
        s7_read_rx_cycles = 0;
        @(negedge host_clk);
        s7_read_measure = 1;
        start_cycle = host_cycles;
        valid_capture = 0;
        for (k = 0; k < 64; k = k + 1) begin
            data_read(32'h9020_0048, 256, st);
            check(st == 0 && last_count == 256, "S7 read packet status=0");
            if (k == 0) begin
                for (j = 24; j < resp_len; j = j + 1)
                    if (resp_buf[j] != 0) valid_capture = 1;
                check(valid_capture, "S7 captured payload contains valid nonzero samples");
            end
        end
        @(negedge host_clk);
        s7_read_measure = 0;
        end_cycle = host_cycles;
        mbps = (65536.0 * 100.0) / (end_cycle - start_cycle);
        $display("S7_READ cycles=%0d bytes=65536 words=16384 MBps=%f", end_cycle - start_cycle, mbps);
        $display("S7_READ_CYCLES bridge=%0d (%.4f/word) arb=%0d (%.4f/word) control=%0d (%.4f/word) awg_rx=%0d (%.4f/word)",
                 s7_read_bridge_cycles, s7_read_bridge_cycles / 16384.0,
                 s7_read_arb_cycles, s7_read_arb_cycles / 16384.0,
                 s7_read_control_cycles, s7_read_control_cycles / 16384.0,
                 s7_read_rx_cycles, s7_read_rx_cycles / 16384.0);
        check(mbps >= 30.0, "S7 read throughput >=30MB/s");

        $display("LOOP_MODEL_DISTANCE violations=%0d", loop_distance_violations);
        check(loop_distance_violations == 0, "loop model distance invariant");
        $display("RESULT name=tb_d3_system PASS=%0d FAIL=%0d", pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "D3 system acceptance failed");
        $finish;
    end
endmodule

`default_nettype wire
