"""Device worker: owns the UDP client in its own QThread so the GUI never blocks on the network.

All requests are queued slots executed in order. Heavy numpy work (unpack, FFT, measurements) also
runs here; the GUI thread only draws. Continuous capture re-schedules itself through the event loop,
so stop/cancel requests are handled between captures.
"""
from __future__ import annotations

import sys
import threading
import time
import traceback

import numpy as np
from PySide6.QtCore import QObject, QTimer, Signal, Slot

from awg_eth.awg import Awg, REG_BUILD_ID, REG_FAULTS
from awg_eth.client import AwgEthClient
from awg_eth.device import open_device
from awg_eth.remote import RemoteAwg

from . import measure, waveforms as wf


class DeviceWorker(QObject):
    connected = Signal(dict)
    disconnected = Signal()
    closed = Signal()
    status = Signal(dict)
    progress = Signal(str, int, int)          # text, done, total
    downloaded = Signal(dict)
    captured = Signal(dict)
    failed = Signal(str, str)                  # operation, message
    log = Signal(str)
    busy = Signal(bool)

    def __init__(self):
        super().__init__()
        # The data port waits for one UDP reply per packet and must re-take the GIL after each recv.
        # While the GUI thread draws (pure Python/numpy), the default 5 ms switch interval makes every
        # packet wait up to 5 ms: measured on the board, a 1-channel readback went from 6 ms to 400 ms.
        # 0.1 ms keeps the worker at full speed with the GUI thread 100 % busy.
        sys.setswitchinterval(1e-4)
        self.client: AwgEthClient | None = None
        self.awg: Awg | None = None
        self.cancel = threading.Event()
        self._continuous = False
        self._capture_args: dict = {}
        # Continuous capture keeps one frame in flight: the next capture starts when the GUI reports the
        # previous frame drawn (frame_shown), or after FRAME_ACK_TIMEOUT_MS if it never does (minimized).
        # Without this the worker produced frames far faster than they were drawn (1615 dropped in one
        # run) and the wasted FFTs competed with the drawing for the GIL.
        self._awaiting_frame = False
        self._ack_timer: QTimer | None = None
        self._poll: QTimer | None = None
        self._last_progress = 0.0

    # ---- helpers -------------------------------------------------------------------------
    def _progress_cb(self, phase, channel, done, total):
        now = time.monotonic()
        if done >= total or now - self._last_progress > 0.05:     # at most ~20 GUI updates/s
            self._last_progress = now
            label = {"write": "下载", "verify": "校验", "capture": "读取"}.get(phase, phase)
            self.progress.emit(f"{label} {channel}", int(done), int(total))

    def _guard(self, op, fn):
        if self.awg is None and op != "连接":
            self.failed.emit(op, "未连接")
            return None
        self.busy.emit(True)
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 — report every failure to the GUI
            self._release_remote()
            self.failed.emit(op, f"{type(exc).__name__}: {exc}")
            self.log.emit(traceback.format_exc(limit=3))
            return None
        finally:
            self.busy.emit(False)

    def _read_status(self) -> dict:
        st = self.awg.status()
        st["faults"] = st.get("fault_channels", 0)
        return st

    @Slot()
    def _release_remote(self):
        if isinstance(self.awg, RemoteAwg):
            self.awg.release()

    @Slot(str, int)
    def connect_remote(self, host: str, port: int):
        def run():
            self.close_device()
            self.awg = RemoteAwg(host, port, self._progress_cb)
            info = dict(self.awg.info)
            info.update(ip=host, port=port, remote=True)
            self.connected.emit(info)
            # Remote status is fetched on request; offline analysis never holds a lease.
            return info
        if self._guard("连接", run) is None:
            self.close_device()

    # ---- slots ---------------------------------------------------------------------------
    FRAME_ACK_TIMEOUT_MS = 1000

    @Slot()
    def setup(self):
        from .perf import thread_high_qos
        self.high_qos = thread_high_qos()      # runs in the worker thread: P-core, above-normal priority
        self._ack_timer = QTimer(self)
        self._ack_timer.setSingleShot(True)
        self._ack_timer.setInterval(self.FRAME_ACK_TIMEOUT_MS)
        self._ack_timer.timeout.connect(self.frame_shown)
        self._poll = QTimer(self)
        self._poll.setInterval(1000)
        self._poll.timeout.connect(self.poll_status)

    def _open(self, ip: str, port: int, words_per_packet: int) -> dict:
        self.close_device()
        self.client, self.awg, info = open_device(ip, port, words_per_packet, self._progress_cb)
        st = self._read_status()
        st["max_capture_samples_1"] = self.awg.max_capture_samples(1)
        st["max_capture_samples_8"] = self.awg.max_capture_samples(8)
        info.update({"ip": ip, "port": port, "build_id_reg": self.client.read32(REG_BUILD_ID), "status": st})
        return info

    @Slot(str, int, int)
    def connect_device(self, ip: str, port: int, words_per_packet: int):
        def run():
            info = self._open(ip, port, words_per_packet)
            self.connected.emit(info)
            self._poll.start()
            return info
        if self._guard("连接", run) is None:
            self.close_device()

    @Slot(str, int, int, float)
    def connect_when_ready(self, ip: str, port: int, words_per_packet: int, timeout_s: float):
        """After program.tcl: wait until the 40GbE link answers and STATUS.ps_ready=1, then connect."""
        def run():
            self.cancel.clear()
            t0 = time.monotonic()
            last_note = 0.0
            last_err = "无响应"
            while True:
                if self.cancel.is_set():
                    raise RuntimeError("已取消等待")
                try:
                    info = self._open(ip, port, words_per_packet)
                    if info["status"].get("ps_ready"):
                        self.connected.emit(info)
                        self._poll.start()
                        self.log.emit(f"板卡就绪（等待 {time.monotonic() - t0:.0f} s）")
                        return info
                    last_err = "光口已通，PS 仍在初始化 RFDC"
                except Exception as exc:  # noqa: BLE001 — link not up yet
                    last_err = f"{type(exc).__name__}: {exc}"
                self._close(emit=False)
                elapsed = time.monotonic() - t0
                if elapsed > timeout_s:
                    raise TimeoutError(f"{timeout_s:.0f} s 内板卡未就绪（最后状态：{last_err}）")
                if elapsed - last_note >= 5:
                    last_note = elapsed
                    self.log.emit(f"等待板卡就绪… {elapsed:.0f} s（{last_err}）")
                time.sleep(0.5)
        if self._guard("连接", run) is None:
            self.close_device()

    @Slot()
    def close_device(self):
        try:
            self._close(emit=True)
        finally:
            self.closed.emit()

    def _close(self, emit: bool):
        self._continuous = False
        if self._poll:
            self._poll.stop()
        was = self.awg is not None or self.client is not None
        if self.awg:
            self.awg.close()
        if self.client:
            try:
                self.client.close()
            except OSError:
                pass
        self.client = None
        self.awg = None
        if was and emit:
            self.disconnected.emit()

    @Slot()
    def poll_status(self):
        if self.awg is None or self._continuous:
            return
        try:
            self.status.emit(self._read_status())
        except Exception as exc:  # noqa: BLE001
            self.log.emit(f"状态轮询失败：{exc}")

    @Slot()
    def refresh_status(self):
        """One status read on request (刷新状态), also while continuous capture runs."""
        self._guard("刷新状态", lambda: self.status.emit(self._read_status()) or True)

    @Slot()
    def clear_fault(self):
        """COMMAND=4 (clear TX faults); the FPGA rejects it while the output is running."""
        def run():
            if self.awg.status().get("running"):
                raise RuntimeError("输出正在播放，先「停止播放」再清除故障")
            self.awg.clear()
            st = self._read_status()
            self.status.emit(st)
            return st
        try:
            self._guard("清除故障", run)
        finally:
            self._release_remote()

    @Slot(object, int, bool)
    def download(self, channels: dict, mask: int, verify: bool):
        """channels: {ch: int16 ndarray}. All must share one length."""
        def run():
            self.cancel.clear()
            lengths = {len(v) for v in channels.values()}
            if len(lengths) != 1:
                raise ValueError("所有启用通道的波形长度必须相同")
            samples = lengths.pop()
            words = {ch: wf.pack_words(v) for ch, v in channels.items()}
            if self.awg.status().get("running"):
                raise RuntimeError("DAC 正在播放，请先手动停止播放，再下载新波形")
            t0 = time.perf_counter()
            st = self.awg.load_words(words, samples, mask, verify=verify, cancel=self.cancel.is_set)
            dt = time.perf_counter() - t0
            nbytes = samples * 2 * len(words)
            wr = max(getattr(self.awg, "last_write_seconds", dt), 1e-9)
            result = {"seconds": dt, "bytes": nbytes, "mb_s": nbytes / dt / 1e6,
                      "write_s": wr, "data_mb_s": nbytes / wr / 1e6, "channels": sorted(words),
                      "samples": samples, "verified": verify, "status": st}
            self.downloaded.emit(result)
            self.status.emit(st)
            return result
        self._guard("下载", run)

    @Slot(bool)
    def set_output(self, run: bool):
        def go():
            if run and self.awg.status()["running"]:
                st = self.awg.status()                    # already playing: Run is a no-op, not an error
            else:
                st = self.awg.start() if run else self.awg.stop()
            self.status.emit(st)
            return st
        try:
            self._guard("启动输出" if run else "停止输出", go)
        finally:
            self._release_remote()

    @Slot(dict)
    def capture_once(self, args: dict):
        self._continuous = False
        self._capture_args = dict(args)
        self._do_capture()

    @Slot(dict)
    def capture_start(self, args: dict):
        self._capture_args = dict(args)
        self._continuous = True
        self._do_capture()

    @Slot()
    def capture_stop(self):
        self._continuous = False
        self._awaiting_frame = False
        if self._ack_timer is not None:
            self._ack_timer.stop()
        self._release_remote()

    @Slot(str, str)
    def load_capture(self, path, window):
        from .capture_io import load_capture
        try:
            if self._continuous:
                raise RuntimeError("请先停止连续采集，再打开记录")
            self.captured.emit(load_capture(path, window))
        except Exception as exc:
            self.failed.emit("打开采集记录", str(exc))

    @Slot(dict)
    def update_capture_args(self, args: dict):
        self._capture_args.update(args)

    def _do_capture(self):
        args = self._capture_args

        def run():
            self.cancel.clear()
            t0 = time.perf_counter()
            captured, cap_tx_word, raw = self.awg.capture_raw(
                args.get("trigger", "manual"), args.get("mask", 0x01),
                samples=args.get("samples", 65520), slots=args.get("slots"), cancel=self.cancel.is_set)
            if captured != args.get("samples", 65520):
                raise RuntimeError("采集点数与请求不一致")
            t_capture = time.perf_counter() - t0                      # arm + trigger + wait + readback
            t_read = getattr(self.awg, "last_read_seconds", t_capture)  # data readback only
            if not self._continuous:
                self._release_remote()  # analysis never needs the board
            t1 = time.perf_counter()
            c1 = time.thread_time()
            data = {ch: wf.unpack_pairs(pairs)[:captured] for ch, pairs in raw.items()}
            win = args.get("window", "blackmanharris")
            spectra, meas = {}, {}
            analysis_limit = 262_144
            for ch, y in data.items():
                f, db, rbw, meas[ch] = measure.analyze(y[:analysis_limit], measure.ADC_FS_HZ, win)  # one FFT
                spectra[ch] = (f, db)
            timing = getattr(self.awg, "last_capture_timing", {}) or {}
            t_done = time.perf_counter()
            process_cpu_s = time.thread_time() - c1        # CPU time of this thread (wall >> CPU: waiting)
            self.captured.emit({"samples": data, "spectra": spectra, "meas": meas, "rbw_hz": rbw,
                                "cap_tx_word": cap_tx_word, "count": captured, "trigger": args.get("trigger"),
                                "read_s": t_read, "capture_s": t_capture, "total_s": t_done - t0,
                                "control_s": timing.get("control_s"), "process_s": t_done - t1,
                                "process_cpu_s": process_cpu_s,
                                "emit_t": t_done,
                                "window": win, "analysis_points": min(captured, analysis_limit),
                                "analysis_limited": captured > analysis_limit})
            return True
        ok = self._guard("采集", run)
        if self._continuous and ok:
            self._awaiting_frame = True                  # next capture once the GUI has drawn this one
            if self._ack_timer is not None:
                self._ack_timer.start()
            else:
                QTimer.singleShot(0, self._do_capture)
        elif self._continuous:
            self._continuous = False
            self._release_remote()
        else:
            self._release_remote()

    @Slot()
    def frame_shown(self):
        """The GUI drew the last frame (or the ack timed out): start the next continuous capture."""
        if self._ack_timer is not None:
            self._ack_timer.stop()
        if not self._awaiting_frame:
            return
        self._awaiting_frame = False
        if self._continuous:
            self._do_capture()

    @Slot()
    def abort_capture(self):
        self._guard("取消采集", lambda: self.awg.abort_capture())
