function [wave, info] = awg_generate_waveform(kind, options)
% AWG_GENERATE_WAVEFORM  生成标准波形（峰值归一为 1.0，满量程单位）
%
%   [wave, info] = awg_generate_waveform(kind, Name=Value ...)
%
%   幅度、直流偏置和量化请交给 awg_scale_waveform。本函数不调用其他自定义函数，可单独使用。
%
%   输入：
%     kind        波形类型（字符串）：
%                 'sine' 正弦、'square' 方波、'triangle' 三角波、'ramp' 锯齿波、'pulse' 脉冲（0/1）、
%                 'noise' 高斯噪声、'multitone' 多音、'chirp' 线性扫频、'dc' 直流
%   可选参数（Name=Value）：
%     FreqHz      频率（Hz），默认 100e6。周期类波形对齐到整数周期，保证循环播放首尾无缝；
%                 多音为起始音频率；扫频为起始频率
%     Samples     波形长度（点），默认 131072；限制在 32..131072，并向下取整到 32 的倍数
%     PhaseDeg    初相位（度），默认 0
%     Duty        占空比（方波、脉冲），默认 0.5
%     Tones       多音的音数，默认 8
%     SpacingHz   多音的频率间隔（Hz），默认 50e6
%     StopHz      扫频终止频率（Hz），默认 1e9（会微调使总相位为整数周期）
%     Seed        噪声的随机种子，默认 1（注意：与 Python 版的随机序列不同）
%     FsHz        DAC 采样率，默认 9.8e9
%
%   输出：
%     wave        1×N double 行向量，峰值绝对值 = 1.0
%     info        结构体：samples 实际点数；freq_hz 实际频率、cycles 整数周期数（周期类）；
%                 freqs_hz 各音频率（多音）；start_hz、stop_hz（扫频）
%
%   示例：
%     [w, info] = awg_generate_waveform('sine', FreqHz=100e6, Samples=131072);
%     codes = awg_scale_waveform(w, AmpDbfs=-6);

arguments
    kind {mustBeTextScalar} = 'sine'
    options.FreqHz (1,1) double {mustBePositive} = 100e6
    options.Samples (1,1) double = 131072
    options.PhaseDeg (1,1) double = 0
    options.Duty (1,1) double = 0.5
    options.Tones (1,1) double = 8
    options.SpacingHz (1,1) double = 50e6
    options.StopHz (1,1) double = 1e9
    options.Seed (1,1) double = 1
    options.FsHz (1,1) double {mustBePositive} = 9.8e9
end

kind = lower(char(kind));
fs = options.FsHz;

% ---- 1. 长度整理：32..131072，且为 32 的倍数 ----
n = floor(options.Samples);
n = max(32, min(131072, n));
n = n - mod(n, 32);
idx = 0:n-1;                                  % 样点序号
phase = options.PhaseDeg * pi / 180;          % 初相位（弧度）
info = struct('samples', n);

switch kind
    % ---- 2. 周期类波形：频率对齐到整数周期 ----
    case {'sine', 'square', 'triangle', 'ramp', 'pulse'}
        cycles = round(options.FreqHz * n / fs);          % 整数周期数
        cycles = max(1, min(cycles, floor(n / 2) - 1));   % 至少 1 个周期，低于奈奎斯特
        info.cycles = cycles;
        info.freq_hz = cycles * fs / n;
        frac = mod(idx * cycles / n + phase / (2 * pi), 1.0);   % 周期内位置 0..1
        d = min(max(options.Duty, 0.001), 0.999);
        switch kind
            case 'sine'
                wave = sin(2 * pi * frac);
            case 'square'
                wave = 2 * double(frac < d) - 1;
            case 'triangle'
                wave = 1 - 4 * abs(frac - 0.5);
            case 'ramp'
                wave = 2 * frac - 1;
            otherwise                                      % pulse：高电平 1，低电平 0
                wave = double(frac < d);
        end

    % ---- 3. 高斯噪声：截断在 ±4σ，再把峰值归一为 1 ----
    case 'noise'
        rng(options.Seed);
        wave = max(min(randn(1, n), 4), -4);
        wave = wave / max(max(abs(wave)), 1e-12);

    % ---- 4. 多音：各音对齐到整数周期，Schroeder 相位降低峰均比 ----
    case 'multitone'
        count = max(1, round(options.Tones));
        base = round(options.FreqHz * n / fs);
        base = max(1, min(base, floor(n / 2) - 1));
        step = max(1, round(options.SpacingHz * n / fs));
        cyc = base + step * (0:count-1);
        cyc = cyc(cyc < floor(n / 2));
        m = numel(cyc);
        wave = zeros(1, n);
        for k = 0:m-1
            schroeder = pi * k * (k + 1) / max(m, 1);      % Schroeder 相位
            wave = wave + sin(2 * pi * cyc(k + 1) * idx / n + schroeder + phase);
        end
        wave = wave / max(max(abs(wave)), 1e-12);
        info.freqs_hz = cyc * fs / n;

    % ---- 5. 线性扫频：调整终止频率，使总相位为整数周期 ----
    case 'chirp'
        f0 = options.FreqHz;
        totalCycles = max(1, round((f0 + options.StopHz) / 2 * n / fs));
        f1 = 2 * totalCycles * fs / n - f0;
        t = idx / fs;
        duration = n / fs;
        wave = sin(2 * pi * (f0 * t + (f1 - f0) * t .^ 2 / (2 * duration)) + phase);
        info.start_hz = f0;
        info.stop_hz = f1;

    % ---- 6. 直流 ----
    case 'dc'
        wave = ones(1, n);

    otherwise
        error('awg_generate_waveform:kind', ...
              'kind 必须是 sine/square/triangle/ramp/pulse/noise/multitone/chirp/dc 之一，收到 %s', kind);
end
end
