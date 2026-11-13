# -*- coding: utf-8 -*-
"""
47DR AWG / 示波器 Python 脚本示例：生成波形 → 缩放 → 下载 → 起播同步采集 → 测量 → 频谱 → 停止。

运行：py -X utf8 example_python.py [板卡IP]
离线试用：先在工程 tools 目录运行 `py -X utf8 -m awg_eth.fpga_emu --loopback --port 9100`，再执行 example_python.py 127.0.0.1
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent / "python"))
import awg47dr as api  # noqa: E402

ip = sys.argv[1] if len(sys.argv) > 1 else "192.168.42.2"

# 1. 检查板卡
st = api.awg_status(ip)
print("板卡：BUILD_ID %s，ps_ready=%s，播放中=%s" % (st["build_id"], st["ps_ready"], st["running"]))
if not st["ps_ready"]:
    raise SystemExit("板卡未初始化：请先用上位机「设备 → 下载 bit 并初始化」")

# 2. AWG：8 个通道分别输出 100, 200, ..., 800 MHz 正弦，幅度 -6 dBFS
rows = []
for ch in range(8):
    w, info = api.awg_generate_waveform("sine", freq_hz=100e6 * (ch + 1), samples=131072)
    codes, sinfo = api.awg_scale_waveform(w, amp_dbfs=-6.0)
    rows.append(codes)
    print("CH%d：实际频率 %.6f MHz，峰值 %.2f dBFS" % (ch, info["freq_hz"] / 1e6, sinfo["peak_dbfs"]))
r = api.awg_download(ip, np.vstack(rows))
print("下载完成：%d 通道 × %d 点，%.2f s，CRC 重下 %d 次，正在播放=%s"
      % (len(r["channels"]), r["samples"], r["seconds"], r["crc_retries"], r["running"]))

# 3. DSO：起播同步采集 CH0、CH1
data, ci = api.dso_capture(ip, channels=[0, 1], samples=65520, trigger="start")
print("采集：%d 点 × %d 通道，读回 %.0f ms" % (ci["samples"], len(ci["channels"]), ci["read_seconds"] * 1e3))
for row, ch in enumerate(ci["channels"]):
    m = api.dso_measure(data[row])
    if "freq_hz" in m:
        print("ADC%d：%.6f MHz，%.2f dBFS，SFDR %.1f dBc，SINAD %.1f dB，ENOB %.2f bit"
              % (ch, m["freq_hz"] / 1e6, m["peak_dbfs"], m["sfdr_dbc"], m["sinad_db"], m["enob_bits"]))

# 4. 频谱（可用 matplotlib 画图）
f, db, rbw = api.dso_spectrum(data[0])
k = int(np.argmax(db))
print("ADC0 频谱峰：%.3f MHz，%.2f dBFS，RBW %.1f kHz" % (f[k] / 1e6, db[k], rbw / 1e3))

# 5. 存档（CSV：每列一个通道）
np.savetxt("capture.csv", data.T, fmt="%d", delimiter=",", header=",".join("ADC%d" % c for c in ci["channels"]))
print("已保存 capture.csv")

# 6. 停止输出
print("输出：", api.awg_output(ip, run=False))
