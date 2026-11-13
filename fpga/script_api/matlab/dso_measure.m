function m = dso_measure(x, options)
% DSO_MEASURE  单音测量（示波器/频谱仪自动测量）
%
%   m = dso_measure(x, Name=Value ...)
%
%   适合输入是单个正弦（加噪声和杂散）的情况。不需要信号处理工具箱，不调用其他自定义函数。
%
%   输入：
%     x           波形向量（dso_capture 返回矩阵的某一行）
%   可选参数（Name=Value）：
%     FsHz        采样率，默认 5e9
%     Window      窗函数："blackmanharris"（默认）、"hann"、"flattop"、"rect"
%     FullScale   满量程对应的数值，int16 容器为 32768（默认）
%     Harmonics   计算 SNR 时扣除的谐波阶数上限（2..Harmonics 次，含混叠位置），默认 5
%
%   输出（结构体）：
%     freq_hz     基波频率（Hz，抛物线插值，优于 1 个 bin）
%     peak_dbfs   基波峰值幅度（dBFS，由主瓣能量计算，不受栅栏效应影响）
%     amp_lsb     基波峰值幅度（int16 数值）
%     vpp_lsb     时域峰峰值；rms_lsb 时域 RMS（去直流）；mean_lsb 直流平均
%     sfdr_dbc    无杂散动态范围（基波与最大杂散之比）
%     sinad_db    信号与噪声+失真之比；snr_db 信噪比（扣除谐波）；enob_bits 有效位数
%     （点数少于 64 时只给时域结果，频域字段为 NaN）
%
%   示例：
%     m = dso_measure(d(1,:));  fprintf('%.6f MHz, %.2f dBFS, SFDR %.1f dBc\n', m.freq_hz/1e6, m.peak_dbfs, m.sfdr_dbc);

arguments
    x {mustBeNumeric, mustBeVector}
    options.FsHz (1,1) double {mustBePositive} = 5e9
    options.Window {mustBeMember(options.Window, ["blackmanharris", "hann", "flattop", "rect"])} = "blackmanharris"
    options.FullScale (1,1) double {mustBePositive} = 32768
    options.Harmonics (1,1) double = 5
end

y = double(reshape(x, 1, []));
n = numel(y);
m = struct('freq_hz', NaN, 'peak_dbfs', NaN, 'amp_lsb', NaN, ...
           'vpp_lsb', max(y) - min(y), 'rms_lsb', sqrt(mean((y - mean(y)) .^ 2)), 'mean_lsb', mean(y), ...
           'sfdr_dbc', NaN, 'sinad_db', NaN, 'snr_db', NaN, 'enob_bits', NaN);
if n < 64
    return                                         % 点数太少，只给时域结果
end

% ---- 1. 窗函数与主瓣半宽（bin）----
k = (0:n-1) / max(n - 1, 1);
switch options.Window
    case "blackmanharris"
        w = 0.35875 - 0.48829 * cos(2*pi*k) + 0.14128 * cos(4*pi*k) - 0.01168 * cos(6*pi*k);
        half = 5;
    case "hann"
        w = 0.5 - 0.5 * cos(2*pi*k);
        half = 3;
    case "flattop"
        w = 0.21557895 - 0.41663158 * cos(2*pi*k) + 0.277263158 * cos(4*pi*k) ...
            - 0.083578947 * cos(6*pi*k) + 0.006947368 * cos(8*pi*k);
        half = 6;
    otherwise
        w = ones(1, n);
        half = 1;
end

% ---- 2. 单边功率谱；DC 附近清零 ----
spec = fft((y - mean(y)) .* w);
power = abs(spec(1:floor(n / 2) + 1)) .^ 2;
power(1:half + 1) = 0;
[pk, i0] = max(power);                             % i0 为 MATLAB 下标（从 1 开始），对应 bin = i0 - 1
if pk <= 0
    return
end
kmax = i0 - 1;

% ---- 3. 频率：对数幅度三点抛物线插值 ----
delta = 0;
if i0 > 1 && i0 < numel(power) && power(i0 - 1) > 0 && power(i0 + 1) > 0
    a = log(power(i0 - 1));
    b = log(power(i0));
    c = log(power(i0 + 1));
    if (a - 2*b + c) ~= 0
        delta = 0.5 * (a - c) / (a - 2*b + c);
    end
end
m.freq_hz = (kmax + delta) * options.FsHz / n;

% ---- 4. 基波能量（主瓣 ±half bin）；其余 = 噪声 + 失真 ----
lo = max(kmax - half, 0);
hi = min(kmax + half, numel(power) - 1);
sig = sum(power(lo + 1:hi + 1));
rest = power;
rest(lo + 1:hi + 1) = 0;
totalNd = sum(rest);

% ---- 5. 谐波能量（2..Harmonics 次，混叠到第一奈奎斯特区）----
harm = 0;
for h = 2:round(options.Harmonics)
    binH = mod(round(kmax * h), n);
    if binH > floor(n / 2)
        binH = n - binH;
    end
    hl = max(binH - half, 0);
    hh = min(binH + half, numel(power) - 1);
    harm = harm + sum(rest(hl + 1:hh + 1));
end
noise = max(totalNd - harm, 1e-30);

% ---- 6. 幅度（Parseval：主瓣能量 = N·A²/4·sum(w²)）与各项指标 ----
amp = sqrt(4 * sig / (n * sum(w .^ 2)));
m.amp_lsb = amp;
m.peak_dbfs = 20 * log10(max(amp / options.FullScale, 1e-12));
m.sinad_db = 10 * log10(sig / max(totalNd, 1e-30));
m.snr_db = 10 * log10(sig / noise);
m.sfdr_dbc = 10 * log10(pk / max(max(rest), 1e-30));
m.enob_bits = (m.sinad_db - 1.76) / 6.02;
end
