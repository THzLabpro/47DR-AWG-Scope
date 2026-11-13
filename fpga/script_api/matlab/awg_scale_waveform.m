function [codes, info] = awg_scale_waveform(wave, options)
% AWG_SCALE_WAVEFORM  幅度缩放（dBFS）+ 直流偏置 + 长度整理 + 量化成 14 bit DAC 码
%
%   [codes, info] = awg_scale_waveform(wave, Name=Value ...)
%
%   输出可直接交给 awg_download。本函数不调用其他自定义函数，可单独使用。
%
%   输入：
%     wave        任意波形向量（行或列，double/single/整数均可）
%   可选参数（Name=Value）：
%     AmpDbfs     目标幅度（dBFS，相对 DAC 满量程的峰值），默认 -6。0 dBFS = 满量程
%     OffsetFs    直流偏置（满量程单位，-1..1），在缩放之后叠加，默认 0
%     Mode        "peak"：先把峰值归一为 1，再乘以 10^(AmpDbfs/20)（默认，适合任意单位的输入）
%                 "gain"：不归一，把输入当作满量程单位直接乘以 10^(AmpDbfs/20)
%     Fit         长度不是 32 的倍数或超出 32..131072 时：
%                 "error" 报错（默认）、"pad" 末尾补零、"truncate" 截掉末尾（不足 32 点时仍补零）
%
%   输出：
%     codes       1×N int16 行向量：14 bit 码左移 2 位（低 2 位为 0），范围 -32768..32764
%     info        结构体：samples 点数、gain 线性增益、peak_dbfs 量化后峰值、clipped 削顶点数、note 长度处理说明
%
%   示例：
%     codes = awg_scale_waveform(sin(2*pi*(0:4095)/64), AmpDbfs=-3);

arguments
    wave {mustBeNumeric, mustBeVector}
    options.AmpDbfs (1,1) double = -6
    options.OffsetFs (1,1) double = 0
    options.Mode {mustBeMember(options.Mode, ["peak", "gain"])} = "peak"
    options.Fit {mustBeMember(options.Fit, ["error", "pad", "truncate"])} = "error"
end

% ---- 1. 输入检查 ----
y = double(wave(:)).';
if isempty(y)
    error('awg_scale_waveform:empty', 'wave 不能为空');
end
if any(~isfinite(y))
    error('awg_scale_waveform:finite', 'wave 含有 NaN 或 Inf');
end

% ---- 2. 长度整理：硬件要求 32..131072 且为 32 的倍数 ----
note = '';
if numel(y) > 131072
    if options.Fit == "error"
        error('awg_scale_waveform:length', '波形长度 %d 超过 131072；可用 Fit="truncate"', numel(y));
    end
    y = y(1:131072);
    note = '超过 131072 点，已截断';
end
r = mod(numel(y), 32);
if r ~= 0 || numel(y) < 32
    if options.Fit == "error"
        error('awg_scale_waveform:length', '波形长度 %d 不是 32 的倍数；可用 Fit="pad" 或 Fit="truncate"', numel(y));
    end
    if options.Fit == "pad" || numel(y) < 32
        if numel(y) >= 32
            padN = 32 - r;
        else
            padN = 32 - numel(y);
        end
        y = [y, zeros(1, padN)];
        note = strtrim([note, sprintf(' 末尾补零 %d 点', padN)]);
    else
        y = y(1:end-r);
        note = strtrim([note, sprintf(' 截掉末尾 %d 点', r)]);
    end
end

% ---- 3. 幅度缩放（dBFS → 线性）----
target = 10 ^ (options.AmpDbfs / 20);
if options.Mode == "peak"
    pk = max(abs(y));
    if pk > 0
        gain = target / pk;
    else
        gain = 0;                                  % 全零波形保持为零
    end
else
    gain = target;
end
y = y * gain + options.OffsetFs;

% ---- 4. 量化成 14 bit：满量程 ±1.0 → 码 -8192..8191，再左移 2 位放进 int16 ----
codes14 = round(y * 8191);
clipped = nnz(codes14 > 8191 | codes14 < -8192);
codes14 = min(max(codes14, -8192), 8191);
codes = int16(codes14 * 4);

peakCode = double(max(abs(double(codes))));
info = struct('samples', numel(codes), 'gain', gain, ...
              'peak_dbfs', 20 * log10(max(peakCode / 32768, 1e-12)), ...
              'clipped', clipped, 'note', note);
end
