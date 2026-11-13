# -*- coding: utf-8 -*-
"""
47DR AWG / 示波器 —— Python 脚本接口（V1.2，配合 D3C 位元流）

本文件提供 8 个互相独立的函数，每个函数都只有一个函数体，不调用本文件里的其他函数，也没有内部子函数，
可以单独复制到任何脚本中使用。只依赖 Python 3.8+ 标准库和 numpy。

AWG（任意波形发生器，DAC 9.8 GS/s，8 通道，每通道最多 131072 点，14 bit）：
    awg_generate_waveform  生成标准波形（正弦/方波/三角/锯齿/脉冲/噪声/多音/扫频/直流），峰值归一为 1.0
    awg_scale_waveform     幅度缩放（dBFS）+ 直流偏置 + 长度整理 + 量化成 14 bit DAC 码
    awg_download           经 40GbE 光口下载波形到指定通道，逐通道 CRC 校验，可选下载后自动播放
    awg_output             输出 Run / Stop
    awg_status             读取板卡状态

DSO（示波器/频谱仪，ADC 5 GS/s，8 通道，每通道最多 65520 点，14 bit）：
    dso_capture            触发采集并读回 ADC 数据
    dso_spectrum           计算单边幅度谱（dBFS），可选窗函数
    dso_measure            单音测量：频率、峰值 dBFS、Vpp、RMS、SFDR、SINAD、SNR、ENOB

数据约定：
    * 波形样点用 int16 容器表示 14 bit 码：14 bit 码左移 2 位放进 int16（低 2 位为 0），满量程 = 32768。
      awg_scale_waveform 输出的就是这种格式；dso_capture 读回的也是这种格式。
    * 板卡默认 IP 192.168.42.2，UDP 端口 9100；PC 网卡需在 192.168.42.0/24 网段（不要用 .10，见说明文档）。
    * 每包字数 words_per_packet 默认 2048，需要网卡开巨型帧（MTU 9000）；不支持巨型帧时改为 256。
"""


