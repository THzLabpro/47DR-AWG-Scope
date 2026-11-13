# 47DR AWG / 示波器 脚本接口说明（V1.2）

本目录提供"纯代码调用"的函数，用于在 Python 或 MATLAB 脚本里控制 47DR 板卡，不需要打开上位机界面。
- AWG：任意波形发生器，DAC 9.8 GS/s。
- DSO：示波器/频谱仪，ADC 5 GS/s。

适用位元流：V1（D3C，BUILD_ID `0xD3C02026`）。V2 位元流仍兼容这些函数（9100 协议不变），只是用不到 V2 的新功能。

## 1. 设计约定

- **每个函数只有一个函数体**：不调用本接口的其他函数，也没有内部子函数或匿名函数。
  - 任何一个函数都可以单独复制到你的脚本里使用；
  - 需要网络通信的函数各自带有完整的 UDP 协议实现。
- Python 和 MATLAB 两套函数一一对应：名称、参数、算法和返回内容都相同。
  - 已用同一份采集数据交叉比对，测量结果一致（误差 < 1e-6）。
- 依赖：
  - Python：3.8 及以上，加 numpy；
  - MATLAB：R2019b 及以上（用到 `arguments` 块）。通信用 MATLAB 自带的 Java，**不需要任何工具箱**。
- 通道号一律**从 0 开始**（CH0..CH7），与面板和上位机一致，MATLAB 也一样。

## 2. 函数一览

| 功能 | Python（`python/awg47dr.py`） | MATLAB（`matlab/*.m`） | 是否联网 |
|---|---|---|---|
| 生成标准波形 | `awg_generate_waveform(kind, freq_hz, samples, ...)` | `awg_generate_waveform(kind, FreqHz=..., Samples=...)` | 否 |
| 幅度缩放 + 量化 | `awg_scale_waveform(wave, amp_dbfs, offset_fs, mode, fit)` | `awg_scale_waveform(wave, AmpDbfs=..., ...)` | 否 |
| 下载波形 | `awg_download(ip, waveforms, channels, run, verify, ...)` | `awg_download(ip, waveforms, Channels=..., ...)` | 是 |
| 输出 Run/Stop | `awg_output(ip, run)` | `awg_output(ip, Run=true/false)` | 是 |
| 读状态 | `awg_status(ip)` | `awg_status(ip)` | 是 |
| 采集 | `dso_capture(ip, channels, samples, trigger, ...)` | `dso_capture(ip, Channels=..., Samples=..., Trigger=...)` | 是 |
| 频谱 | `dso_spectrum(x, fs_hz, window)` | `dso_spectrum(x, FsHz=..., Window=...)` | 否 |
| 单音测量 | `dso_measure(x, fs_hz, window)` | `dso_measure(x, FsHz=..., Window=...)` | 否 |

每个函数开头都有详细注释，说明全部参数、返回值和示例。查看方式：Python 用 `help(awg47dr.awg_download)`，MATLAB 用 `help awg_download`。

## 3. 数据格式

| 项目 | 说明 |
|---|---|
| 浮点波形 | `awg_generate_waveform` 的输出，满量程单位，峰值 = 1.0 |
| DAC/ADC 码 | int16 容器：14 bit 码左移 2 位（低 2 位为 0），满量程 = 32768。`awg_scale_waveform` 的输出和 `dso_capture` 的读回都是这种格式 |
| 幅度 | dBFS（相对满量程的峰值），0 dBFS = 满量程。dBm/Vpp 校准尚未提供 |
| AWG 长度 | 32..131072 点，必须是 32 的倍数；所有通道等长；循环播放 |
| 周期波形频率 | 自动对齐到"整数个周期"（首尾无缝），实际频率见 `info.freq_hz` |
| DSO 长度 | 24..65520 点，必须是 24 的倍数；8 个通道同时采集、时间对齐 |
| 采样率 | DAC 9.8e9，ADC 5e9 |

## 4. 使用前准备

1. 板卡已经「下载 bit 并初始化」：用上位机菜单，或执行 `AWG47DR_V1.exe --program`。用 `awg_status(ip)` 检查 `ps_ready` 是否为真。
2. PC 40G 网卡设 192.168.42.x/24，**不要用 .10**（FPGA 对 .10 写死了原测试 PC 的 MAC），例如 192.168.42.20。MTU 设 9000。
   - 没开巨型帧时，把各函数的 `words_per_packet` / `WordsPerPacket` 设为 256。
