% 47DR AWG / 示波器 MATLAB 脚本示例：生成波形 → 缩放 → 下载 → 起播同步采集 → 测量 → 频谱 → 停止
%
% 运行：在 MATLAB 里打开本文件按 F5，或 matlab -batch "run('example_matlab.m')"
% 离线试用：先在工程 tools 目录运行 py -X utf8 -m awg_eth.fpga_emu --loopback --port 9100，再把下面 ip 改成 '127.0.0.1'

addpath(fullfile(fileparts(mfilename('fullpath')), 'matlab'));
ip = '192.168.42.2';

% 1. 检查板卡
st = awg_status(ip);
fprintf('板卡：BUILD_ID %s，ps_ready=%d，播放中=%d\n', st.build_id, st.ps_ready, st.running);
if ~st.ps_ready
    error('板卡未初始化：请先用上位机「设备 → 下载 bit 并初始化」');
end

% 2. AWG：8 个通道分别输出 100, 200, ..., 800 MHz 正弦，幅度 -6 dBFS
waves = zeros(8, 131072, 'int16');
for ch = 0:7
    [w, info] = awg_generate_waveform('sine', FreqHz=100e6 * (ch + 1), Samples=131072);
    [waves(ch + 1, :), sinfo] = awg_scale_waveform(w, AmpDbfs=-6);
    fprintf('CH%d：实际频率 %.6f MHz，峰值 %.2f dBFS\n', ch, info.freq_hz / 1e6, sinfo.peak_dbfs);
end
r = awg_download(ip, waves);                         % 通道默认 0..7，下载 + CRC + 自动 Run
fprintf('下载完成：%d 通道 × %d 点，%.2f s，CRC 重下 %d 次\n', numel(r.channels), r.samples, r.seconds, r.crc_retries);

% 3. DSO：起播同步采集 CH0、CH1
[d, ci] = dso_capture(ip, Channels=[0 1], Samples=65520, Trigger="start");
fprintf('采集：%d 点 × %d 通道，读回 %.0f ms\n', ci.samples, numel(ci.channels), ci.read_seconds * 1e3);
for row = 1:numel(ci.channels)
    m = dso_measure(d(row, :));
    fprintf('ADC%d：%.6f MHz，%.2f dBFS，SFDR %.1f dBc，SINAD %.1f dB，ENOB %.2f bit\n', ...
            ci.channels(row), m.freq_hz / 1e6, m.peak_dbfs, m.sfdr_dbc, m.sinad_db, m.enob_bits);
end

% 4. 时域与频谱图
t = (0:ci.samples - 1) / ci.fs_hz;
[f, db, rbw] = dso_spectrum(d(1, :));
if usejava('desktop')
    figure;
    subplot(2, 1, 1); plot(t(1:end) * 1e6, double(d(1, 1:end)) / 32768); xlabel('时间 (us)'); ylabel('满量程'); grid on;
    subplot(2, 1, 2); plot(f / 1e6, db); xlabel('频率 (MHz)'); ylabel('dBFS'); grid on;
    title(sprintf('ADC0 频谱，RBW %.1f kHz', rbw / 1e3));
end

% 5. 存档（CSV：每列一个通道）
writematrix(double(d.'), 'capture_matlab.csv');

% 6. 停止输出
o = awg_output(ip, Run=false);
fprintf('输出：running=%d\n', o.running);
