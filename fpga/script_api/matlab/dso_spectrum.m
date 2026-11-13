function [freqHz, dbfs, rbwHz] = dso_spectrum(x, options)
% DSO_SPECTRUM  计算单边幅度谱（dBFS）
%
%   [freqHz, dbfs, rbwHz] = dso_spectrum(x, Name=Value ...)
%
%   满量程正弦的谱峰读数为 0 dBFS（已做窗函数相干增益校正）。不需要信号处理工具箱，不调用其他自定义函数。
%
%   输入：
%     x           波形向量（dso_capture 返回矩阵的某一行，int16 或 double）
%   可选参数（Name=Value）：
%     FsHz        采样率，默认 5e9（ADC）
%     Window      窗函数："blackmanharris"（默认，旁瓣低，适合看杂散）、"hann"、"flattop"（幅度最准）、"rect"（不加窗）
%     FullScale   满量程对应的数值，int16 容器为 32768（默认）；满量程单位的浮点波形请传 1
%
%   输出：
%     freqHz      1×(N/2+1) 频率轴（Hz）
%     dbfs        1×(N/2+1) 各频点幅度（dBFS）
%     rbwHz       分辨率带宽 = 等效噪声带宽 × Fs / N（Hz）
%
%   示例：
%     [f, db] = dso_spectrum(d(1,:));  plot(f/1e6, db); xlabel('MHz'); ylabel('dBFS');

arguments
    x {mustBeNumeric, mustBeVector}
    options.FsHz (1,1) double {mustBePositive} = 5e9
    options.Window {mustBeMember(options.Window, ["blackmanharris", "hann", "flattop", "rect"])} = "blackmanharris"
    options.FullScale (1,1) double {mustBePositive} = 32768
end

y = double(reshape(x, 1, []));
n = numel(y);
if n < 2
    error('dso_spectrum:length', '波形至少要 2 点');
end

% ---- 1. 窗函数（系数直接写在这里）----
k = (0:n-1) / max(n - 1, 1);
switch options.Window
    case "blackmanharris"
        w = 0.35875 - 0.48829 * cos(2*pi*k) + 0.14128 * cos(4*pi*k) - 0.01168 * cos(6*pi*k);
    case "hann"
        w = 0.5 - 0.5 * cos(2*pi*k);
    case "flattop"
        w = 0.21557895 - 0.41663158 * cos(2*pi*k) + 0.277263158 * cos(4*pi*k) ...
            - 0.083578947 * cos(6*pi*k) + 0.006947368 * cos(8*pi*k);
    otherwise
        w = ones(1, n);
end

% ---- 2. 去直流、加窗、FFT，只取单边 0..Fs/2；幅度 = |X| / (sum(w)/2) / 满量程 ----
spec = fft((y - mean(y)) .* w);
spec = spec(1:floor(n / 2) + 1);
mag = abs(spec) / (sum(w) / 2) / options.FullScale;
dbfs = 20 * log10(max(mag, 1e-12));

% ---- 3. 频率轴与 RBW ----
freqHz = (0:numel(spec)-1) * options.FsHz / n;
enbw = n * sum(w .^ 2) / sum(w) ^ 2;              % 等效噪声带宽（单位：bin）
rbwHz = enbw * options.FsHz / n;
end