3. Python：把 `python/awg47dr.py` 放到脚本旁边，或加入 `sys.path`。
   MATLAB：`addpath('<本目录>/matlab')`。

## 5. 示例

### Python

```python
import numpy as np
import awg47dr as api

ip = "192.168.42.2"
print(api.awg_status(ip))                                       # ps_ready 应为 True

# AWG：CH0 100 MHz 正弦 -6 dBFS，CH1 方波 -10 dBFS
w0, info0 = api.awg_generate_waveform("sine", freq_hz=100e6, samples=131072)
w1, _ = api.awg_generate_waveform("square", freq_hz=50e6, samples=131072, duty=0.3)
c0, _ = api.awg_scale_waveform(w0, amp_dbfs=-6)
c1, _ = api.awg_scale_waveform(w1, amp_dbfs=-10)
r = api.awg_download(ip, np.vstack([c0, c1]), channels=[0, 1])  # 下载 + CRC 校验 + 自动 Run
print("实际频率 %.6f MHz，耗时 %.2f s" % (info0["freq_hz"] / 1e6, r["seconds"]))

# 导入任意波形：例如从 .npy 读入、自动补齐到 32 的倍数、缩放到 -3 dBFS
# arb, _ = api.awg_scale_waveform(np.load("my_wave.npy"), amp_dbfs=-3, fit="pad")

# DSO：起播同步采集 CH0，测量 + 频谱
data, ci = api.dso_capture(ip, channels=[0], samples=65520, trigger="start")
m = api.dso_measure(data[0])
print("%.6f MHz  %.2f dBFS  SFDR %.1f dBc  SNR %.1f dB" % (m["freq_hz"] / 1e6, m["peak_dbfs"], m["sfdr_dbc"], m["snr_db"]))
f, db, rbw = api.dso_spectrum(data[0], window="blackmanharris")
api.awg_output(ip, run=False)                                    # 停止输出
```

### MATLAB

```matlab
addpath('script_api/matlab');
ip = '192.168.42.2';
st = awg_status(ip)                                               % st.ps_ready 应为 true

[w0, info0] = awg_generate_waveform('sine', FreqHz=100e6, Samples=131072);
w1 = awg_generate_waveform('square', FreqHz=50e6, Duty=0.3);
c0 = awg_scale_waveform(w0, AmpDbfs=-6);
c1 = awg_scale_waveform(w1, AmpDbfs=-10);
r = awg_download(ip, [c0; c1], Channels=[0 1]);                   % 下载 + CRC + 自动 Run

[d, ci] = dso_capture(ip, Channels=0, Samples=65520, Trigger="start");
m = dso_measure(d(1,:));
fprintf('%.6f MHz  %.2f dBFS  SFDR %.1f dBc\n', m.freq_hz/1e6, m.peak_dbfs, m.sfdr_dbc);
[f, db] = dso_spectrum(d(1,:));
plot(f/1e6, db); xlabel('频率 (MHz)'); ylabel('dBFS'); grid on;
awg_output(ip, Run=false);
```

完整示例：`example_python.py`、`example_matlab.m`。

## 6. 参数要点

- `awg_generate_waveform`：波形种类包括 `sine`、`square`、`triangle`、`ramp`、`pulse`、`noise`、`multitone`、`chirp`、`dc`。
  - 方波/脉冲用 duty 设占空比；多音用 tones、spacing_hz；扫频用 stop_hz；
  - 噪声的随机序列在 Python 和 MATLAB 之间不同（随机数生成器不同）。
- `awg_scale_waveform`：
  - `mode='peak'`（默认）：先把峰值归一，再缩放到 amp_dbfs；
  - `mode='gain'`：把输入当作满量程单位，直接乘以增益；
  - 超出满量程的点会被削顶，数量见 `clipped`；
  - 长度不是 32 的倍数时默认报错，可用 `fit='pad'`（补零）或 `'truncate'`（截断）。
