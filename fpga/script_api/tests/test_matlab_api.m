function test_matlab_api(port, outdir)
% TEST_MATLAB_API  MATLAB 脚本接口测试（对 127.0.0.1:port 上的 FPGA 模拟器，不接硬件）
%   由 test_matlab_api.py 调用：matlab -batch "addpath(...); test_matlab_api(port, outdir)"
%   结果写到 outdir，供 Python 端与 awg47dr.py 交叉比对。
ip = '127.0.0.1';
results = struct();

% ---- 1. 波形生成 + 缩放（结果交给 Python 比对）----
kinds = {'sine', 'square', 'triangle', 'ramp', 'pulse', 'multitone', 'chirp', 'dc'};
for i = 1:numel(kinds)
    [w, info] = awg_generate_waveform(kinds{i}, FreqHz=123e6, Samples=65536);
    assert(numel(w) == 65536 && abs(max(abs(w)) - 1) < 1e-9, kinds{i});
    [codes, sinfo] = awg_scale_waveform(w, AmpDbfs=-6);
    assert(isa(codes, 'int16') && all(mod(double(codes), 4) == 0), kinds{i});
    fid = fopen(fullfile(outdir, ['gen_', kinds{i}, '.bin']), 'w'); fwrite(fid, codes, 'int16'); fclose(fid);
    results.gen.(kinds{i}) = struct('info', info, 'peak_dbfs', sinfo.peak_dbfs, 'clipped', sinfo.clipped);
end
[c2, i2] = awg_scale_waveform(ones(1, 100) * 3, AmpDbfs=0, Mode="gain", Fit="pad");
assert(numel(c2) == 128 && i2.clipped == 100 && max(c2) == 8191 * 4);
try
    awg_scale_waveform(ones(1, 100));
    error('test:noerr', '长度 100 应该报错');
catch e
    assert(strcmp(e.identifier, 'awg_scale_waveform:length'), e.message);
end

% ---- 2. 状态 ----
st = awg_status(ip, Port=port, Timeout=0.1);
assert(strcmp(st.id, '0x41574732') && st.ps_ready);

% ---- 3. 8 通道下载（每通道频率、幅度不同）+ Run ----
waves = zeros(8, 131072, 'int16');
for ch = 0:7
    w = awg_generate_waveform('sine', FreqHz=50e6 * (ch + 1), Samples=131072);
    waves(ch + 1, :) = awg_scale_waveform(w, AmpDbfs=-6 - ch);
end
r = awg_download(ip, waves, Port=port, WordsPerPacket=512, Timeout=0.1);
assert(isequal(r.channels, 0:7) && r.mask == 255 && numel(r.crc) == 8 && r.running);
results.download_seconds = r.seconds;
results.crc_retries = r.crc_retries;
o = awg_output(ip, Run=true, Port=port, Timeout=0.1);          % 已在播放再 Run：不报错
assert(o.running && o.channel_mask == 255);

% ---- 4. 起播同步采集 3 个通道 + 测量 ----
[d, info] = dso_capture(ip, Channels=[0 3 7], Samples=65520, Trigger="start", Port=port, ...
                        WordsPerPacket=512, Timeout=0.1);
assert(isequal(size(d), [3, 65520]) && info.samples == 65520 && isa(d, 'int16'));
chs = [0 3 7];
for row = 1:3
    ch = chs(row);
    m = dso_measure(d(row, :));
    cycles = round(50e6 * (ch + 1) * 131072 / 9.8e9);
    assert(abs(m.freq_hz - cycles * 5e9 / 131072) < 50e3, sprintf('CH%d 频率 %.0f', ch, m.freq_hz));
    assert(abs(m.peak_dbfs - (-6 - ch)) < 0.3, sprintf('CH%d 幅度 %.2f', ch, m.peak_dbfs));
    results.measure{row} = m;
end
fid = fopen(fullfile(outdir, 'capture.bin'), 'w'); fwrite(fid, d.', 'int16'); fclose(fid);   % 行优先写出
[f, db, rbw] = dso_spectrum(d(1, :));
results.spectrum = struct('n', numel(f), 'peak_db', max(db), 'peak_f', f(db == max(db)), 'rbw', rbw);
results.read_seconds = info.read_seconds;

% ---- 5. 手动触发小采集、Stop ----
[d2, info2] = dso_capture(ip, Channels=1, Samples=240, Port=port, Timeout=0.1);
assert(isequal(size(d2), [1, 240]) && info2.samples == 240);
o = awg_output(ip, Run=false, Port=port, Timeout=0.1);
assert(~o.running);

% ---- 6. 错误处理 ----
try
    awg_download(ip, zeros(1, 128), Port=port);
    error('test:noerr', 'double 输入应该报错');
catch e
    assert(strcmp(e.identifier, 'awg_download:type'), e.message);
end
try
    awg_status(ip, Port=9, Timeout=0.01, Retries=1);
    error('test:noerr', '无人监听的端口应该超时');
catch e
    assert(strcmp(e.identifier, 'awg_status:timeout'), e.message);
end

fid = fopen(fullfile(outdir, 'results.json'), 'w'); fwrite(fid, jsonencode(results), 'char'); fclose(fid);
disp('MATLAB_API_TEST PASS');
end
