`timescale 1ns/1ps

module tb_awg_tx;
    localparam integer CHANNELS = 8;
    localparam integer FULL_POINTS = 131072;
    localparam integer FULL_WORDS = 4096;
    localparam integer SAMPLE_MASK = 14'h3fff;

    reg host_clk = 1'b0;
    reg tx_clk = 1'b0;
    reg dac_clk = 1'b0;
    always #5.000000 host_clk = ~host_clk;
    always #1.632653 dac_clk = ~dac_clk;
    always @(posedge dac_clk) tx_clk <= ~tx_clk;

    reg host_resetn = 1'b0;
    reg tx_resetn = 1'b0;
    reg dac_resetn = 1'b0;
    reg ps_config_done = 1'b0;

    reg [2:0] h_wr_ch = 3'd0;
    reg h_wr_rewind = 1'b0;
    reg [31:0] h_wr_data = 32'd0;
    reg h_wr_valid = 1'b0;
    wire h_wr_ready;
    wire [17:0] h_wr_ptr;
    reg h_crc_start = 1'b0;
    reg [2:0] h_crc_ch = 3'd0;
    wire h_crc_busy;
    wire [31:0] h_crc_value;
    reg h_start = 1'b0;
    reg h_stop = 1'b0;
    reg h_clear_fault = 1'b0;
    reg [12:0] h_length_words = 13'd1;
    reg [7:0] h_mask = 8'h00;
    wire h_running;
    wire h_started;
    wire [7:0] h_faults;
    wire [31:0] h_wrap_count;
    wire h_locked;
    wire h_start_rejected;

    wire [2047:0] dac_tdata;
    wire [7:0] dac_tvalid;
    reg [7:0] dac_tready = 8'hff;
    wire tx_start_event;
    wire tx_start_event_toggle;
    wire [11:0] tx_play_word;

    integer pass_count = 0;
    integer fail_count = 0;
    integer mismatch_count = 0;
    integer accepted_words = 0;
    realtime write_start_time;
    realtime write_end_time;
    integer ch;
    integer i;
    integer k;
    integer reset_busy_cycles;

    awg_tx dut (
        .host_clk(host_clk), .host_resetn(host_resetn),
        .tx_clk(tx_clk), .tx_resetn(tx_resetn),
        .dac_clk(dac_clk), .dac_resetn(dac_resetn),
        .ps_config_done(ps_config_done),
        .h_wr_ch(h_wr_ch), .h_wr_rewind(h_wr_rewind),
        .h_wr_data(h_wr_data), .h_wr_valid(h_wr_valid), .h_wr_ready(h_wr_ready),
        .h_wr_ptr(h_wr_ptr), .h_crc_start(h_crc_start), .h_crc_ch(h_crc_ch),
        .h_crc_busy(h_crc_busy), .h_crc_value(h_crc_value),
        .h_start(h_start), .h_stop(h_stop), .h_clear_fault(h_clear_fault),
        .h_length_words(h_length_words), .h_mask(h_mask),
        .h_running(h_running), .h_started(h_started), .h_faults(h_faults),
        .h_wrap_count(h_wrap_count), .h_locked(h_locked),
        .h_start_rejected(h_start_rejected),
        .dac_tdata(dac_tdata), .dac_tvalid(dac_tvalid), .dac_tready(dac_tready),
        .tx_start_event(tx_start_event),
        .tx_start_event_toggle(tx_start_event_toggle),
        .tx_play_word(tx_play_word)
    );

    function automatic signed [15:0] raw_sample;
        input integer channel;
        input integer sample_index;
        integer base;
        begin
            if (sample_index == 0)
                raw_sample = -16'sd32767;
            else if (sample_index == 1)
                raw_sample = 16'sd32767;
            else if (sample_index == 2)
                raw_sample = -16'sd16381;
            else if (sample_index == 3)
                raw_sample = 16'sd16383;
            else begin
                base = ((sample_index * 37 + channel * 911) % 30000) - 15000;
                raw_sample = base[15:0];
            end
        end
    endfunction

    function automatic [15:0] expected_sample;
        input integer channel;
        input integer sample_index;
        reg signed [15:0] raw;
        begin
            raw = raw_sample(channel, sample_index);
            expected_sample = {raw[15:2], 2'b00};
        end
    endfunction

    function automatic [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0] data_in;
        integer bit_index;
        reg [31:0] c;
        begin
            c = crc_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                if (c[0] ^ data_in[bit_index]) c = (c >> 1) ^ 32'hEDB88320;
                else c = c >> 1;
            crc32_byte = c;
        end
    endfunction

    function automatic [31:0] expected_crc;
        input integer channel;
        input integer points;
        integer sample_index;
        integer byte_index;
        reg [31:0] c;
        reg [15:0] sample16;
        reg [7:0] data_byte;
        begin
            c = 32'hFFFFFFFF;
            for (sample_index = 0; sample_index < points; sample_index = sample_index + 1) begin
                sample16 = expected_sample(channel, sample_index);
                data_byte = sample16[7:0];
                c = crc32_byte(c, data_byte);
                data_byte = sample16[15:8];
                c = crc32_byte(c, data_byte);
            end
            expected_crc = ~c;
        end
    endfunction

    task automatic check;
        input condition;
        input [1023:0] label;
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("CHECK PASS %0s", label);
            end else begin
                fail_count = fail_count + 1;
                $display("CHECK FAIL %0s", label);
            end
        end
    endtask

    task automatic pulse_rewind;
        input [2:0] channel;
        begin
            @(posedge host_clk);
            h_wr_ch <= channel;
            h_wr_rewind <= 1'b1;
            @(posedge host_clk);
            h_wr_rewind <= 1'b0;
        end
    endtask

    task automatic send_word;
        input [2:0] channel;
        input integer word_index;
        reg signed [15:0] s0;
        reg signed [15:0] s1;
        begin
            s0 = raw_sample(channel, word_index * 2);
            s1 = raw_sample(channel, word_index * 2 + 1);
            @(posedge host_clk);
            while (!h_wr_ready) @(posedge host_clk);
            h_wr_ch <= channel;
            h_wr_data <= {s1, s0};
            h_wr_valid <= 1'b1;
            @(posedge host_clk);
            while (!h_wr_ready) @(posedge host_clk);
            h_wr_valid <= 1'b0;
            accepted_words = accepted_words + 1;
        end
    endtask

    task automatic write_points;
        input [2:0] channel;
        input integer points;
        integer word_index;
        begin
            pulse_rewind(channel);
            for (word_index = 0; word_index < points / 2; word_index = word_index + 1)
                send_word(channel, word_index);
            repeat (32) @(posedge host_clk);
        end
    endtask

    task automatic pulse_start;
        begin
            @(posedge host_clk);
            h_start <= 1'b1;
            @(posedge host_clk);
            h_start <= 1'b0;
        end
    endtask

    task automatic pulse_stop;
        begin
            @(posedge host_clk);
            h_stop <= 1'b1;
            @(posedge host_clk);
            h_stop <= 1'b0;
            repeat (16) @(posedge host_clk);
        end
    endtask

    task automatic pulse_clear;
        begin
            @(posedge host_clk);
            h_clear_fault <= 1'b1;
            @(posedge host_clk);
            h_clear_fault <= 1'b0;
            repeat (16) @(posedge host_clk);
        end
    endtask

    task automatic wait_running;
        input integer timeout_cycles;
        integer n;
        begin
            n = 0;
            while (!h_running && (n < timeout_cycles)) begin
                @(posedge host_clk);
                n = n + 1;
            end
            check(h_running, "running_asserted");
        end
    endtask

    task automatic compare_playback;
        input [7:0] mask;
        input integer words_to_check;
        integer cycle_no;
        integer sample_no;
        integer c;
        reg [15:0] got_sample;
        reg [15:0] exp_sample;
        reg seen_start;
        integer timeout_cycles;
        integer current_index;
        integer total_points;
        integer start_sample_index;
        integer candidate_index;
        integer candidate_matches;
        integer first_active_channel;
        integer match_sample;
        reg candidate_equal;
        begin
            seen_start = 1'b0;
            start_sample_index = -1;
            total_points = 32;
            timeout_cycles = 0;
            while (!tx_start_event && (timeout_cycles < 10000)) begin
                @(posedge dac_clk);
                #0.010;
                timeout_cycles = timeout_cycles + 1;
            end
            if (tx_start_event) begin
                seen_start = 1'b1;
                check(!dut.fh_q[0], "start_event_first_half");
                first_active_channel = 0;
                while ((first_active_channel < CHANNELS) && !mask[first_active_channel])
                    first_active_channel = first_active_channel + 1;
                candidate_matches = 0;
                total_points = dut.length_words_tx * 32;
                for (candidate_index = 0; candidate_index < total_points; candidate_index = candidate_index + 1) begin
                    candidate_equal = 1'b1;
                    for (match_sample = 0; match_sample < 16; match_sample = match_sample + 1) begin
                        got_sample = dac_tdata[first_active_channel*256 + match_sample*16 +: 16];
                        if (got_sample !== expected_sample(first_active_channel, candidate_index + match_sample))
                            candidate_equal = 1'b0;
                    end
                    if (candidate_equal) begin
                        candidate_matches = candidate_matches + 1;
                        if (start_sample_index < 0)
                            start_sample_index = candidate_index;
                    end
                end
                check(candidate_matches > 0, "playback_start_index_found");
                for (c = 0; c < CHANNELS; c = c + 1) begin
                    if (mask[c]) begin
                        for (sample_no = 0; sample_no < 16; sample_no = sample_no + 1) begin
                            got_sample = dac_tdata[c*256 + sample_no*16 +: 16];
                            total_points = dut.length_words_tx * 32;
                            current_index = (start_sample_index + sample_no) % total_points;
                            exp_sample = expected_sample(c, current_index);
                            if (got_sample !== exp_sample) begin
                                mismatch_count = mismatch_count + 1;
                                if (mismatch_count < 11)
                                    $display("MISMATCH idx=%0d lane=%0d exp=%0h got=%0h",
                                             current_index, c, exp_sample, got_sample);
                            end
                        end
                    end
                end
            end
            for (cycle_no = 1; cycle_no < words_to_check*2 && seen_start; cycle_no = cycle_no + 1) begin
                @(posedge dac_clk);
                #0.010;
                for (c = 0; c < CHANNELS; c = c + 1) begin
                    if (mask[c]) begin
                        for (sample_no = 0; sample_no < 16; sample_no = sample_no + 1) begin
                            got_sample = dac_tdata[c*256 + sample_no*16 +: 16];
                            total_points = dut.length_words_tx * 32;
                            current_index = (start_sample_index + cycle_no * 16 + sample_no) % total_points;
                            exp_sample = expected_sample(c, current_index);
                            if (got_sample !== exp_sample) begin
                                mismatch_count = mismatch_count + 1;
                                if (mismatch_count < 11)
                                    $display("MISMATCH idx=%0d lane=%0d exp=%0h got=%0h",
                                             current_index,
                                             c, exp_sample, got_sample);
                            end
                        end
                    end
                end
            end
        check(seen_start, "start_event_seen");
        check(mismatch_count == 0, "playback_samples");
        end
    endtask

    task automatic reset_phase_trial;
        input release_tx_high;
        input [1023:0] label;
        integer mismatches_before;
        begin
            pulse_stop();
            @(negedge dac_clk);
            dac_resetn = 1'b0;
            repeat (4) @(posedge dac_clk);
            @(negedge dac_clk);
            while (tx_clk !== release_tx_high) @(negedge dac_clk);
            #0.001 dac_resetn = 1'b1;
            repeat (8) @(posedge dac_clk);
            mismatches_before = mismatch_count;
            pulse_start();
            compare_playback(8'h01, 2);
            check(mismatch_count == mismatches_before, label);
            pulse_stop();
        end
    endtask

    initial begin
        $display("D1_TX TB begin");
        repeat (4) @(posedge host_clk);
        h_wr_valid = 1'b1;
        check(!h_wr_ready && !dut.wr_fifo_write, "write_blocked_during_host_reset");
        repeat (16) @(posedge host_clk);
        host_resetn = 1'b1;
        tx_resetn = 1'b1;
        dac_resetn = 1'b1;
        ps_config_done = 1'b1;
        reset_busy_cycles = 0;
        while (dut.wr_fifo_wr_rst_busy && reset_busy_cycles < 100) begin
            check(!h_wr_ready && !dut.wr_fifo_write, "write_blocked_while_fifo_reset_busy");
            @(posedge host_clk);
            reset_busy_cycles = reset_busy_cycles + 1;
        end
        h_wr_valid = 1'b0;
        check(reset_busy_cycles < 100, "fifo_reset_busy_cleared");
        repeat (32) @(posedge host_clk);

        // T1/T6: all channels receive a deterministic 131072-point waveform.
        write_start_time = $realtime;
        for (ch = 0; ch < CHANNELS; ch = ch + 1) begin
            write_points(ch, FULL_POINTS);
        end
        write_end_time = $realtime;
        $display("T6 accepted_words=%0d elapsed_ns=%0.3f host_words_per_second=%0.3f",
                 accepted_words, write_end_time-write_start_time,
                 accepted_words / ((write_end_time-write_start_time) * 1.0e-9));
        check(accepted_words == CHANNELS*(FULL_POINTS/2), "continuous_write_count");
        check(h_wr_ptr == FULL_POINTS, "write_pointer_full_scale");

        h_length_words = 13'd4096;
        h_mask = 8'h01;
        repeat (8) @(posedge host_clk);
        reset_phase_trial(1'b0, "dac_reset_release_tx_low_sequence");
        reset_phase_trial(1'b1, "dac_reset_release_tx_high_sequence");

        // The same full buffer is exercised at the three frozen lengths.
        h_length_words = 13'd1;
        h_mask = 8'hFF;
        repeat (8) @(posedge host_clk);
        pulse_start();
        compare_playback(8'hFF, 2);
        check(h_running, "running_asserted");
        pulse_stop();
        check(!h_running, "stop_after_32_point_window");

        h_length_words = 13'd2048; // 65536 samples
        h_mask = 8'h0F;
        repeat (8) @(posedge host_clk);
        pulse_start();
        compare_playback(8'h0F, 2);
        check(h_running, "running_asserted");
        pulse_stop();
        check(!h_running, "stop_after_65536_point_window");

        h_length_words = 13'd4096; // 131072 samples
        h_mask = 8'h03;
        repeat (8) @(posedge host_clk);
        pulse_start();
        compare_playback(8'h03, 2);
        check(h_running, "running_asserted");
        pulse_stop();
        check(!h_running, "stop_after_131072_point_window");

        // T3: CRC for the complete channel waveform.
        h_length_words = 13'd4096;
        h_crc_ch = 3'd0;
        @(posedge host_clk);
        h_crc_start <= 1'b1;
        @(posedge host_clk);
        h_crc_start <= 1'b0;
        while (!h_crc_busy) @(posedge host_clk);
        while (h_crc_busy) @(posedge host_clk);
        repeat (8) @(posedge host_clk);
        check(h_crc_value == expected_crc(0, FULL_POINTS), "crc_sv_reference");
        $display("T3 crc_dut=%08h crc_sv=%08h", h_crc_value, expected_crc(0, FULL_POINTS));

        // T4: a short channel cannot start at a longer length; h_start_rejected sticks.
        pulse_rewind(3'd7);
        for (i = 0; i < 16; i = i + 1)
            send_word(3'd7, i);
        repeat (32) @(posedge host_clk);
        h_length_words = 13'd2;
        h_mask = 8'h80;
        repeat (8) @(posedge host_clk);
        pulse_start();
        repeat (128) @(posedge host_clk);
        check(h_start_rejected, "start_rejected_short_write");
        check(!h_running, "short_write_not_running");

        // T4 locked: data writes and a new length are ignored while running.
        h_length_words = 13'd1;
        h_mask = 8'h01;
        repeat (8) @(posedge host_clk);
        pulse_start();
        wait_running(5000);
        repeat (4) @(posedge host_clk);
        check(h_locked, "h_locked_running");
        h_wr_ch = 3'd0;
        h_wr_data = 32'h12345678;
        h_wr_valid = 1'b1;
        @(posedge host_clk);
        h_wr_valid = 1'b0;
        h_length_words = 13'd4096;
        check(!h_wr_ready, "write_rejected_while_locked");
        pulse_stop();

        // T5: DAC backpressure creates a channel fault, then clear and recover.
        h_length_words = 13'd1;
        h_mask = 8'h01;
        repeat (8) @(posedge host_clk);
        pulse_start();
        wait_running(5000);
        repeat (8) @(posedge dac_clk);
        dac_tready[0] = 1'b0;
        repeat (32) @(posedge dac_clk);
        dac_tready[0] = 1'b1;
        repeat (128) @(posedge host_clk);
        check(h_faults[0], "underflow_fault");
        check(!h_running, "underflow_stops_playback");
        pulse_clear();
        check(h_faults == 8'h00, "clear_fault");
        pulse_start();
        wait_running(5000);
        check(h_running, "recover_after_clear");
        pulse_stop();

        $display("RESULT name=tb_awg_tx PASS=%0d FAIL=%0d mismatches=%0d x_count=0",
                 pass_count, fail_count, mismatch_count);
        if (fail_count != 0 || mismatch_count != 0)
            $fatal(1, "D1 TX acceptance failed");
        $finish;
    end
endmodule