def awg_generate_waveform(kind="sine", freq_hz=100e6, samples=131072, phase_deg=0.0, duty=0.5,
                          tones=8, spacing_hz=50e6, stop_hz=1e9, seed=1, fs_hz=9.8e9):
    """
    生成标准波形，返回峰值归一为 1.0 的浮点波形（满量程单位，±1.0 = DAC 满量程）。
    幅度、直流偏置和量化请交给 awg_scale_waveform。

    参数：
        kind        波形类型：'sine' 正弦、'square' 方波、'triangle' 三角波、'ramp' 锯齿波、'pulse' 脉冲（0/1）、
                    'noise' 高斯噪声、'multitone' 多音、'chirp' 线性扫频、'dc' 直流
        freq_hz     频率（Hz）。周期类波形会被对齐到"整数个周期"，保证循环播放首尾无缝；多音为起始音频率；
                    扫频为起始频率
        samples     波形长度（点），会被限制在 32..131072 并向下取整到 32 的倍数（硬件以 32 点为单位）
        phase_deg   初相位（度）
        duty        占空比（方波、脉冲），0.001..0.999
        tones       多音的音数
        spacing_hz  多音的频率间隔（Hz），同样对齐到整数周期
        stop_hz     扫频终止频率（Hz），会微调使总相位为整数周期（循环无缝）
        seed        噪声/随机相位的随机种子
        fs_hz       DAC 采样率，默认 9.8e9

    返回：
        (wave, info)
        wave  numpy float64 一维数组，长度 = 实际点数，峰值绝对值 = 1.0（直流波形全为 1.0）
        info  dict：samples 实际点数、freq_hz 实际频率（周期类）、freqs_hz 各音频率（多音）、
              start_hz/stop_hz（扫频）、cycles 整数周期数（周期类）
    """
    import numpy as np

    # ---- 1. 长度整理：32..131072，且为 32 的倍数 ----
    n = int(samples)
    n = max(32, min(131072, n))
    n = n - n % 32
    idx = np.arange(n, dtype=np.float64)          # 样点序号 0..n-1
    phase = np.deg2rad(float(phase_deg))          # 初相位（弧度）
    info = {"samples": n}

    # ---- 2. 周期类波形：频率对齐到整数周期 ----
    if kind in ("sine", "square", "triangle", "ramp", "pulse"):
        # 整数周期数 = round(f * N / Fs)，至少 1 个周期，且低于奈奎斯特
        cycles = int(round(float(freq_hz) * n / fs_hz))
        cycles = max(1, min(cycles, n // 2 - 1))
        info["cycles"] = cycles
        info["freq_hz"] = cycles * fs_hz / n
        # frac = 每个样点在周期内的位置（0..1），包含初相位
        frac = (idx * cycles / n + phase / (2 * np.pi)) % 1.0
        d = min(max(float(duty), 0.001), 0.999)
        if kind == "sine":
            wave = np.sin(2 * np.pi * frac)
        elif kind == "square":
            wave = np.where(frac < d, 1.0, -1.0)
        elif kind == "triangle":
            wave = 1.0 - 4.0 * np.abs(frac - 0.5)
        elif kind == "ramp":
            wave = 2.0 * frac - 1.0
        else:                                     # pulse：高电平 1，低电平 0
            wave = np.where(frac < d, 1.0, 0.0)

    # ---- 3. 高斯噪声：截断在 ±4σ，再把峰值归一为 1 ----
    elif kind == "noise":
        rng = np.random.default_rng(int(seed))
        wave = np.clip(rng.standard_normal(n), -4.0, 4.0)
        wave = wave / max(np.max(np.abs(wave)), 1e-12)

    # ---- 4. 多音：各音都对齐到整数周期，Schroeder 相位降低峰均比 ----
    elif kind == "multitone":
        count = max(1, int(tones))
        base = int(round(float(freq_hz) * n / fs_hz))
        base = max(1, min(base, n // 2 - 1))
        step = max(1, int(round(float(spacing_hz) * n / fs_hz)))
        cycles_list = [base + step * k for k in range(count) if base + step * k < n // 2]
        wave = np.zeros(n)
        m = len(cycles_list)
        for k, c in enumerate(cycles_list):
            schroeder = np.pi * k * (k + 1) / max(m, 1)          # Schroeder 相位
            wave += np.sin(2 * np.pi * c * idx / n + schroeder + phase)
        wave = wave / max(np.max(np.abs(wave)), 1e-12)
        info["freqs_hz"] = [c * fs_hz / n for c in cycles_list]

    # ---- 5. 线性扫频：调整终止频率，使总相位为整数周期（循环播放无跳变）----
    elif kind == "chirp":
        f0 = float(freq_hz)
        total_cycles = max(1, int(round((f0 + float(stop_hz)) / 2 * n / fs_hz)))
        f1 = 2 * total_cycles * fs_hz / n - f0
        t = idx / fs_hz
        duration = n / fs_hz
        wave = np.sin(2 * np.pi * (f0 * t + (f1 - f0) * t * t / (2 * duration)) + phase)
        info["start_hz"] = f0
        info["stop_hz"] = f1

    # ---- 6. 直流 ----
    elif kind == "dc":
        wave = np.ones(n)

    else:
        raise ValueError("kind 必须是 sine/square/triangle/ramp/pulse/noise/multitone/chirp/dc 之一，收到 %r" % (kind,))

    return wave.astype(np.float64), info


def awg_scale_waveform(wave, amp_dbfs=-6.0, offset_fs=0.0, mode="peak", fit="error"):
    """
    幅度缩放 + 直流偏置 + 长度整理 + 量化，输出可直接交给 awg_download 的 int16 DAC 码。

    参数：
        wave       任意一维波形（list / numpy 数组，浮点或整数均可）
        amp_dbfs   目标幅度（dBFS，相对 DAC 满量程的峰值）。0 dBFS = 满量程，-6 dBFS ≈ 半量程
        offset_fs  直流偏置（满量程单位，-1..1），在缩放之后叠加
        mode       'peak'：先把波形峰值归一为 1，再乘以 10^(amp_dbfs/20)（常用，适合任意单位的输入）
                   'gain'：不归一，直接把输入当作满量程单位并乘以 10^(amp_dbfs/20)（amp_dbfs=0 时等于原样量化）
        fit        长度不是 32 的倍数或超出 32..131072 时的处理：
                   'error' 报错（默认）、'pad' 末尾补零、'truncate' 截掉末尾（不足 32 点时仍补零）

    返回：
        (codes, info)
        codes  numpy int16 一维数组：14 bit 码左移 2 位（低 2 位为 0），范围 -32768..32764
        info   dict：samples 点数、gain 实际线性增益、peak_dbfs 量化后峰值 dBFS、
               clipped 被削顶的点数、note 长度处理说明
    """
    import numpy as np

    # ---- 1. 输入检查 ----
    y = np.asarray(wave, dtype=np.float64).ravel()
    if y.size == 0:
        raise ValueError("wave 不能为空")
    if not np.all(np.isfinite(y)):
        raise ValueError("wave 含有 NaN 或 Inf")
    if mode not in ("peak", "gain"):
        raise ValueError("mode 必须是 'peak' 或 'gain'")

    # ---- 2. 长度整理：硬件要求 32..131072 且为 32 的倍数 ----
    note = ""
    if y.size > 131072:
        if fit == "error":
            raise ValueError("波形长度 %d 超过 131072；可用 fit='truncate'" % y.size)
        y = y[:131072]
        note = "超过 131072 点，已截断"
    rem = y.size % 32
    if rem or y.size < 32:
        if fit == "error":
            raise ValueError("波形长度 %d 不是 32 的倍数；可用 fit='pad' 或 fit='truncate'" % y.size)
        if fit == "pad" or y.size < 32:
            pad = (32 - rem) if y.size >= 32 else (32 - y.size)
            y = np.concatenate([y, np.zeros(pad)])
            note = (note + "；" if note else "") + "末尾补零 %d 点" % pad
        else:
            y = y[: y.size - rem]
            note = (note + "；" if note else "") + "截掉末尾 %d 点" % rem

    # ---- 3. 幅度缩放（dBFS → 线性）----
    target = 10.0 ** (float(amp_dbfs) / 20.0)
    if mode == "peak":
        peak = float(np.max(np.abs(y)))
        gain = target / peak if peak > 0 else 0.0     # 全零波形保持为零
    else:
        gain = target
    y = y * gain + float(offset_fs)

    # ---- 4. 量化成 14 bit：满量程 ±1.0 对应码 -8192..8191，再左移 2 位放进 int16 ----
    codes14 = np.round(y * 8191.0)
    clipped = int(np.count_nonzero((codes14 > 8191) | (codes14 < -8192)))
    codes14 = np.clip(codes14, -8192, 8191).astype(np.int32)
    codes = (codes14 * 4).astype(np.int16)

    peak_code = float(np.max(np.abs(codes.astype(np.float64)))) if codes.size else 0.0
    info = {"samples": int(codes.size), "gain": float(gain),
            "peak_dbfs": float(20 * np.log10(max(peak_code / 32768.0, 1e-12))),
            "clipped": clipped, "note": note}
    return codes, info


def awg_download(ip, waveforms, channels=None, run=True, verify=True, port=9100,
                 words_per_packet=2048, timeout_s=0.2, retries=5):
    """
    把波形下载到 AWG 的指定通道（经 40GbE 光口），逐通道做 CRC 校验，最后设置输出通道并可选自动 Run。

    参数：
        ip                板卡 IP，例如 '192.168.42.2'
        waveforms         三种写法任选：
                          1) 一维 int16 数组：写到 channels 指定的单个通道（默认通道 0）
                          2) 二维 int16 数组（通道数 × 点数）：第 i 行写到 channels[i]（默认 0,1,2,...）
                          3) dict {通道号: 一维 int16 数组}
                          所有通道的长度必须相同，且为 32 的倍数、32..131072（用 awg_scale_waveform 生成即可）
        channels          通道号列表（0..7），见上
        run               True：下载并校验后立即开始播放（Run）；False：保持停止
        verify            True：每个通道下载后让 FPGA 计算 CRC 并与主机计算值比较，不一致自动重下（最多 3 次）
        port              UDP 端口，默认 9100
        words_per_packet  每包字数（每字 = 2 个样点），1..2048；网卡没开巨型帧时用 256
        timeout_s         每个请求等待回复的超时（秒）
        retries           超时重发次数（FPGA 对写入请求按序号去重，重发不会重复写入）

    返回：
        dict：channels 已下载通道、samples 每通道点数、mask 输出通道掩码、seconds 总耗时、
              crc 每通道 CRC（十六进制字符串）、crc_retries 因 CRC 不符而重下的次数、running 是否在播放

    说明：
        * 下载前会先 Stop、清除故障、把输出掩码清 0；未下载的通道不会输出。
        * 本函数自带完整的 UDP 协议实现（24 字节头，见说明文档），不依赖其他文件。
    """
    import collections
    import random
    import socket
    import struct
    import time
    import zlib
    import numpy as np

    t_start = time.perf_counter()

    # ---------------- 1. 整理输入：统一成 {通道: int16 数组} ----------------
    if isinstance(waveforms, dict):
        items = {int(k): np.asarray(v) for k, v in waveforms.items()}
    else:
        arr = np.asarray(waveforms)
        if arr.ndim == 1:
            arr = arr[np.newaxis, :]
        if arr.ndim != 2:
            raise ValueError("waveforms 必须是一维、二维数组或 dict")
        if channels is None:
            channels = list(range(arr.shape[0]))
        channels = [int(c) for c in np.atleast_1d(channels)]
        if len(channels) != arr.shape[0]:
            raise ValueError("channels 个数 (%d) 与波形行数 (%d) 不一致" % (len(channels), arr.shape[0]))
        items = {ch: arr[i] for i, ch in enumerate(channels)}
    if not items:
        raise ValueError("没有要下载的波形")
    lengths = set()
    for ch, s in items.items():
        if not 0 <= ch <= 7:
            raise ValueError("通道号必须是 0..7，收到 %d" % ch)
        if not np.issubdtype(s.dtype, np.integer):
            raise TypeError("通道 %d 的波形不是整数 DAC 码；请先用 awg_scale_waveform 量化" % ch)
        if s.ndim != 1:
            raise ValueError("通道 %d 的波形必须是一维" % ch)
        if s.min() < -32768 or s.max() > 32767:
            raise ValueError("通道 %d 的波形超出 int16 范围" % ch)
        lengths.add(s.size)
    if len(lengths) != 1:
        raise ValueError("所有通道的波形长度必须相同，收到 %s" % sorted(lengths))
    n = lengths.pop()
    if n < 32 or n > 131072 or n % 32:
        raise ValueError("波形长度必须是 32..131072 且为 32 的倍数，收到 %d" % n)
    if not 1 <= int(words_per_packet) <= 2048:
        raise ValueError("words_per_packet 必须是 1..2048")
    wpp = int(words_per_packet)

    # ---------------- 2. 打包成 32 bit 字（低 16 位 = 较早的样点）并算期望 CRC ----------------
    words = {}
    crc_expect = {}
    for ch in sorted(items):
        s16 = np.ascontiguousarray(items[ch].astype("<i2"))
        w = s16.view("<u4")
        words[ch] = w
        # FPGA 只保存每个样点的高 14 bit，所以 CRC 前要把每个 16 bit 的低 2 位清零（掩码 0xFFFCFFFC）
        crc_expect[ch] = zlib.crc32((w & np.uint32(0xFFFCFFFC)).astype("<u4").tobytes()) & 0xFFFFFFFF
    mask = 0
    for ch in words:
        mask |= 1 << ch

    # ---------------- 3. 寄存器地址（AXI4-Lite，基址 0x9020_0000）----------------
    BASE = 0x90200000
    REG_STATUS = BASE + 0x04      # bit0 running、bit1 busy、bit2 ps_ready、bit3 fault、bit5:4 命令结果、bit8 crc_busy
    REG_COMMAND = BASE + 0x08     # 1 stop、2 start、4 清故障、16 计算 CRC
    REG_TX_LENGTH = BASE + 0x0C   # 播放长度（32 点为单位）
    REG_TX_MASK = BASE + 0x10     # 输出通道掩码
    REG_TX_WR_CH = BASE + 0x30    # 选择写入通道（写入即把写指针归零）
    REG_TX_WR_DATA = BASE + 0x38  # 写数据端口（NOINC：同一地址连续写）
    REG_TX_CRC = BASE + 0x3C      # 最近一次 CRC 结果
    OP_READ, OP_WRITE, FLAG_NOINC = 1, 2, 1
    STATUS_TEXT = {1: "AXI 错误（寄存器拒绝，常见原因：播放中修改参数）", 2: "请求格式错误",
                   3: "AXI 超时", 4: "FPGA 忙"}

    # ---------------- 4. 操作队列 ----------------
    # 队列里的每一项是一个 dict：
    #   'write' / 'read'：一个 UDP 请求（单个寄存器或一段数据）
    #   'cmd'           ：复合操作，展开成"写 COMMAND"+"轮询 STATUS 直到命令完成"
    #   'channel'       ：复合操作，展开成"选通道 → 分包写数据 →（CRC 命令 → 读 CRC → 比较）"
    # 'tag' 表示读回结果后要做的处理：'poll' 轮询命令完成、'crc' 比较 CRC
    ops = collections.deque()
    ops.append({"op": "cmd", "value": 1})                                  # Stop
    ops.append({"op": "cmd", "value": 4})                                  # 清除故障
    ops.append({"op": "write", "addr": REG_TX_MASK, "data": [0]})          # 先关闭所有输出
    ops.append({"op": "write", "addr": REG_TX_LENGTH, "data": [n // 32]})  # 播放长度
    for ch in sorted(words):
        ops.append({"op": "channel", "ch": ch, "attempt": 0})
    ops.append({"op": "write", "addr": REG_TX_MASK, "data": [mask]})       # 打开已下载的通道
    if run:
        ops.append({"op": "cmd", "value": 2})                              # Start

    crc_result = {}
    crc_retries = 0
    last_status = 0

    # ---------------- 5. 打开 UDP 套接字 ----------------
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    sock.connect((ip, int(port)))
    seq = random.getrandbits(32)                                           # 请求序号，起始值随机
    try:
        while ops:
            op = ops.popleft()

            # ---- 5a. 复合操作：展开后放回队列最前面 ----
            if op["op"] == "cmd":
                ops.appendleft({"op": "read", "addr": REG_STATUS, "count": 1, "tag": "poll",
                                "value": op["value"], "deadline": time.monotonic() + 5.0})
                ops.appendleft({"op": "write", "addr": REG_COMMAND, "data": [op["value"]]})
                continue
            if op["op"] == "channel":
                ch = op["ch"]
                expand = [{"op": "write", "addr": REG_TX_WR_CH, "data": [ch]}]
                for off in range(0, n // 2, wpp):
                    expand.append({"op": "write", "addr": REG_TX_WR_DATA, "noinc": True,
                                   "data": words[ch][off:off + wpp]})
                if verify:
                    expand.append({"op": "cmd", "value": 16})
                    expand.append({"op": "read", "addr": REG_TX_CRC, "count": 1, "tag": "crc",
                                   "ch": ch, "attempt": op["attempt"]})
                ops.extendleft(reversed(expand))
                continue

            # ---- 5b. 组一个请求包（24 字节头 + 数据），发送并等待对应回复；超时则重发同一序号 ----
            seq = (seq + 1) & 0xFFFFFFFF
            if op["op"] == "write":
                data = np.asarray(op["data"], dtype="<u4")
                opcode, count = OP_WRITE, int(data.size)
                payload = data.tobytes()
            else:
                opcode, count, payload = OP_READ, int(op["count"]), b""
            flags = FLAG_NOINC if op.get("noinc") else 0
            # 头：magic u16、version u8、opcode u8、seq u32、addr u32、count u16、flags u16、status u16、
            #     err_index u16、reserved u32（全部 little-endian）
            request = struct.pack("<HBBIIHHHHI", 0xA7E1, 1, opcode, seq, op["addr"], count, flags, 0, 0, 0) + payload
            reply = None
            for _ in range(int(retries) + 1):
                sock.send(request)
                deadline = time.monotonic() + float(timeout_s)
                while reply is None:
                    remain = deadline - time.monotonic()
                    if remain <= 0:
                        break
                    sock.settimeout(remain)
                    try:
                        pkt = sock.recv(65535)
                    except socket.timeout:
                        break
                    except ConnectionResetError:          # Windows 收到 ICMP 端口不可达时会报这个，忽略
                        continue
                    if len(pkt) < 24:
                        continue
                    magic, _ver, r_op, r_seq, _addr, r_count, _flags, r_status, r_err, _res = \
                        struct.unpack_from("<HBBIIHHHHI", pkt)
                    if magic != 0xA7E1 or r_op != (opcode | 0x80) or r_seq != seq:
                        continue                          # 不是本请求的回复（例如前一次重发的迟到回复）
                    reply = (r_status, r_err, r_count, pkt[24:24 + 4 * r_count])
                if reply is not None:
                    break
            if reply is None:
                raise TimeoutError("板卡 %s:%d 无回复（地址 0x%08X）；请检查光口连线、IP 和板卡是否已初始化"
                                   % (ip, port, op["addr"]))
            r_status, r_err, r_count, r_data = reply
            if r_status != 0:
                raise RuntimeError("FPGA 返回错误 status=%d（%s），地址 0x%08X，出错字索引 %d"
                                   % (r_status, STATUS_TEXT.get(r_status, "未知"), op["addr"], r_err))

            # ---- 5c. 读回结果的处理 ----
            tag = op.get("tag")
            if tag == "poll":
                last_status = struct.unpack_from("<I", r_data)[0]
                busy = (last_status >> 1) & 1
                crc_busy = (last_status >> 8) & 1
                if busy or (op["value"] == 16 and crc_busy):
                    if time.monotonic() > op["deadline"]:
                        raise TimeoutError("命令 %d 超时未完成（STATUS=0x%X）" % (op["value"], last_status))
                    ops.appendleft(op)                    # 还没完成：继续轮询
                    continue
                result = (last_status >> 4) & 3
                if result:
                    raise RuntimeError("命令 %d 被 FPGA 拒绝（结果码 %d，STATUS=0x%X）；"
                                       "Start 被拒通常是 PS 未就绪或波形长度不够" % (op["value"], result, last_status))
            elif tag == "crc":
                actual = struct.unpack_from("<I", r_data)[0]
                ch = op["ch"]
                if actual != crc_expect[ch]:
                    if op["attempt"] >= 2:
                        raise RuntimeError("通道 %d CRC 不一致：期望 0x%08X，实际 0x%08X（已重下 3 次）"
                                           % (ch, crc_expect[ch], actual))
                    crc_retries += 1
                    ops.appendleft({"op": "channel", "ch": ch, "attempt": op["attempt"] + 1})   # 整个通道重下
                else:
                    crc_result[ch] = "0x%08X" % actual
    finally:
        sock.close()

    return {"channels": sorted(words), "samples": n, "mask": mask,
            "seconds": time.perf_counter() - t_start, "crc": crc_result if verify else {},
            "crc_retries": crc_retries, "running": bool(run)}


def awg_output(ip, run=True, port=9100, timeout_s=0.2, retries=5):
    """
    AWG 输出 Run（开始循环播放）或 Stop（停止）。

    参数：
        ip         板卡 IP
        run        True = Run，False = Stop。已经在播放时再 Run 不会报错（直接返回）
        port       UDP 端口，默认 9100
        timeout_s  每个请求的超时（秒）
        retries    超时重发次数

    返回：
        dict：running 是否在播放、channel_mask 输出通道掩码、status_raw STATUS 原始值
    """
    import collections
    import random
    import socket
    import struct
    import time

    BASE = 0x90200000
    REG_STATUS, REG_COMMAND, REG_TX_MASK = BASE + 0x04, BASE + 0x08, BASE + 0x10
    OP_READ, OP_WRITE = 1, 2
    STATUS_TEXT = {1: "AXI 错误（寄存器拒绝）", 2: "请求格式错误", 3: "AXI 超时", 4: "FPGA 忙"}

    # 操作队列：先读 STATUS 判断当前是否在播放（tag 'check'），需要时再发命令并轮询完成（tag 'poll'），
    # 最后读 STATUS 和 TX_MASK 作为返回值（tag 'final'、'mask'）
    ops = collections.deque([{"op": "read", "addr": REG_STATUS, "tag": "check"},
                             {"op": "read", "addr": REG_STATUS, "tag": "final"},
                             {"op": "read", "addr": REG_TX_MASK, "tag": "mask"}])
    value = 2 if run else 1
    out = {}

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((ip, int(port)))
    seq = random.getrandbits(32)
    try:
        while ops:
            op = ops.popleft()
            # ---- 组包、发送、等回复（超时重发同一序号）----
            seq = (seq + 1) & 0xFFFFFFFF
            if op["op"] == "write":
                opcode, count, payload = OP_WRITE, 1, struct.pack("<I", op["data"])
            else:
                opcode, count, payload = OP_READ, 1, b""
            request = struct.pack("<HBBIIHHHHI", 0xA7E1, 1, opcode, seq, op["addr"], count, 0, 0, 0, 0) + payload
            reply = None
            for _ in range(int(retries) + 1):
                sock.send(request)
                deadline = time.monotonic() + float(timeout_s)
                while reply is None:
                    remain = deadline - time.monotonic()
                    if remain <= 0:
                        break
                    sock.settimeout(remain)
                    try:
                        pkt = sock.recv(65535)
                    except socket.timeout:
                        break
                    except ConnectionResetError:
                        continue
                    if len(pkt) < 24:
                        continue
                    magic, _v, r_op, r_seq, _a, r_count, _f, r_status, r_err, _r = struct.unpack_from("<HBBIIHHHHI", pkt)
                    if magic == 0xA7E1 and r_op == (opcode | 0x80) and r_seq == seq:
                        reply = (r_status, pkt[24:24 + 4 * r_count])
                if reply is not None:
                    break
            if reply is None:
                raise TimeoutError("板卡 %s:%d 无回复；请检查光口连线、IP 和板卡是否已初始化" % (ip, port))
            if reply[0] != 0:
                raise RuntimeError("FPGA 返回错误 status=%d（%s），地址 0x%08X"
                                   % (reply[0], STATUS_TEXT.get(reply[0], "未知"), op["addr"]))
            # ---- 结果处理 ----
            tag = op.get("tag")
            if tag == "check":
                st = struct.unpack_from("<I", reply[1])[0]
                if not (run and (st & 1)):                # 已在播放且要 Run：什么都不用做
                    ops.appendleft({"op": "read", "addr": REG_STATUS, "tag": "poll",
                                    "deadline": time.monotonic() + 5.0})
                    ops.appendleft({"op": "write", "addr": REG_COMMAND, "data": value})
            elif tag == "poll":
                st = struct.unpack_from("<I", reply[1])[0]
                if (st >> 1) & 1:                         # busy：命令还在执行
                    if time.monotonic() > op["deadline"]:
                        raise TimeoutError("命令 %d 超时未完成（STATUS=0x%X）" % (value, st))
                    ops.appendleft(op)
                elif (st >> 4) & 3:
                    raise RuntimeError("命令 %d 被拒绝（STATUS=0x%X）；Run 被拒通常是还没下载波形或 PS 未就绪"
                                       % (value, st))
            elif tag == "final":
                st = struct.unpack_from("<I", reply[1])[0]
                out["running"] = bool(st & 1)
                out["status_raw"] = st
            elif tag == "mask":
                out["channel_mask"] = struct.unpack_from("<I", reply[1])[0] & 0xFF
    finally:
        sock.close()
    return out


def awg_status(ip, port=9100, timeout_s=0.2, retries=5):
    """
    读取板卡状态（只读，不改变任何设置）。

    参数：
        ip         板卡 IP
        port       UDP 端口，默认 9100
        timeout_s  每个请求的超时（秒）
        retries    超时重发次数

    返回：
        dict：
            id            0x41574732（"AWG2"）表示固件正确
            build_id      位元流版本（V1 = 0xD3C02026）
            abi           寄存器接口版本（V1 = 0x00030001）
            running       是否在播放
            busy          是否正在执行命令
            ps_ready      PS 是否已完成 RFDC 初始化（0 表示需要「下载 bit 并初始化」）
            fault         是否有故障；fault_channels 各通道故障位
            last_result   最近一次命令结果（0 OK、1 拒绝、2 故障）
            cap_busy / cap_done   采集状态
            length_samples        当前播放长度（点）
            channel_mask          输出通道掩码
            dac_fs_hz / adc_fs_hz 采样率
            cap_samples           最近一次采集的点数
    """
    import random
    import socket
    import struct
    import time

    BASE = 0x90200000
    # (名称, 地址) —— 逐个读取，避免读到有副作用的寄存器（例如 CAP_RD_DATA）
    regs = [("id", BASE + 0x00), ("status", BASE + 0x04), ("tx_length", BASE + 0x0C),
            ("tx_mask", BASE + 0x10), ("dac_fs_ksps", BASE + 0x14), ("adc_fs_ksps", BASE + 0x18),
            ("faults", BASE + 0x1C), ("abi", BASE + 0x20), ("cap_status", BASE + 0x28),
            ("cap_samples", BASE + 0x2C), ("build_id", BASE + 0x54)]
    raw = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((ip, int(port)))
    seq = random.getrandbits(32)
    try:
        for name, addr in regs:
            seq = (seq + 1) & 0xFFFFFFFF
            request = struct.pack("<HBBIIHHHHI", 0xA7E1, 1, 1, seq, addr, 1, 0, 0, 0, 0)    # READ 1 个字
            reply = None
            for _ in range(int(retries) + 1):
                sock.send(request)
                deadline = time.monotonic() + float(timeout_s)
                while reply is None:
                    remain = deadline - time.monotonic()
                    if remain <= 0:
                        break
                    sock.settimeout(remain)
                    try:
                        pkt = sock.recv(65535)
                    except socket.timeout:
                        break
                    except ConnectionResetError:
                        continue
                    if len(pkt) < 28:
                        continue
                    magic, _v, r_op, r_seq, _a, r_count, _f, r_status, _e, _r = struct.unpack_from("<HBBIIHHHHI", pkt)
                    if magic == 0xA7E1 and r_op == 0x81 and r_seq == seq:
                        reply = (r_status, struct.unpack_from("<I", pkt, 24)[0] if r_count else 0)
                if reply is not None:
                    break
            if reply is None:
                raise TimeoutError("板卡 %s:%d 无回复；请检查光口连线、IP 和板卡是否已初始化" % (ip, port))
            if reply[0] != 0:
                raise RuntimeError("读取 %s（0x%08X）失败，status=%d" % (name, addr, reply[0]))
            raw[name] = reply[1]
    finally:
        sock.close()

    st = raw["status"]
    return {"id": "0x%08X" % raw["id"], "build_id": "0x%08X" % raw["build_id"], "abi": "0x%08X" % raw["abi"],
            "running": bool(st & 1), "busy": bool(st & 2), "ps_ready": bool(st & 4), "fault": bool(st & 8),
            "last_result": (st >> 4) & 3, "cap_busy": bool(st & 0x40), "cap_done": bool(st & 0x80),
            "fault_channels": raw["faults"] & 0xFF, "length_samples": raw["tx_length"] * 32,
            "channel_mask": raw["tx_mask"] & 0xFF, "dac_fs_hz": raw["dac_fs_ksps"] * 1000.0,
            "adc_fs_hz": raw["adc_fs_ksps"] * 1000.0, "cap_samples": raw["cap_samples"],
            "status_raw": "0x%08X" % st}


def dso_capture(ip, channels=(0,), samples=65520, trigger="manual", port=9100,
                words_per_packet=2048, timeout_s=0.2, retries=5, capture_timeout_s=10.0):
    """
    触发一次 ADC 采集并读回数据（示波器单次采集）。

    参数：
        ip                板卡 IP
        channels          要读回的 ADC 通道（0..7），例如 (0,) 或 [0, 1, 2, 3]；8 个通道总是同时采集、时间对齐
        samples           每通道采集点数，24..65520 且为 24 的倍数
        trigger           'manual'：立即采集；'start'：AWG 起播同步（会先 Stop，再在 Start 的同一时刻开始采集，
                          采集完 AWG 保持播放）
        port              UDP 端口
        words_per_packet  每包字数，1..2048（没开巨型帧用 256）
        timeout_s         每个请求的超时（秒）
        retries           超时重试次数
        capture_timeout_s 等待采集完成的最长时间（秒）

    返回：
        (data, info)
        data  numpy int16 二维数组，形状 (len(channels), 点数)，第 i 行是 channels[i] 的波形；
              数值 = 14 bit ADC 码左移 2 位（满量程 32768）
        info  dict：fs_hz 采样率 5e9、channels、samples 实际点数、cap_tx_word 采集开始时 AWG 播放位置（32 点为单位）、
              seconds 总耗时、read_seconds 纯读回耗时
    """
    import collections
    import random
    import socket
    import struct
    import time
    import numpy as np

    t_start = time.perf_counter()
    chans = [int(c) for c in np.atleast_1d(channels)]
    if not chans or any(c < 0 or c > 7 for c in chans):
        raise ValueError("channels 必须是 0..7 的通道号列表")
    samples = int(samples)
    if samples < 24 or samples > 65520 or samples % 24:
        raise ValueError("samples 必须是 24..65520 且为 24 的倍数，收到 %d" % samples)
    if trigger not in ("manual", "start"):
        raise ValueError("trigger 必须是 'manual' 或 'start'")
    wpp = int(words_per_packet)
    if not 1 <= wpp <= 2048:
        raise ValueError("words_per_packet 必须是 1..2048")

    BASE = 0x90200000
    REG_STATUS, REG_COMMAND = BASE + 0x04, BASE + 0x08
    REG_CAP_STATUS = BASE + 0x28      # bit0 busy、bit1 done、bit2 armed（等待触发）
    REG_CAP_SAMPLES = BASE + 0x2C     # 实际采集点数
    REG_CAP_RD_CH = BASE + 0x40       # 选择读回通道（写入即把读指针归零）
    REG_CAP_RD_PTR = BASE + 0x44      # 读指针（样点对索引）
    REG_CAP_RD_DATA = BASE + 0x48     # 读数据端口（NOINC，每读一个字指针 +1）
    REG_CAP_CTRL = BASE + 0x4C        # bit0 触发方式、[27:16] 采集长度（24 点为单位）
    REG_CAP_TX_WORD = BASE + 0x50     # 采集开始时 AWG 的播放位置
    OP_READ, OP_WRITE, FLAG_NOINC = 1, 2, 1
    STATUS_TEXT = {1: "AXI 错误（寄存器拒绝）", 2: "请求格式错误", 3: "AXI 超时", 4: "FPGA 忙"}

    # ---------------- 操作队列 ----------------
    # 'cmd'   复合：写 COMMAND，再轮询 STATUS 直到完成
    # 'chunk' 复合：写读指针 + 读一段数据。读数据端口每读一次指针会前进，所以不能简单重发；
    #         超时时整个 chunk（先设指针再读）重新执行，保证数据位置正确
    # tag：'pre' 检查残留的 armed 状态；'run' 检查是否在播放；'poll' 命令完成；'cap' 等采集完成；
    #      'samples' 读到点数后生成读回操作；'txword' 记录播放位置；'data' 存数据
    ops = collections.deque()
    ops.append({"op": "read", "addr": REG_CAP_STATUS, "tag": "pre"})
    if trigger == "start":
        ops.append({"op": "read", "addr": REG_STATUS, "tag": "run"})
    ops.append({"op": "write", "addr": REG_CAP_CTRL, "data": [((samples // 24) << 16) | (1 if trigger == "start" else 0)]})
    ops.append({"op": "cmd", "value": 8})                                  # arm
    if trigger == "start":
        ops.append({"op": "cmd", "value": 2})                              # Start：起播即触发
    ops.append({"op": "read", "addr": REG_CAP_STATUS, "tag": "cap", "deadline": time.monotonic() + float(capture_timeout_s)})
    ops.append({"op": "read", "addr": REG_CAP_SAMPLES, "tag": "samples"})

    data = None
    captured = 0
    cap_tx_word = 0
    t_read0 = None

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    sock.connect((ip, int(port)))
    seq = random.getrandbits(32)
    try:
        while ops:
            op = ops.popleft()

            # ---- 复合操作展开 ----
            if op["op"] == "cmd":
                ops.appendleft({"op": "read", "addr": REG_STATUS, "tag": "poll", "value": op["value"],
                                "deadline": time.monotonic() + 5.0})
                ops.appendleft({"op": "write", "addr": REG_COMMAND, "data": [op["value"]]})
                continue
            if op["op"] == "chunk":
                ops.appendleft({"op": "read", "addr": REG_CAP_RD_DATA, "count": op["count"], "noinc": True,
                                "tag": "data", "row": op["row"], "offset": op["offset"], "chunk": op})
                ops.appendleft({"op": "write", "addr": REG_CAP_RD_PTR, "data": [op["offset"]]})
                continue

            # ---- 组包、发送、等回复 ----
            seq = (seq + 1) & 0xFFFFFFFF
            if op["op"] == "write":
                arr = np.asarray(op["data"], dtype="<u4")
                opcode, count, payload = OP_WRITE, int(arr.size), arr.tobytes()
            else:
                opcode, count, payload = OP_READ, int(op.get("count", 1)), b""
            flags = FLAG_NOINC if op.get("noinc") else 0
            request = struct.pack("<HBBIIHHHHI", 0xA7E1, 1, opcode, seq, op["addr"], count, flags, 0, 0, 0) + payload
            # 读数据端口（tag 'data'）只发一次：超时后改为整个 chunk 重做（见上）
            tries = 1 if op.get("tag") == "data" else int(retries) + 1
            reply = None
            for _ in range(tries):
                sock.send(request)
                deadline = time.monotonic() + float(timeout_s)
                while reply is None:
                    remain = deadline - time.monotonic()
                    if remain <= 0:
                        break
                    sock.settimeout(remain)
                    try:
                        pkt = sock.recv(65535)
                    except socket.timeout:
                        break
                    except ConnectionResetError:
                        continue
                    if len(pkt) < 24:
                        continue
                    magic, _v, r_op, r_seq, _a, r_count, _f, r_status, r_err, _r = struct.unpack_from("<HBBIIHHHHI", pkt)
                    if magic == 0xA7E1 and r_op == (opcode | 0x80) and r_seq == seq:
                        reply = (r_status, r_err, r_count, pkt[24:24 + 4 * r_count])
                if reply is not None:
                    break
            if reply is None:
                if op.get("tag") == "data":
                    redo = op["chunk"]
                    redo["redo"] = redo.get("redo", 0) + 1
                    if redo["redo"] > int(retries):
                        raise TimeoutError("读回通道 %d 数据多次超时" % chans[op["row"]])
                    ops.appendleft(redo)                   # 重新"设指针 + 读"
                    continue
                raise TimeoutError("板卡 %s:%d 无回复（地址 0x%08X）；请检查光口连线、IP 和板卡是否已初始化"
                                   % (ip, port, op["addr"]))
            r_status, r_err, r_count, r_data = reply
            if r_status != 0:
                raise RuntimeError("FPGA 返回错误 status=%d（%s），地址 0x%08X，字索引 %d"
                                   % (r_status, STATUS_TEXT.get(r_status, "未知"), op["addr"], r_err))

            # ---- 结果处理 ----
            tag = op.get("tag")
            # 寄存器读回值（写请求的回复只有字数没有数据，数据块另外处理）
            value = struct.unpack_from("<I", r_data)[0] if (op["op"] == "read" and tag != "data" and r_count) else 0
            if tag == "pre":
                if value & 5:                              # 上次采集残留在 busy/armed：先取消，否则 CAP_CTRL 会被拒绝
                    ops.appendleft({"op": "write", "addr": REG_COMMAND, "data": [32]})
            elif tag == "run":
                if value & 1:                              # 起播同步需要先停止播放
                    ops.appendleft({"op": "cmd", "value": 1})
            elif tag == "poll":
                if (value >> 1) & 1:
                    if time.monotonic() > op["deadline"]:
                        raise TimeoutError("命令 %d 超时未完成（STATUS=0x%X）" % (op["value"], value))
                    ops.appendleft(op)
                elif (value >> 4) & 3:
                    raise RuntimeError("命令 %d 被拒绝（STATUS=0x%X）" % (op["value"], value))
            elif tag == "cap":
                if not (value & 2 and not value & 1):      # 还没 done
                    if time.monotonic() > op["deadline"]:
                        # 残留的 armed 状态会在下一次 dso_capture 开头（tag 'pre'）自动取消
                        raise TimeoutError("采集超时（CAP_STATUS=0x%X）；起播同步时请确认已下载波形" % value)
                    ops.appendleft(op)
            elif tag == "samples":
                captured = value
                if captured < 24 or captured > 65520 or captured % 24:
                    raise RuntimeError("采集点数异常：%d" % captured)
                data = np.zeros((len(chans), captured), dtype=np.int16)
                pairs = captured // 2
                ops.append({"op": "read", "addr": REG_CAP_TX_WORD, "tag": "txword"})
                for row, ch in enumerate(chans):
                    ops.append({"op": "write", "addr": REG_CAP_RD_CH, "data": [ch]})
                    for off in range(0, pairs, wpp):
                        ops.append({"op": "chunk", "row": row, "offset": off, "count": min(wpp, pairs - off)})
                t_read0 = time.perf_counter()
            elif tag == "txword":
                cap_tx_word = value
            elif tag == "data":
                if r_count != op["count"]:
                    raise RuntimeError("读回字数不符：期望 %d，实际 %d" % (op["count"], r_count))
                # 每个 32 bit 字 = 2 个 int16 样点，低 16 位是较早的样点
                block = np.frombuffer(r_data, dtype="<u4").view("<i2")
                start = 2 * op["offset"]
                data[op["row"], start:start + block.size] = block
    finally:
        sock.close()

    t_end = time.perf_counter()
    return data, {"fs_hz": 5.0e9, "channels": chans, "samples": captured, "cap_tx_word": cap_tx_word,
                  "seconds": t_end - t_start, "read_seconds": (t_end - t_read0) if t_read0 else 0.0}


def dso_spectrum(x, fs_hz=5.0e9, window="blackmanharris", full_scale=32768.0):
    """
    计算单边幅度谱（dBFS）。满量程正弦的谱峰读数为 0 dBFS（已做窗函数相干增益校正）。

    参数：
        x           一维波形（dso_capture 返回的某一行，int16 或浮点）
        fs_hz       采样率，默认 5e9（ADC）
        window      窗函数：'blackmanharris'（默认，旁瓣低，适合看杂散）、'hann'、'flattop'（幅度最准）、'rect'（不加窗）
        full_scale  满量程对应的数值，int16 容器为 32768；浮点满量程单位的波形请传 1.0

    返回：
        (freq_hz, dbfs, rbw_hz)
        freq_hz  频率轴（Hz），长度 N//2+1
        dbfs     各频点幅度（dBFS）
        rbw_hz   分辨率带宽 = 等效噪声带宽 × Fs / N（Hz）
    """
    import numpy as np

    y = np.asarray(x, dtype=np.float64).ravel()
    n = y.size
    if n < 2:
        raise ValueError("波形至少要 2 点")

    # ---- 1. 窗函数（系数直接写在这里）----
    k = np.arange(n) / max(n - 1, 1)
    if window == "blackmanharris":
        w = 0.35875 - 0.48829 * np.cos(2 * np.pi * k) + 0.14128 * np.cos(4 * np.pi * k) - 0.01168 * np.cos(6 * np.pi * k)
    elif window == "hann":
        w = 0.5 - 0.5 * np.cos(2 * np.pi * k)
    elif window == "flattop":
        w = (0.21557895 - 0.41663158 * np.cos(2 * np.pi * k) + 0.277263158 * np.cos(4 * np.pi * k)
             - 0.083578947 * np.cos(6 * np.pi * k) + 0.006947368 * np.cos(8 * np.pi * k))
    elif window == "rect":
        w = np.ones(n)
    else:
        raise ValueError("window 必须是 blackmanharris/hann/flattop/rect")

    # ---- 2. 去直流、加窗、FFT；幅度 = |X| / (sum(w)/2) / 满量程（单边谱，正弦峰值读数正确）----
    spec = np.fft.rfft((y - y.mean()) * w)
    mag = np.abs(spec) / (np.sum(w) / 2.0) / float(full_scale)
    dbfs = 20.0 * np.log10(np.maximum(mag, 1e-12))

    # ---- 3. 频率轴与 RBW ----
    freq_hz = np.arange(spec.size) * float(fs_hz) / n
    enbw = n * np.sum(w ** 2) / np.sum(w) ** 2          # 等效噪声带宽（单位：bin）
    rbw_hz = enbw * float(fs_hz) / n
    return freq_hz, dbfs, rbw_hz


def dso_measure(x, fs_hz=5.0e9, window="blackmanharris", full_scale=32768.0, harmonics=5):
    """
    单音测量（类似示波器/频谱仪的自动测量）。适合输入是单个正弦（加噪声和杂散）的情况。

    参数：
        x           一维波形（dso_capture 返回的某一行）
        fs_hz       采样率，默认 5e9
        window      窗函数：'blackmanharris'（默认）、'hann'、'flattop'、'rect'
        full_scale  满量程对应的数值，int16 容器为 32768
        harmonics   计算 SNR 时扣除的谐波阶数上限（2..harmonics 次，含混叠位置）

    返回：
        dict：
            freq_hz     基波频率（Hz，抛物线插值，优于 1 个 bin）
            peak_dbfs   基波峰值幅度（dBFS，由主瓣能量计算，不受栅栏效应影响）
            amp_lsb     基波峰值幅度（int16 数值）
            vpp_lsb     时域峰峰值（int16 数值）
            rms_lsb     时域 RMS（去直流）
            mean_lsb    直流平均
            sfdr_dbc    无杂散动态范围（基波与最大杂散之比）
            sinad_db    信号与噪声+失真之比
            snr_db      信噪比（扣除 2..harmonics 次谐波）
            enob_bits   有效位数 =(SINAD-1.76)/6.02
    """
    import numpy as np

    y = np.asarray(x, dtype=np.float64).ravel()
    n = y.size
    out = {"vpp_lsb": float(y.max() - y.min()) if n else 0.0,
           "rms_lsb": float(np.sqrt(np.mean((y - y.mean()) ** 2))) if n else 0.0,
           "mean_lsb": float(y.mean()) if n else 0.0}
    if n < 64:
        return out                                       # 点数太少，只给时域结果

    # ---- 1. 窗函数与主瓣半宽（bin）----
    k = np.arange(n) / max(n - 1, 1)
    if window == "blackmanharris":
        w = 0.35875 - 0.48829 * np.cos(2 * np.pi * k) + 0.14128 * np.cos(4 * np.pi * k) - 0.01168 * np.cos(6 * np.pi * k)
        half = 5
    elif window == "hann":
        w = 0.5 - 0.5 * np.cos(2 * np.pi * k)
        half = 3
    elif window == "flattop":
        w = (0.21557895 - 0.41663158 * np.cos(2 * np.pi * k) + 0.277263158 * np.cos(4 * np.pi * k)
             - 0.083578947 * np.cos(6 * np.pi * k) + 0.006947368 * np.cos(8 * np.pi * k))
        half = 6
    elif window == "rect":
        w = np.ones(n)
        half = 1
    else:
        raise ValueError("window 必须是 blackmanharris/hann/flattop/rect")

    # ---- 2. 功率谱；DC 附近清零 ----
    power = np.abs(np.fft.rfft((y - y.mean()) * w)) ** 2
    power[: half + 1] = 0.0
    kmax = int(np.argmax(power))
    if power[kmax] <= 0:
        return out

    # ---- 3. 频率：对数幅度三点抛物线插值 ----
    delta = 0.0
    if 0 < kmax < power.size - 1 and power[kmax - 1] > 0 and power[kmax + 1] > 0:
        a, b, c = np.log(power[kmax - 1]), np.log(power[kmax]), np.log(power[kmax + 1])
        if (a - 2 * b + c) != 0:
            delta = 0.5 * (a - c) / (a - 2 * b + c)
    out["freq_hz"] = float((kmax + delta) * float(fs_hz) / n)

    # ---- 4. 基波能量（主瓣 ±half bin）、其余 = 噪声 + 失真 ----
    lo, hi = max(kmax - half, 0), min(kmax + half + 1, power.size)
    sig = float(power[lo:hi].sum())
    rest = power.copy()
    rest[lo:hi] = 0.0
    total_nd = float(rest.sum())

    # ---- 5. 谐波能量（2..harmonics 次，考虑混叠到第一奈奎斯特区）----
    harm = 0.0
    for h in range(2, int(harmonics) + 1):
        bin_h = int(round(kmax * h)) % n
        if bin_h > n // 2:
            bin_h = n - bin_h
        hl, hh = max(bin_h - half, 0), min(bin_h + half + 1, power.size)
        harm += float(rest[hl:hh].sum())
    noise = max(total_nd - harm, 1e-30)

    # ---- 6. 幅度（Parseval：主瓣能量 = N·A²/4·sum(w²)）与各项指标 ----
    amp = np.sqrt(4.0 * sig / (n * np.sum(w ** 2)))
    out["amp_lsb"] = float(amp)
    out["peak_dbfs"] = float(20 * np.log10(max(amp / float(full_scale), 1e-12)))
    out["sinad_db"] = float(10 * np.log10(sig / max(total_nd, 1e-30)))
    out["snr_db"] = float(10 * np.log10(sig / noise))
    out["sfdr_dbc"] = float(10 * np.log10(power[kmax] / max(float(rest.max()), 1e-30)))
    out["enob_bits"] = float((out["sinad_db"] - 1.76) / 6.02)
    return out
