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

from . import measure, waveforms as wf


class DeviceWorker(QObject):
    connected = Signal(dict)
    disconnected = Signal()
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
            self.failed.emit(op, f"{type(exc).__name__}: {exc}")
            self.log.emit(traceback.format_exc(limit=3))
            return None
        finally:
            self.busy.emit(False)

    def _read_status(self) -> dict:
        st = self.awg.status()
        st["faults"] = self.client.read32(REG_FAULTS)
        return st

    # ---- slots ---------------------------------------------------------------------------
    @Slot()
    def setup(self):
        self._poll = QTimer(self)
        self._poll.setInterval(1000)
        self._poll.timeout.connect(self.poll_status)

    def _open(self, ip: str, port: int, words_per_packet: int) -> dict:
        self.close_device()
        self.client = AwgEthClient(ip, port=port, words_per_packet=words_per_packet,
                                   window=8, timeout=0.2, retries=5)
        self.client.ping()
        info = self.client.info()
        self.awg = Awg(self.client, progress_callback=self._progress_cb)
        st = self._read_status()
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
        self._close(emit=True)

    def _close(self, emit: bool):
        self._continuous = False
        if self._poll:
            self._poll.stop()
        if self.client:
            try:
                self.client.close()
            except OSError:
                pass
        was = self.client is not None
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
        self._guard("启动输出" if run else "停止输出", go)

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
                samples=args.get("samples", 65520), cancel=self.cancel.is_set)
            t_capture = time.perf_counter() - t0                      # arm + trigger + wait + readback
            t_read = getattr(self.awg, "last_read_seconds", t_capture)  # data readback only
            data = {ch: wf.unpack_pairs(pairs)[:captured] for ch, pairs in raw.items()}
            win = args.get("window", "blackmanharris")
            spectra, meas = {}, {}
            for ch, y in data.items():
                f, db, rbw = measure.spectrum(y, measure.ADC_FS_HZ, win)
                spectra[ch] = (f, db.astype(np.float32))
                meas[ch] = measure.measure(y, measure.ADC_FS_HZ, win)
            self.captured.emit({"samples": data, "spectra": spectra, "meas": meas, "rbw_hz": rbw,
                                "cap_tx_word": cap_tx_word, "count": captured, "trigger": args.get("trigger"),
                                "read_s": t_read, "capture_s": t_capture, "total_s": time.perf_counter() - t0, "window": win})
            return True
        ok = self._guard("采集", run)
        if self._continuous and ok:
            QTimer.singleShot(0, self._do_capture)        # yield to the event loop between captures
        elif self._continuous:
            self._continuous = False

    @Slot()
    def abort_capture(self):
        self._guard("取消采集", lambda: self.awg.abort_capture())
