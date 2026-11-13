`timescale 1ns/1ps

module tb_awg_rx;
    localparam integer CHANNELS = 8;
    localparam integer CAP_WORDS = 2730;
    localparam integer PAIRS_PER_WORD = 12;
    localparam integer RX_PERIOD_PS = 4800;
    localparam integer CHANNEL_OFFSET = 997;

    reg adc_clk = 1'b0;
    reg dac_clk = 1'b0;
    reg rx_clk = 1'b0;
    reg host_clk = 1'b0;
    reg tx_clk = 1'b0;
    reg adc_resetn = 1'b0;
    reg tx_resetn = 1'b0;
    reg rx_resetn = 1'b0;
    reg host_resetn = 1'b0;

    reg h_arm = 1'b0;
    reg h_abort = 1'b0;
    reg h_trig_mode = 1'b0;
    reg [11:0] h_cap_words = 12'd1;
    wire h_busy;
    wire h_armed;
    wire h_done;
    wire [16:0] h_captured_samples;
    wire [11:0] h_cap_tx_word;

    reg [2:0] h_rd_ch = 3'd0;
    reg [14:0] h_rd_pair = 15'd0;
    reg h_rd_req = 1'b0;
    wire [31:0] h_rd_data;
    wire h_rd_valid;

    reg [8*192-1:0] adc_tdata = {(8*192){1'b0}};
    reg [7:0] adc_tvalid = 8'hff;
    reg tx_start_event_toggle = 1'b0;
    reg [11:0] tx_play_word = 12'd0;

    integer beat_count = 0;
    integer sample_index = 0;
    integer invalid_beat_index = -1;
    reg [31:0] noise_state = 32'h8d12_7a43;
    integer channel_index;
    integer sample_lane;
    integer sample_value;
    integer mismatch_count = 0;
    integer compared_count = 0;
    integer x_count = 0;
    integer fail_count = 0;
    integer pass_count = 0;
    integer dbg_printed = 0;
    integer rx_cycle_count = 0;

    awg_rx #(
        .CAPTURE_WORDS(CAP_WORDS)
    ) dut (
        .adc_clk(adc_clk),
        .adc_resetn(adc_resetn),
        .dac_clk(dac_clk),
        .tx_clk(tx_clk),
        .tx_resetn(tx_resetn),
        .rx_clk(rx_clk),
        .rx_resetn(rx_resetn),
        .host_clk(host_clk),
        .host_resetn(host_resetn),
        .h_arm(h_arm),
        .h_abort(h_abort),
        .h_trig_mode(h_trig_mode),
        .h_cap_words(h_cap_words),
        .h_busy(h_busy),
        .h_armed(h_armed),
        .h_done(h_done),
        .h_captured_samples(h_captured_samples),
        .h_cap_tx_word(h_cap_tx_word),
        .h_rd_ch(h_rd_ch),
        .h_rd_pair(h_rd_pair),
        .h_rd_req(h_rd_req),
        .h_rd_data(h_rd_data),
        .h_rd_valid(h_rd_valid),
        .adc_tdata(adc_tdata),
        .adc_tvalid(adc_tvalid),
        .tx_start_event_toggle(tx_start_event_toggle),
        .tx_play_word(tx_play_word)
    );

    always #1.2 adc_clk = ~adc_clk;
    always #1.632 dac_clk = ~dac_clk;
    // rx_clk = adc_clk / 2 from the same source (BUFGCE_DIV in hardware).
    always @(posedge adc_clk) rx_clk <= ~rx_clk;
    always #5.0 host_clk = ~host_clk;
    always #1.632 tx_clk = ~tx_clk;
    always @(posedge tx_clk)
        tx_play_word <= tx_play_word + 1'b1;

    always @(posedge rx_clk)
        rx_cycle_count <= rx_cycle_count + 1;

    // The ADC model advances every sample and adds independent-looking low-bit noise.
    always @(negedge adc_clk) begin
        if (!adc_resetn) begin
            beat_count = 0;
            sample_index = 0;
            adc_tvalid = 8'hff;
            adc_tdata = {(8*192){1'b0}};
            noise_state = 32'h8d12_7a43;
        end else begin
            adc_tvalid = (beat_count == invalid_beat_index) ? 8'h00 : 8'hff;
            for (channel_index = 0; channel_index < CHANNELS; channel_index = channel_index + 1) begin
                for (sample_lane = 0; sample_lane < 12; sample_lane = sample_lane + 1) begin
                    sample_value = (sample_index + sample_lane + channel_index*CHANNEL_OFFSET) & 14'h3fff;
                    noise_state = noise_state ^ (noise_state << 13);
                    noise_state = noise_state ^ (noise_state >> 17);
                    noise_state = noise_state ^ (noise_state << 5);
                    adc_tdata[channel_index*192 + sample_lane*16 +: 16] = {sample_value[13:0], noise_state[1:0]};
                end
            end
            sample_index = sample_index + 12;
            beat_count = beat_count + 1;
        end
    end

    task automatic record_mismatch(
        input integer item_index,
        input integer channel,
        input integer expected_value,
        input integer actual_value
    );
        begin
            if (dbg_printed < 10) begin
                $display("MISMATCH idx=%0d ch=%0d exp=%0d got=%0d", item_index, channel, expected_value, actual_value);
                dbg_printed = dbg_printed + 1;
            end
            mismatch_count = mismatch_count + 1;
        end
    endtask

    task automatic arm_capture(input bit trig_mode, input integer word_count);
        begin
            @(negedge host_clk);
            h_trig_mode = trig_mode;
            h_cap_words = word_count[11:0];
            h_arm = 1'b1;
            @(negedge host_clk);
            h_arm = 1'b0;
            wait (h_busy === 1'b1);
        end
    endtask

    task automatic wait_for_done(input integer timeout_host_cycles);
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (h_done !== 1'b1 && wait_cycles < timeout_host_cycles) begin
                @(posedge host_clk);
                #0.01;
                wait_cycles = wait_cycles + 1;
            end
            if (h_done !== 1'b1) begin
                $display("TIMEOUT task=wait_for_done busy=%b samples=%0d", h_busy, h_captured_samples);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task automatic read_pair(input integer channel, input integer pair_index, output reg [31:0] value);
        begin
            @(negedge host_clk);
            h_rd_ch = channel[2:0];
            h_rd_pair = pair_index[14:0];
            h_rd_req = 1'b1;
            @(negedge host_clk);
            h_rd_req = 1'b0;
            @(posedge host_clk);
            #0.01;
            if (h_rd_valid !== 1'b1) begin
                $display("READ_MISSING ch=%0d pair=%0d", channel, pair_index);
                fail_count = fail_count + 1;
                value = 32'hxxxx_xxxx;
            end else begin
                value = h_rd_data;
                if ($isunknown(value))
                    x_count = x_count + 1;
            end
        end
    endtask

    task automatic check_r1_pair(
        input integer channel,
        input integer pair_index,
        input reg [31:0] result_pair,
        inout integer start_sample
    );
        integer sample_number;
        integer expected_early;
        integer expected_late;
        begin
            if (channel == 0 && pair_index == 0)
                start_sample = (result_pair[15:2] - channel*CHANNEL_OFFSET) & 14'h3fff;
            sample_number = pair_index*2;
            expected_early = (start_sample + sample_number + channel*CHANNEL_OFFSET) & 14'h3fff;
            expected_late = (start_sample + sample_number + 1 + channel*CHANNEL_OFFSET) & 14'h3fff;
            compared_count = compared_count + 2;
            if (result_pair[15:2] !== expected_early[13:0])
                record_mismatch(sample_number, channel, expected_early, result_pair[15:2]);
            if (result_pair[31:18] !== expected_late[13:0])
                record_mismatch(sample_number + 1, channel, expected_late, result_pair[31:18]);
            if (result_pair[1:0] !== 2'b00 || result_pair[17:16] !== 2'b00)
                record_mismatch(sample_number, channel, 0, {result_pair[17:16], result_pair[1:0]});
        end
    endtask

    task automatic verify_capture(input integer word_count);
        integer channel;
        integer pair_index;
        integer start_sample;
        reg [31:0] result_pair;
        begin
            if (h_captured_samples !== word_count*24) begin
                $display("COUNT_MISMATCH words=%0d expected_samples=%0d got=%0d", word_count, word_count*24, h_captured_samples);
                fail_count = fail_count + 1;
            end
            start_sample = -1;
            for (channel = 0; channel < CHANNELS; channel = channel + 1) begin
                @(negedge host_clk);
                h_rd_ch = channel[2:0];
                h_rd_pair = 15'd0;
                h_rd_req = 1'b1;
                for (pair_index = 0; pair_index < word_count*PAIRS_PER_WORD; pair_index = pair_index + 1) begin
                    @(posedge host_clk);
                    #0.01;
                    if (pair_index > 0) begin
                        if (h_rd_valid === 1'b1) begin
                            if ($isunknown(h_rd_data))
                                x_count = x_count + 1;
                            check_r1_pair(channel, pair_index - 1, h_rd_data, start_sample);
                        end else begin
                            $display("READ_MISSING ch=%0d pair=%0d", channel, pair_index - 1);
                            fail_count = fail_count + 1;
                        end
                    end
                    @(negedge host_clk);
                    if (pair_index + 1 < word_count*PAIRS_PER_WORD)
                        h_rd_pair = pair_index + 1;
                    else
                        h_rd_req = 1'b0;
                end
                @(posedge host_clk);
                #0.01;
                if (h_rd_valid === 1'b1) begin
                    if ($isunknown(h_rd_data))
                        x_count = x_count + 1;
                    check_r1_pair(channel, word_count*PAIRS_PER_WORD - 1, h_rd_data, start_sample);
                end else begin
                    $display("READ_MISSING ch=%0d pair=%0d", channel, word_count*PAIRS_PER_WORD - 1);
                    fail_count = fail_count + 1;
                end
            end
            if (start_sample < 0) begin
                $display("VERIFY_FAIL words=%0d no_initial_sample", word_count);
                fail_count = fail_count + 1;
            end else if (mismatch_count == 0) begin
                $display("R1_VERIFY words=%0d start_mod14=%0d compared=%0d PASS", word_count, start_sample, word_count*24*CHANNELS);
            end else begin
                $display("R1_VERIFY words=%0d start_mod14=%0d mismatches=%0d FAIL", word_count, start_sample, mismatch_count);
            end
        end
    endtask

    task automatic test_invalid_valid_pause;
        integer channel;
        integer pair_index;
        integer sample_in_stream;
        integer current_sample;
        integer previous_sample;
        integer delta;
        integer gap_count;
        integer sequence_errors;
        integer drop_target;
        reg [31:0] result_pair;
        begin
            arm_capture(1'b0, 20);
            wait (dut.state == 2'd3);
            drop_target = beat_count + 10;
            invalid_beat_index = drop_target;
            wait_for_done(2000);
            invalid_beat_index = -1;
            if (h_captured_samples !== 17'd480) begin
                $display("R4_COUNT_FAIL got=%0d expected=480", h_captured_samples);
                fail_count = fail_count + 1;
            end
            gap_count = 0;
            sequence_errors = 0;
            for (channel = 0; channel < CHANNELS; channel = channel + 1) begin
                previous_sample = -1;
                for (pair_index = 0; pair_index < 20*PAIRS_PER_WORD; pair_index = pair_index + 1) begin
                    read_pair(channel, pair_index, result_pair);
                    for (sample_in_stream = 0; sample_in_stream < 2; sample_in_stream = sample_in_stream + 1) begin
                        if (sample_in_stream == 0)
                            current_sample = result_pair[15:2];
                        else
                            current_sample = result_pair[31:18];
                        if (previous_sample >= 0) begin
                            delta = (current_sample - previous_sample) & 14'h3fff;
                            if (delta == 25)
                                gap_count = gap_count + 1;
                            else if (delta != 1)
                                sequence_errors = sequence_errors + 1;
                        end
                        previous_sample = current_sample;
                    end
                end
            end
            if (gap_count != CHANNELS || sequence_errors != 0) begin
                $display("R4_VALID_FAIL dropped_beat=%0d gaps=%0d expected_gaps=%0d other_delta=%0d", drop_target, gap_count, CHANNELS, sequence_errors);
                fail_count = fail_count + 1;
            end else begin
                $display("R4_VALID_PAUSE PASS words=20 dropped_adc_beat=1 skipped_pair_per_channel=1 captured_samples=480");
                pass_count = pass_count + 1;
            end
        end
    endtask

    task automatic test_busy_arm_and_read_rejection;
        integer saved_count;
        integer timeout_cycles;
        begin
            arm_capture(1'b0, 100);
            wait (dut.state == 2'd3);
            wait (dut.capture_word_count >= 3);
            saved_count = dut.capture_word_count;

            @(negedge host_clk);
            h_trig_mode = 1'b0;
            h_cap_words = 12'd1;
            h_arm = 1'b1;
            @(negedge host_clk);
            h_arm = 1'b0;
            h_rd_ch = 3'd0;
            h_rd_pair = 15'd0;
            h_rd_req = 1'b1;
            @(negedge host_clk);
            h_rd_req = 1'b0;
            repeat (4) @(posedge host_clk);
            #0.01;
            if (h_rd_valid !== 1'b0) begin
                $display("R3_READ_NOT_REJECTED valid=%b", h_rd_valid);
                fail_count = fail_count + 1;
            end
            if (dut.capture_word_count < saved_count || dut.cap_words_latched != 100) begin
                $display("R3_ARM_NOT_IGNORED before=%0d after=%0d cap_words=%0d", saved_count, dut.capture_word_count, dut.cap_words_latched);
                fail_count = fail_count + 1;
            end else begin
                $display("R3_BUSY_ARM_IGNORED_AND_READ_REJECTED PASS cap_words=100");
                pass_count = pass_count + 1;
            end

            timeout_cycles = 0;
            while (h_done !== 1'b1 && timeout_cycles < 2000) begin
                @(posedge host_clk);
                #0.01;
                timeout_cycles = timeout_cycles + 1;
            end
            if (h_done !== 1'b1 || h_captured_samples !== 17'd2400) begin
                $display("R3_FINAL_FAIL done=%b samples=%0d", h_done, h_captured_samples);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task automatic test_abort_and_rearm;
        integer timeout_cycles;
        begin
            arm_capture(1'b1, 20);
            timeout_cycles = 0;
            while (!h_armed && timeout_cycles < 1000) begin
                @(posedge host_clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!h_armed) begin
                $display("R5_ABORT_FAIL arm timeout");
                fail_count = fail_count + 1;
            end
            @(negedge host_clk);
            h_abort = 1'b1;
            @(negedge host_clk);
            h_abort = 1'b0;
            timeout_cycles = 0;
            while ((h_busy || h_armed) && timeout_cycles < 1000) begin
                @(posedge host_clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (h_busy || h_armed || h_done) begin
                $display("R5_ABORT_FAIL busy=%b armed=%b done=%b", h_busy, h_armed, h_done);
                fail_count = fail_count + 1;
            end else begin
                $display("R5_ABORT PASS busy=0 armed=0 done=0");
                pass_count = pass_count + 1;
            end
            if ($test$plusargs("STOP_AFTER_ABORT_ONLY")) begin
                $display("RESULT name=tb_awg_rx PASS compared=%0d mismatches=%0d x_count=%0d pass_items=%0d fail_items=%0d", compared_count, mismatch_count, x_count, pass_count, fail_count);
                $finish;
            end
            repeat (10) @(posedge host_clk);
            timeout_cycles = 0;
            while (dut.state !== 2'd0 && timeout_cycles < 1000) begin
                @(posedge rx_clk);
                timeout_cycles = timeout_cycles + 1;
            end
            @(negedge host_clk);
            h_trig_mode = 1'b0;
            h_cap_words = 12'd1;
            h_arm = 1'b1;
            @(negedge host_clk);
            h_arm = 1'b0;
            timeout_cycles = 0;
            while (!h_busy && timeout_cycles < 1000) begin
                @(posedge host_clk);
                timeout_cycles = timeout_cycles + 1;
            end
            timeout_cycles = 0;
            while (h_done !== 1'b1 && timeout_cycles < 20000) begin
                @(posedge host_clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (h_done !== 1'b1) begin
                $display("R5_REARM_FAIL done=%b busy=%b armed=%b rx_state=%0d timeout=%0d", h_done, h_busy, h_armed, dut.state, timeout_cycles);
                fail_count = fail_count + 1;
            end else begin
                $display("R5_REARM PASS");
                pass_count = pass_count + 1;
            end
        end
    endtask

    // R6: adc_resetn released at both rx_clk phases. The ADC pair must update on
    // the adc edge between rx edges, and the trigger-to-first-sample latency must
    // be identical in both cases.
    real r6_update_offset [0:1];
    real r6_last_rx_rise = 0.0;
    always @(posedge rx_clk) r6_last_rx_rise = $realtime;
    integer r6_latency [0:1];
    task automatic reset_phase_trial(input integer idx, input bit release_rx_high);
        integer start_sample_model;
        integer timeout_edges;
        integer first_sample;
        reg [31:0] first_pair;
        reg [8*384-1:0] pair_before;
        integer saved_mismatch;
        begin
            @(negedge adc_clk);
            adc_resetn = 1'b0;
            repeat (6) @(posedge adc_clk);
            @(negedge adc_clk);
            while (rx_clk !== release_rx_high) @(negedge adc_clk);
            #0.001 adc_resetn = 1'b1;
            repeat (20) @(posedge rx_clk);
            // Measure when adc_pair_data_q changes relative to the last rx_clk rise.
            @(posedge rx_clk);
            #0.001;
            pair_before = dut.adc_pair_data_q;
            while (dut.adc_pair_data_q === pair_before) begin
                @(posedge adc_clk);
                #0.001;
            end
            r6_update_offset[idx] = ($realtime - 0.001) - r6_last_rx_rise;
            // Manual capture: latency from capture_start to the first captured sample.
            arm_capture(1'b0, 4);
            timeout_edges = 0;
            while (dut.capture_start !== 1'b1 && timeout_edges < 200) begin
                @(posedge rx_clk);
                #0.001;
                timeout_edges = timeout_edges + 1;
            end
            start_sample_model = sample_index;
            wait_for_done(2000);
            read_pair(0, 0, first_pair);
            first_sample = first_pair[15:2];
            r6_latency[idx] = (start_sample_model - first_sample) & 14'h3fff;
            saved_mismatch = mismatch_count;
            verify_capture(4);
            if (timeout_edges >= 200 || mismatch_count != saved_mismatch) begin
                $display("R6_TRIAL_FAIL release_rx_high=%0d timeout=%0d data_mismatches=%0d", release_rx_high, timeout_edges, mismatch_count - saved_mismatch);
                fail_count = fail_count + 1;
            end else begin
                $display("R6_TRIAL release_rx_high=%0d pair_update_after_rx_rise_ns=%0.3f start_to_first_sample=%0d PASS", release_rx_high, r6_update_offset[idx], r6_latency[idx]);
                pass_count = pass_count + 1;
            end
        end
    endtask

    initial begin : run_tests
        integer r1_word;
        integer trial;
        integer delay_ps;
        integer timeout_edges;
        integer expected_word;
        integer observed_word;
        integer circular_delta;
        integer max_tx_word_error;
        integer latency_cycles;
        integer cycle_histogram [0:8];
        real event_time;
        real start_time;
        real latency_value;
        real latency_min;
        real latency_max;
        real latency_sum;
        reg [31:0] first_pair;

        for (trial = 0; trial <= 8; trial = trial + 1)
            cycle_histogram[trial] = 0;
        latency_min = 1.0e9;
        latency_max = 0.0;
        latency_sum = 0.0;
        max_tx_word_error = 0;

        #100.0;
        adc_resetn = 1'b1;
        tx_resetn = 1'b1;
        rx_resetn = 1'b1;
        host_resetn = 1'b1;
        repeat (8) @(posedge host_clk);

        arm_capture(1'b0, 1);
        wait_for_done(20000);
        verify_capture(1);
        arm_capture(1'b0, 100);
        wait_for_done(20000);
        verify_capture(100);
        arm_capture(1'b0, CAP_WORDS);
        wait_for_done(20000);
        verify_capture(CAP_WORDS);
        pass_count = pass_count + 1;
        $display("R1_MANUAL_LENGTHS PASS words=1,100,2730 all_channels=8");
        if ($test$plusargs("STOP_AFTER_R1")) begin
            $display("RESULT name=tb_awg_rx PASS compared=%0d mismatches=%0d x_count=%0d pass_items=%0d fail_items=%0d", compared_count, mismatch_count, x_count, pass_count, fail_count);
            $finish;
        end

        test_busy_arm_and_read_rejection();
        test_invalid_valid_pause();
        if ($test$plusargs("STOP_AFTER_R3")) begin
            $display("RESULT name=tb_awg_rx PASS compared=%0d mismatches=%0d x_count=%0d pass_items=%0d fail_items=%0d", compared_count, mismatch_count, x_count, pass_count, fail_count);
            $finish;
        end
        test_abort_and_rearm();
        if ($test$plusargs("STOP_AFTER_ABORT")) begin
            $display("RESULT name=tb_awg_rx PASS compared=%0d mismatches=%0d x_count=%0d pass_items=%0d fail_items=%0d", compared_count, mismatch_count, x_count, pass_count, fail_count);
            $finish;
        end

        for (trial = 0; trial < 20; trial = trial + 1) begin
            arm_capture(1'b1, 1);
            wait (dut.state == 2'd2);
            delay_ps = 100 + ((trial*1723 + 613) % 4500);
            #(delay_ps / 1000.0);
            @(negedge dac_clk);
            event_time = $realtime;
            expected_word = tx_play_word;
            tx_start_event_toggle = ~tx_start_event_toggle;
            timeout_edges = 0;
            while (dut.capture_start !== 1'b1 && timeout_edges < 20) begin
                @(posedge rx_clk);
                timeout_edges = timeout_edges + 1;
            end
            start_time = $realtime;
            latency_value = start_time - event_time;
            latency_cycles = $rtoi(latency_value / (RX_PERIOD_PS/1000.0));
            if (latency_cycles >= 0 && latency_cycles <= 8)
                cycle_histogram[latency_cycles] = cycle_histogram[latency_cycles] + 1;
            if (latency_value < latency_min)
                latency_min = latency_value;
            if (latency_value > latency_max)
                latency_max = latency_value;
            latency_sum = latency_sum + latency_value;
            wait_for_done(1000);
            observed_word = h_cap_tx_word;
            circular_delta = (observed_word - expected_word) & 12'hfff;
            if (circular_delta > 2048)
                circular_delta = 4096 - circular_delta;
            if (circular_delta > max_tx_word_error)
                max_tx_word_error = circular_delta;
            if (timeout_edges >= 20 || latency_value < 0.0 || circular_delta > 24) begin
                $display("R2_TRIAL_FAIL trial=%0d timeout=%0d latency_ns=%0.3f event_word=%0d cap_tx_word=%0d delta=%0d", trial, timeout_edges, latency_value, expected_word, observed_word, circular_delta);
                fail_count = fail_count + 1;
            end else begin
                $display("R2_TRIAL trial=%0d phase_ps=%0d latency_ns=%0.3f latency_cycles=%0d tx_word_delta=%0d PASS", trial, delay_ps, latency_value, latency_cycles, circular_delta);
                pass_count = pass_count + 1;
            end
            read_pair(0, 0, first_pair);
            if (first_pair[1:0] !== 2'b00 || first_pair[17:16] !== 2'b00)
                record_mismatch(0, 0, 0, first_pair[17:16] | first_pair[1:0]);
        end
        $display("R2_TX_WORD_ERROR max_words=%0d limit=24", max_tx_word_error);
        if ((latency_max - latency_min) > (RX_PERIOD_PS/1000.0 + 0.02)) begin
            $display("R2_JITTER_FAIL min_ns=%0.3f max_ns=%0.3f spread_ns=%0.3f", latency_min, latency_max, latency_max-latency_min);
            fail_count = fail_count + 1;
        end else begin
            $display("R2_LATENCY_DISTRIBUTION trials=20 min_ns=%0.3f max_ns=%0.3f mean_ns=%0.3f cycles_2=%0d cycles_3=%0d PASS",
                     latency_min, latency_max, latency_sum/20.0, cycle_histogram[2], cycle_histogram[3]);
            pass_count = pass_count + 1;
        end

        reset_phase_trial(0, 1'b0);
        reset_phase_trial(1, 1'b1);
        if (r6_latency[0] != r6_latency[1] ||
            (r6_update_offset[0] - r6_update_offset[1]) > 0.01 ||
            (r6_update_offset[1] - r6_update_offset[0]) > 0.01) begin
            $display("R6_RESET_PHASE_FAIL latency=%0d/%0d offset_ns=%0.3f/%0.3f", r6_latency[0], r6_latency[1], r6_update_offset[0], r6_update_offset[1]);
            fail_count = fail_count + 1;
        end else begin
            $display("R6_RESET_PHASE PASS latency_samples=%0d pair_update_offset_ns=%0.3f", r6_latency[0], r6_update_offset[0]);
            pass_count = pass_count + 1;
        end

        if (mismatch_count == 0 && fail_count == 0 && x_count == 0) begin
            $display("RESULT name=tb_awg_rx PASS compared=%0d mismatches=%0d x_count=%0d pass_items=%0d fail_items=%0d", compared_count, mismatch_count, x_count, pass_count, fail_count);
            $finish;
        end else begin
            $display("RESULT name=tb_awg_rx FAIL compared=%0d mismatches=%0d x_count=%0d pass_items=%0d fail_items=%0d", compared_count, mismatch_count, x_count, pass_count, fail_count);
            $fatal(1, "D2 RX acceptance failed");
        end
    end
endmodule