- `awg_download`：
  - 先 Stop、清故障、关闭全部输出，再逐通道下载并做 CRC 校验，不一致时自动重下，最多 3 次；
  - 最后只打开已下载的通道；`run=True` 时自动 Run。
- `dso_capture`：
  - `trigger='manual'` 立即采集；
  - `trigger='start'` 是 AWG 起播同步：先 Stop，arm 后 Start，采集起点与波形起点对齐，可用于测延迟。
- `dso_measure`：
  - 频率用三点抛物线插值；幅度用主瓣能量计算，不受栅栏效应影响；
  - SNR 扣除 2..5 次谐波，包括混叠位置。
- `dso_spectrum`：满量程正弦读 0 dBFS；RBW 等于窗函数的等效噪声带宽乘以 Fs/N。

## 7. 错误与排查

| 现象 | 原因与处理 |
|---|---|
| `TimeoutError` / `*:timeout`「板卡无回复」 | 光口没连、IP 不对、PC 用了 192.168.42.10、板卡没初始化，或 MTU 不是 9000 但用了 2048 字/包 |
| 「命令 2 被拒绝」（Start） | PS 未就绪（先初始化），或还没下载波形 |
| 「FPGA 返回错误 status=1」 | 寄存器拒绝写入，通常是播放中修改长度/掩码。函数内部已先 Stop，一般不会出现 |
| CRC 不一致（重下 3 次仍错） | 链路有问题。改小 `words_per_packet` 试试，并检查光纤 |
| 采集超时 | 起播同步时没有下载过波形，所以 Start 被拒。下次采集会自动清掉残留状态 |

## 8. 协议摘要（供参考）

- UDP 端口 9100。每个请求都有 24 字节头（little-endian），回复的 opcode 为请求 opcode | 0x80，seq 原样带回：

  | 字段 | 类型 |
  |---|---|
  | magic | `0xA7E1` |
  | version | 1 |
  | opcode | 1 READ / 2 WRITE |
  | seq | u32 |
  | addr | u32 |
  | count | u16，字数 |
  | flags | bit0 = NOINC |
  | status | u16 |
  | err_index | u16 |
  | reserved | u32 |

- 寄存器基址 `0x9020_0000`：

  | 偏移 | 寄存器 |
  |---|---|
  | 0x04 | STATUS |
  | 0x08 | COMMAND（1 stop、2 start、4 清故障、8 arm、16 CRC、32 取消采集） |
  | 0x0C | TX_LENGTH |
  | 0x10 | TX_MASK |
  | 0x30 / 0x38 | TX_WR_CH / TX_WR_DATA |
  | 0x3C | TX_CRC |
  | 0x28 / 0x2C | CAP_STATUS / CAP_SAMPLES |
  | 0x40 / 0x44 / 0x48 | CAP_RD_CH / PTR / DATA |
  | 0x4C | CAP_CTRL |

- 可靠性：
  - FPGA 对写请求按 seq 去重，所以超时后重发同一个 seq 是安全的；
  - 读采集数据的端口每读一次指针就前进，所以读回时每段都先设指针，超时则"设指针 + 读"整段重做。
- 完整规格见工程的 `doc/00_ETH_PLAN.md` §4 和 `doc/01_DATAPATH_V2.md`。

## 9. 测试

- `tests/test_python_api.py`：对内置 FPGA 模拟器跑完整流程，并注入 10% 丢包和 10% 重复包；同时与上位机算法逐点比对，并检查每个函数都是单一函数体。
- `tests/test_matlab_api.py`：运行 MATLAB 版本，模拟器注入 5% 丢包和 5% 重复包；与 Python 版本交叉比对；检查每个 .m 文件只有一个函数。
- 运行方法（需要工程的 `tools/` 目录，里面有模拟器）：在工程根目录执行 `py -X utf8 -m pytest -q script_api/tests`。
- 2026-11-12 上板结果（D3C）：

  | 语言 | 下载 | 采集 + 读回 | CH0 回环 |
  |---|---|---|---|
  | Python | 8 通道 × 131072 点含 CRC 0.12 s | 2 通道 × 65520 点 39 ms | 99.96483 MHz |
  | MATLAB | 1 通道含 CRC 0.10 s | 65520 点 147 ms | 99.96483 MHz |

  两种语言的测量结果一致。
