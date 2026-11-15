"""Main window: instrument-style AWG (left) + oscilloscope / spectrum analyzer (right)."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

import numpy as np
import pyqtgraph as pg
from PySide6.QtCore import QSettings, Qt, QThread, QTimer, Signal
from PySide6.QtGui import QAction, QColor, QFont
from PySide6.QtWidgets import (
    QAbstractItemView, QCheckBox, QComboBox, QDockWidget, QDoubleSpinBox, QFileDialog, QFormLayout,
    QFrame, QGridLayout, QGroupBox, QHBoxLayout, QHeaderView, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QMainWindow, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QSpinBox,
    QScrollArea, QSizePolicy, QSlider, QSplitter, QTableWidget, QTableWidgetItem, QTabWidget, QVBoxLayout, QWidget,
)

from . import importers, measure, style as sty, waveforms as wf
from .programmer import BoardProgrammer, default_package, find_xsct, missing_package_files
from .worker import DeviceWorker
from awg_eth.awg import CAPTURE_MARGIN_SAMPLES as CAPTURE_MARGIN, capture_samples_for_tx

APP_VERSION = "V2.1"            # V2 release line (bitstream V2.1, ABI 0x00050000), branch eth40g
READY_TIMEOUT_S = 120.0          # program.tcl returns before RFDC/MTS init finishes on the PS

CH_COLORS = ["#0E7C8C", "#D85A30", "#1D9E75", "#BA7517", "#7F77DD", "#D4537E", "#639922", "#888780"]
ADC_FS = measure.ADC_FS_HZ
CAP_MAX = 65520
CAP_ANALYSIS_MAX = 262_144
TX_WINDOWS = (("1024 点", 1024), ("4096 点", 4096), ("16384 点", 16384), ("65536 点", 65536), ("全长", 0))
FACTS_MIN_INTERVAL_S = 0.5      # continuous capture: refresh the summary text at most twice a second

pg.setConfigOptions(antialias=False, background="w", foreground="#444441")


def _mhz_spin(value, lo=0.001, hi=4899.0, decimals=6, step=1.0):
    s = QDoubleSpinBox()
    s.setRange(lo, hi)
    s.setDecimals(decimals)
    s.setSingleStep(step)
    s.setValue(value)
    s.setSuffix(" MHz")
    s.setKeyboardTracking(False)
    return s


def _fmt_dur(seconds: float) -> str:
    seconds = max(0.0, seconds)
    if seconds < 60:
        return f"{seconds:.0f} 秒" if seconds >= 10 else f"{seconds:.1f} 秒"
    return f"{int(seconds // 60)} 分 {int(seconds % 60):02d} 秒"


def _box_axes(plot: pg.PlotWidget):
    """MATLAB-like boxed axes: show top/right axes without tick labels."""
    item = plot.getPlotItem()
    for side in ("top", "right"):
        item.showAxis(side)
        item.getAxis(side).setStyle(showValues=False)
    for side in ("left", "bottom", "top", "right"):
        axis = item.getAxis(side)
        axis.enableAutoSIPrefix(False)           # units are fixed (µs / MHz) and written in the label
        axis.setPen(pg.mkPen("#7D8C96"))
        axis.setTextPen(pg.mkPen(sty.INK))


def _fmt_hz(hz: float) -> str:
    for unit, scale in (("GHz", 1e9), ("MHz", 1e6), ("kHz", 1e3)):
        if abs(hz) >= scale:
            return f"{hz / scale:.6f} {unit}"
    return f"{hz:.3f} Hz"


class MainWindow(QMainWindow):
    req_connect = Signal(str, int, int)
    req_remote = Signal(str, int)
    req_connect_ready = Signal(str, int, int, float)
    req_close = Signal()
    req_release = Signal()
    req_load_capture = Signal(str, str)
    req_download = Signal(object, int, bool)
    req_output = Signal(bool)
    req_cap_once = Signal(dict)
    req_cap_start = Signal(dict)
    req_cap_stop = Signal()
    req_cap_args = Signal(dict)
    req_abort = Signal()
    req_refresh = Signal()
    req_clear_fault = Signal()
    frame_shown = Signal()

    def __init__(self, default_ip: str = "192.168.42.2", default_port: int = 9100):
        super().__init__()
        self.setWindowTitle(f"47DR AWG / 示波器 — 40GbE 光口  {APP_VERSION}")
        self.settings = QSettings(str(Path(os.environ.get("AWG_APP_DATA", Path(__file__).resolve().parents[2] / "app_data")) / "settings.ini"),
                                  QSettings.IniFormat)
        self.waves: dict[int, dict] = {}          # ch -> {"y": float array, "desc": str}
        self.enabled = [False] * 8
        self.tx_limit = wf.TX_MAX_SAMPLES
        self.last_capture: dict | None = None
        self.connected = False
        self.running = False
        self._busy = False
        self.device_status: dict = {}
        self.capture_limit = CAP_MAX
        self._downloaded_once = False
        self._capture_after_download = False
        self.setStyleSheet(sty.QSS)

        self._build_worker()
        self._build_ui(default_ip, default_port)
        self._restore()
        self._update_kind_rows()
        self._update_actual_freq()

    # ================================================================== worker
    def _build_worker(self):
        self.thread = QThread(self)
        self.worker = DeviceWorker()
        self.worker.moveToThread(self.thread)
        self.thread.started.connect(self.worker.setup)
        self.req_connect.connect(self.worker.connect_device)
        self.req_remote.connect(self.worker.connect_remote)
        self.req_connect_ready.connect(self.worker.connect_when_ready)
        self.req_close.connect(self.worker.close_device)
        self.req_release.connect(self.worker._release_remote)
        self.req_load_capture.connect(self.worker.load_capture)
        self.req_download.connect(self.worker.download)
        self.req_output.connect(self.worker.set_output)
        self.req_cap_once.connect(self.worker.capture_once)
        self.req_cap_start.connect(self.worker.capture_start)
        self.req_cap_stop.connect(self.worker.capture_stop)
        self.req_cap_args.connect(self.worker.update_capture_args)
        self.req_abort.connect(self.worker.abort_capture)
        self.frame_shown.connect(self.worker.frame_shown)
        self.req_refresh.connect(self.worker.refresh_status)
        self.req_clear_fault.connect(self.worker.clear_fault)
        self.worker.connected.connect(self._on_connected)
        self.worker.disconnected.connect(self._on_disconnected)
        self.worker.closed.connect(self._worker_closed)
        self.thread.finished.connect(self._finish_close)
        self.worker.status.connect(self._on_status)
        self.worker.progress.connect(self._on_progress)
        self.worker.downloaded.connect(self._on_downloaded)
        self.worker.captured.connect(self._on_captured)
        self.worker.failed.connect(self._on_failed)
        self.worker.log.connect(self._log)
        self.worker.busy.connect(self._on_busy)
        self.thread.start()

    # ================================================================== UI
    # Layout after the rf_awg_scope_v1 MATLAB app: header with status lights, numbered workflow steps,
    # progress row, left tabs (收发操作 / 发射参数 / 连接设置), plots on the right, dark log panel.
    # Every control of the previous layout is kept (only moved).
    def _build_ui(self, ip, port):
        central = QWidget()
        central.setObjectName("root")
        root = QVBoxLayout(central)
        root.setContentsMargins(12, 8, 12, 4)
        root.setSpacing(8)
        self._build_connection_fields(ip, port)
        root.addWidget(self._build_header())
        root.addWidget(self._build_steps_row())
        root.addWidget(self._build_progress_row())

        body = QSplitter(Qt.Horizontal)
        body.addWidget(self._build_left_tabs())
        body.addWidget(self._build_scope_panel())
        body.setStretchFactor(0, 0)
        body.setStretchFactor(1, 1)
        body.setSizes([400, 1100])

        self.log_view = QPlainTextEdit(readOnly=True)
        self.log_view.setObjectName("log")
        self.log_view.setMaximumBlockCount(2000)
        vsplit = QSplitter(Qt.Vertical)
        vsplit.addWidget(body)
        vsplit.addWidget(self.log_view)
        vsplit.setStretchFactor(0, 1)
        vsplit.setStretchFactor(1, 0)
        vsplit.setSizes([760, 120])
        self.log_split = vsplit
        root.addWidget(vsplit, 1)
        self.setCentralWidget(central)

        self._build_device_menu()
        view_menu = self.menuBar().addMenu("视图")
        self.act_log = QAction("显示日志", self, checkable=True, checked=True)
        self.act_log.toggled.connect(self.log_view.setVisible)
        view_menu.addAction(self.act_log)
        act = QAction("清空日志", self)
        act.triggered.connect(self.log_view.clear)
        view_menu.addAction(act)

        self.info_label = QLabel("DAC 9.8 GS/s · ADC 5 GS/s raw · 40GbE 光口 · C 数据通路")
        self.statusBar().addPermanentWidget(self.info_label)
        self.statusBar().showMessage("未连接。请先「① 初始化板卡」（或已初始化时直接「② 连接板卡」）。")
        self._update_steps()

    def _show_log(self):
        self.act_log.setChecked(True)

    def _build_connection_fields(self, ip, port):
        """Connection widgets live in the 连接设置 tab; built first because other rows refer to them."""
        self.ip_edit = QLineEdit(ip)
        self.port_spin = QSpinBox()
        self.port_spin.setRange(1, 65535)
        self.port_spin.setValue(port)
        self.wpp_combo = QComboBox()
        self.wpp_combo.addItems(["2048", "1024", "350", "256"])
        self.wpp_combo.setToolTip("V2.1 批量数据端口需 PC 光口网卡 MTU 9000")
        self.connect_btn = QPushButton("连接板卡")
        self.connect_btn.clicked.connect(self._toggle_connect)

    def _build_header(self):
        bar = sty.card()
        h = QHBoxLayout(bar)
        h.setContentsMargins(14, 8, 14, 8)
        h.setSpacing(14)
        h.addWidget(sty.label("47DR  /  AWG + SCOPE", "title"))
        h.addWidget(sty.label(APP_VERSION, "section"))
        self.hdr_info = sty.label("40GbE 光口 · 未连接", "muted")
        h.addWidget(self.hdr_info)
        h.addStretch(1)
        self.conn_label = QLabel("● 未连接")
        self.conn_label.setStyleSheet("color:#888780")
        font = self.conn_label.font()
        font.setBold(True)
        self.conn_label.setFont(font)
        h.addWidget(self.conn_label)
        self.led_link = sty.Led("光口")
        self.led_ready = sty.Led("RF 就绪")
        self.led_play = sty.Led("播放")
        self.led_fault = sty.Led("故障")
        for led in (self.led_link, self.led_ready, self.led_play, self.led_fault):
            h.addWidget(led)
        self.refresh_btn = QPushButton("刷新状态")
        self.refresh_btn.clicked.connect(self._refresh_status)
        self.clear_fault_btn = QPushButton("清除故障")
        self.clear_fault_btn.setToolTip("COMMAND=4：清除 TX 故障标志（输出停止时有效）")
        self.clear_fault_btn.clicked.connect(self._clear_fault)
        h.addWidget(self.refresh_btn)
        h.addWidget(self.clear_fault_btn)
        return bar

    def _build_steps_row(self):
        row = QWidget()
        h = QHBoxLayout(row)
        h.setContentsMargins(0, 0, 0, 0)
        self.steps = sty.StepBar()
        self.steps.clicked.connect(self._on_step_clicked)
        h.addWidget(self.steps)
        h.addStretch(1)
        self.state_label = sty.label("", "muted")
        h.addWidget(self.state_label)
        h.addWidget(self.connect_btn)
        settings_btn = QPushButton("连接设置")
        settings_btn.clicked.connect(lambda: self.left_tabs.setCurrentIndex(2))
        h.addWidget(settings_btn)
        return row

    def _build_progress_row(self):
        bar = sty.card()
        h = QHBoxLayout(bar)
        h.setContentsMargins(12, 6, 12, 6)
        h.setSpacing(12)
        self.progress = QProgressBar()
        self.progress.setFixedWidth(170)
        self.progress.setTextVisible(False)
        self.progress.setRange(0, 1)
        self.progress.setValue(0)
        h.addWidget(self.progress)
        self.progress_text = QLabel("就绪")
        h.addWidget(self.progress_text, 1)
        self.progress_pct = sty.label("", "facts")
        self.progress_elapsed = sty.label("", "muted")
        self.progress_remain = sty.label("", "muted")
        for w in (self.progress_pct, self.progress_elapsed, self.progress_remain):
            h.addWidget(w)
        self._prog_task = None
        self._prog_t0 = 0.0
        self._prog_timer = QTimer(self)
        self._prog_timer.setInterval(500)
        self._prog_timer.timeout.connect(self._tick_progress)
        return bar

    # ------------------------------------------------------------------ left: tabs
    def _build_left_tabs(self):
        self.left_tabs = QTabWidget()
        self.left_tabs.addTab(self._scroll(self._build_ops_tab()), "收发操作")
        self.left_tabs.addTab(self._scroll(self._build_params_tab()), "发射参数")
        self.left_tabs.addTab(self._scroll(self._build_settings_tab()), "连接设置")
        self.left_tabs.setMinimumWidth(360)
        return self.left_tabs

    @staticmethod
    def _scroll(widget):
        area = QScrollArea()
        area.setWidgetResizable(True)
        area.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        area.setWidget(widget)
        return area

    @staticmethod
    def _section(v, text, right=None):
        row = QHBoxLayout()
        row.addWidget(sty.label(text, "section"))
        row.addStretch(1)
        if right is not None:
            row.addWidget(right)
        v.addLayout(row)

    def _build_ops_tab(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(8)

        # ③ choose waveform
        self._section(v, "③ 选波形（DAC 9.8 GS/s 实数样点）")
        row = QHBoxLayout()
        gen = QPushButton("生成标准波形…")
        gen.setToolTip("在「发射参数」页设置正弦/方波/多音/扫频等参数并生成")
        gen.clicked.connect(lambda: self.left_tabs.setCurrentIndex(1))
        imp = QPushButton("导入波形文件…")
        imp.setToolTip(".npy / .csv / .txt / .mat / v1 hex 目录；读取后在「发射参数」页选择变量")
        imp.clicked.connect(self._pick_file_and_show)
        row.addWidget(gen)
        row.addWidget(imp)
        v.addLayout(row)
        self.src_label = sty.label("尚未生成或导入发射波形。", "muted")
        self.src_label.setWordWrap(True)
        v.addWidget(self.src_label)
        v.addWidget(QLabel("输出通道（选中 = 下载并播放）"))
        grid = QGridLayout()
        grid.setSpacing(6)
        self.ch_checks = []
        for ch in range(8):
            b = sty.chan_button(f"DAC{ch}")
            b.toggled.connect(lambda on, c=ch: self._set_enabled(c, on))
            grid.addWidget(b, ch // 4, ch % 4)
            self.ch_checks.append(b)
        v.addLayout(grid)
        self.tx_info = sty.label("", "muted")
        self.tx_info.setWordWrap(True)
        v.addWidget(self.tx_info)

        # ④ download and play
        self.verify_cb = QCheckBox("CRC 校验")
        self.verify_cb.setChecked(True)
        self.verify_cb.setToolTip("下载后逐通道比对 FPGA 计算的 CRC（推荐保留）")
        self._section(v, "④ 下载并播放", self.verify_cb)
        g = QGridLayout()
        g.setSpacing(6)
        self.dl_btn = sty.primary(QPushButton("下载（停播并校验）"))
        self.dl_btn.setToolTip("把选中的输出通道下载到 FPGA（下载时会先停止播放）")
        self.dl_btn.clicked.connect(self._download)
        self.dl_cap_btn = QPushButton("一键下载并采集")
        self.dl_cap_btn.setToolTip("下载 → 输出 Run → 采集一次")
        self.dl_cap_btn.clicked.connect(self._download_and_capture)
        self.run_btn = QPushButton("▶ 开始循环播放")
        self.run_btn.clicked.connect(lambda: self._set_output(True))
        self.stop_btn = QPushButton("■ 停止播放")
        self.stop_btn.clicked.connect(lambda: self._set_output(False))
        g.addWidget(self.dl_btn, 0, 0)
        g.addWidget(self.dl_cap_btn, 0, 1)
        g.addWidget(self.run_btn, 1, 0)
        g.addWidget(self.stop_btn, 1, 1)
        v.addLayout(g)
        row = QHBoxLayout()
        self.auto_dl_cb = QCheckBox("生成/导入后自动下载")
        self.auto_dl_cb.setChecked(True)
        self.auto_run_cb = QCheckBox("下载后自动播放")
        self.auto_run_cb.setChecked(True)
        cancel = QPushButton("取消")
        cancel.setToolTip("取消正在进行的下载或采集")
        cancel.clicked.connect(self.worker.cancel.set)
        row.addWidget(self.auto_dl_cb)
        row.addWidget(self.auto_run_cb)
        row.addStretch(1)
        row.addWidget(cancel)
        v.addLayout(row)
        self.dl_info = sty.label("选中输出通道后下载；所有输出通道的波形长度必须相同。", "muted")
        self.dl_info.setWordWrap(True)
        v.addWidget(self.dl_info)

        # ⑤ capture
        self._section(v, "⑤ 采集（ADC 5 GS/s 原始样点）")
        grid = QGridLayout()
        grid.setSpacing(6)
        self.adc_checks = []
        for ch in range(8):
            b = sty.chan_button(f"ADC{ch}")
            b.setChecked(ch == 0)
            b.toggled.connect(self._push_capture_args)
            grid.addWidget(b, ch // 4, ch % 4)
            self.adc_checks.append(b)
        v.addLayout(grid)
        f = QFormLayout()
        f.setHorizontalSpacing(10)
        self.trig_combo = QComboBox()
        self.trig_combo.addItem("手动（立即）", "manual")
        self.trig_combo.addItem("AWG 起播同步", "start")
        self.trig_combo.currentIndexChanged.connect(self._push_capture_args)
        f.addRow("采集触发方式", self.trig_combo)
        self.cap_len = QSpinBox()
        self.cap_len.setRange(24, self.capture_limit)
        self.cap_len.setSingleStep(24)
        self.cap_len.setValue(CAP_MAX)
        self.cap_len.setSuffix(" 点")
        self.cap_len.setKeyboardTracking(False)
        self.cap_len.valueChanged.connect(self._push_capture_args)
        f.addRow("回读点数（每路）", self.cap_len)
        v.addLayout(f)
        self.cap_mode_info = sty.label("V1：最多 65520 点", "muted")
        self.cap_mode_info.setWordWrap(True)
        v.addWidget(self.cap_mode_info)
        g = QGridLayout()
        g.setSpacing(6)
        self.single_btn = sty.primary(QPushButton("采集并显示"))
        self.single_btn.clicked.connect(self._capture_single)
        self.cont_btn = QPushButton("连续采集")
        self.cont_btn.setCheckable(True)
        self.cont_btn.toggled.connect(self._capture_continuous)
        save = QPushButton("保存采集数据…")
        save.clicked.connect(self._save_capture)
        load = QPushButton("打开采集记录…")
        load.clicked.connect(self._load_capture)
        g.addWidget(self.single_btn, 0, 0)
        g.addWidget(self.cont_btn, 0, 1)
        g.addWidget(save, 1, 0)
        g.addWidget(load, 1, 1)
        v.addLayout(g)
        v.addStretch(1)
        return w

    def _build_params_tab(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(8)
        self._section(v, "标准波形")
        v.addWidget(self._build_std_tab())
        self._section(v, "导入波形")
        v.addWidget(self._build_import_tab())
        self._section(v, "通道波形")
        self.ch_table = QTableWidget(8, 3)
        self.ch_table.setHorizontalHeaderLabels(["波形", "峰值", "点数"])
        self.ch_table.setVerticalHeaderLabels([f"DAC{i}" for i in range(8)])
        hdr = self.ch_table.horizontalHeader()
        hdr.setSectionResizeMode(0, QHeaderView.Stretch)
        for col in (1, 2):
            hdr.setSectionResizeMode(col, QHeaderView.ResizeToContents)
        self.ch_table.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.ch_table.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.ch_table.setWordWrap(False)
        self.ch_table.setTextElideMode(Qt.ElideRight)
        self.ch_table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.ch_table.setSelectionMode(QAbstractItemView.SingleSelection)
        self.ch_table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        for ch in range(8):
            for col in range(3):
                self.ch_table.setItem(ch, col, QTableWidgetItem("—"))
        row_h = self.ch_table.fontMetrics().height() + 8
        self.ch_table.verticalHeader().setDefaultSectionSize(row_h)
        self.ch_table.verticalHeader().setSectionResizeMode(QHeaderView.Fixed)
        self.ch_table.setFixedHeight(8 * row_h + self.ch_table.horizontalHeader().sizeHint().height() + 4)
        self.ch_table.itemSelectionChanged.connect(self._update_preview)
        v.addWidget(self.ch_table)
        v.addWidget(sty.label("预览（选中通道，满量程 ±1）", "muted"))
        self.preview = pg.PlotWidget()
        self.preview.setMinimumHeight(140)
        self.preview.setLabel("bottom", "时间 / µs")
        self.preview.getAxis("bottom").setScale(1e6)
        self.preview.showGrid(x=True, y=True, alpha=0.25)
        self.preview.setYRange(-1.05, 1.05)
        self.preview.setMouseEnabled(x=True, y=False)
        self.preview_curve = self.preview.plot(pen=pg.mkPen(CH_COLORS[0], width=1))
        self.preview_curve.setDownsampling(auto=True, method="peak")
        self.preview_curve.setClipToView(True)
        _box_axes(self.preview)
        v.addWidget(self.preview)
        v.addStretch(1)
        return w

    def _build_settings_tab(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(12, 10, 12, 10)
        v.setSpacing(8)
        self._section(v, "板卡网络（QSFP 40GbE）")
        f = QFormLayout()
        self.transport_combo = QComboBox()
        self.transport_combo.addItems(["实验室远程服务", "本机直连光口"])
        self.remote_host = QLineEdit("127.0.0.1")
        self.remote_port = QSpinBox()
        self.remote_port.setRange(1, 65535)
        self.remote_port.setValue(4748)
        f.addRow("连接方式", self.transport_combo)
        f.addRow("实验室 Tailscale 地址", self.remote_host)
        f.addRow("服务 TCP 端口", self.remote_port)
        f.addRow("FPGA IP", self.ip_edit)
        f.addRow("控制端口", self.port_spin)
        f.addRow("每包字数", self.wpp_combo)
        v.addLayout(f)
        usage = sty.label("远程服务无需密码。下载、播放控制和单次采集完成后释放控制权，DAC 保持播放；连续采集停止后释放。更换波形前请手动停止播放。", "muted")
        usage.setWordWrap(True)
        v.addWidget(usage)
        note = sty.label("直连光口：UDP 9100/9101，光口网卡需 MTU 9000，建议 192.168.42.20；不要使用 .10。"
                         "远程模式由实验室电脑负责光口设置，使用者电脑只需填写 Tailscale 地址和服务端口。",
                         "muted")
        note.setWordWrap(True)
        v.addWidget(note)
        self._section(v, "初始化（JTAG 下载 bit + 初始化 LMK/RFDC）")
        f = QFormLayout()
        self.pkg_label = sty.label("", "muted")
        self.pkg_label.setWordWrap(True)
        self.xsct_label = sty.label("", "muted")
        self.xsct_label.setWordWrap(True)
        self.hws_label = sty.label("", "muted")
        f.addRow("固件包", self.pkg_label)
        f.addRow("XSCT", self.xsct_label)
        f.addRow("hw_server", self.hws_label)
        v.addLayout(f)
        g = QGridLayout()
        g.setSpacing(6)
        b_pkg = QPushButton("选择固件包…")
        b_pkg.clicked.connect(self._choose_package)
        b_xsct = QPushButton("选择 XSCT…")
        b_xsct.clicked.connect(self._choose_xsct)
        b_hws = QPushButton("hw_server 地址…")
        b_hws.clicked.connect(self._choose_hw_server)
        self.program_btn = sty.primary(QPushButton("① 下载 bit 并初始化"))
        self.program_btn.clicked.connect(self._program_board)
        self.program_cancel_btn = QPushButton("取消初始化")
        self.program_cancel_btn.setEnabled(False)
        self.program_cancel_btn.clicked.connect(self._cancel_program)
        g.addWidget(b_pkg, 0, 0)
        g.addWidget(b_xsct, 0, 1)
        g.addWidget(b_hws, 1, 0)
        g.addWidget(self.program_btn, 2, 0)
        g.addWidget(self.program_cancel_btn, 2, 1)
        v.addLayout(g)
        v.addStretch(1)
        return w

    def _refresh_paths(self):
        if not hasattr(self, "pkg_label"):
            return
        def breakable(path: str) -> str:       # let long paths wrap inside the narrow tab
            return path.replace("\\", "\​").replace("/", "/​")
        self.pkg_label.setText(breakable(self._package_dir()))
        xsct = find_xsct(self.settings.value("xsct"))
        self.xsct_label.setText(breakable(xsct) if xsct else "未找到（请选择 Vitis 的 xsct.bat）")
        self.hws_label.setText(str(self.settings.value("hw_server", "")) or "本机自动启动")

    def _build_std_tab(self):
        w = QWidget()
        f = QFormLayout(w)
        f.setContentsMargins(0, 0, 0, 0)
        self.std_target = QComboBox()
        self.std_target.addItems([f"DAC{i}" for i in range(8)] + ["全部通道"])
        f.addRow("目标通道", self.std_target)
        self.std_kind = QComboBox()
        for k in wf.KINDS:
            self.std_kind.addItem(wf.KIND_LABELS[k], k)
        self.std_kind.currentIndexChanged.connect(self._update_kind_rows)
        f.addRow("函数", self.std_kind)
        self.std_freq = _mhz_spin(100.0)
        self.std_freq.valueChanged.connect(self._update_actual_freq)
        f.addRow("频率", self.std_freq)
        self.std_actual = sty.label("", "muted")
        self.std_actual.setWordWrap(True)
        f.addRow("实际频率", self.std_actual)
        self.std_amp = QDoubleSpinBox()
        self.std_amp.setRange(-80.0, 0.0)
        self.std_amp.setDecimals(2)
        self.std_amp.setValue(-6.0)
        self.std_amp.setSuffix(" dBFS")
        f.addRow("幅度", self.std_amp)
        self.std_phase = QDoubleSpinBox()
        self.std_phase.setRange(-360, 360)
        self.std_phase.setSuffix(" °")
        f.addRow("相位", self.std_phase)
        self.std_offset = QDoubleSpinBox()
        self.std_offset.setRange(-100, 100)
        self.std_offset.setSuffix(" %FS")
        f.addRow("直流偏置", self.std_offset)
        self.std_duty = QDoubleSpinBox()
        self.std_duty.setRange(0.1, 99.9)
        self.std_duty.setValue(50)
        self.std_duty.setSuffix(" %")
        f.addRow("占空比", self.std_duty)
        self.std_tones = QSpinBox()
        self.std_tones.setRange(1, 1000)
        self.std_tones.setValue(8)
        f.addRow("音数", self.std_tones)
        self.std_spacing = _mhz_spin(50.0, 0.1)
        f.addRow("音间隔", self.std_spacing)
        self.std_stop = _mhz_spin(1000.0)
        f.addRow("终止频率", self.std_stop)
        self.std_len = QSpinBox()
        self.std_len.setRange(32, wf.TX_MAX_SAMPLES)
        self.std_len.setSingleStep(32)
        self.std_len.setValue(wf.TX_MAX_SAMPLES)
        self.std_len.setSuffix(" 点")
        self.std_len.valueChanged.connect(self._update_actual_freq)
        f.addRow("波形长度", self.std_len)
        self.std_len_info = sty.label("", "muted")
        self.std_len_info.setWordWrap(True)
        f.addRow("", self.std_len_info)
        btn = sty.primary(QPushButton("生成到通道"))
        btn.clicked.connect(self._generate)
        f.addRow(btn)
        self._std_rows = {"freq": self.std_freq, "duty": self.std_duty, "tones": self.std_tones,
                          "spacing": self.std_spacing, "stop": self.std_stop, "phase": self.std_phase,
                          "actual": self.std_actual}
        self._std_form = f
        return w

    def _build_import_tab(self):
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(0, 0, 0, 0)
        row = QHBoxLayout()
        b1 = QPushButton("选择文件…")
        b1.clicked.connect(self._pick_file)
        b2 = QPushButton("选择 hex 目录…")
        b2.clicked.connect(self._pick_dir)
        row.addWidget(b1)
        row.addWidget(b2)
        v.addLayout(row)
        self.imp_path = sty.label("支持 .npy / .csv / .txt / .mat / v1 hex 目录", "muted")
        self.imp_path.setWordWrap(True)
        v.addWidget(self.imp_path)
        self.imp_list = QListWidget()
        self.imp_list.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.imp_list.setMinimumHeight(90)
        v.addWidget(QLabel("变量 / 列（可多选，按顺序放到连续通道）"))
        v.addWidget(self.imp_list, 1)
        f = QFormLayout()
        self.imp_scale = QComboBox()
        for k, label in importers.SCALE_MODES.items():
            self.imp_scale.addItem(label, k)
        f.addRow("数值解释", self.imp_scale)
        self.imp_len = QComboBox()
        self.imp_len.addItem("截断到 32 的倍数", "truncate")
        self.imp_len.addItem("补零到 32 的倍数", "pad")
        f.addRow("长度处理", self.imp_len)
        self.imp_start = QComboBox()
        self.imp_start.addItems([f"DAC{i}" for i in range(8)])
        f.addRow("起始通道", self.imp_start)
        v.addLayout(f)
        btn = sty.primary(QPushButton("导入到通道"))
        btn.clicked.connect(self._import_selected)
        v.addWidget(btn)
        self._imported: dict[str, np.ndarray] = {}
        return w

    # ------------------------------------------------------------------ scope side
    def _build_scope_panel(self):
        panel = sty.card()
        v = QVBoxLayout(panel)
        v.setContentsMargins(10, 8, 10, 8)
        v.setSpacing(6)
        v.addWidget(self._build_scope_controls())
        # Fixed two-line summary in a fixed-pitch digit font: changing numbers must not move the layout.
        self.facts = sty.label("连接板卡后「⑤ 采集」；生成或导入波形后可切到「发射预览」。", "facts")
        self.facts.setWordWrap(False)
        facts_font = QFont()
        facts_font.setFamilies(["Consolas", "Microsoft YaHei UI"])
        facts_font.setPointSize(9)
        self.facts.setFont(facts_font)
        self.facts.setFixedHeight(self.facts.fontMetrics().lineSpacing() * 2 + 6)
        self.facts.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Fixed)
        self.facts.setAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        self._facts_t = 0.0
        v.addWidget(self.facts)

        plots = QSplitter(Qt.Vertical)
        self.time_plot = pg.PlotWidget()
        self.time_plot.setTitle("<b>采集波形 · 时域</b>", color=sty.INK, size="10pt")
        self.time_plot.setLabel("bottom", "时间 / µs")
        self.time_plot.getAxis("bottom").setScale(1e6)          # data in s, ticks in µs
        self.time_plot.setLabel("left", "14 bit 码值")
        self.time_plot.showGrid(x=True, y=True, alpha=0.25)
        self.legend = self.time_plot.addLegend(offset=(-10, 10))
        self._time_user_zoom = False
        self._time_setting_range = False
        self.time_plot.getViewBox().sigRangeChangedManually.connect(self._on_time_zoom)
        self.spec_plot = pg.PlotWidget()
        self.spec_plot.setTitle("<b>采集频谱</b>", color=sty.INK, size="10pt")
        self.spec_plot.setLabel("bottom", "频率 / MHz")
        self.spec_plot.getAxis("bottom").setScale(1e-6)         # data in Hz, ticks in MHz
        self.spec_plot.setLabel("left", "dBFS")
        self.spec_plot.showGrid(x=True, y=True, alpha=0.25)
        self.spec_plot.setYRange(-140, 5)
        self.spec_plot.setXRange(0, ADC_FS / 2, padding=0)
        self.time_plot.setXRange(0, CAP_MAX / ADC_FS, padding=0)
        for p in (self.time_plot, self.spec_plot):
            _box_axes(p)
        self.time_curves, self.spec_curves = [], []
        for ch in range(8):
            pen = pg.mkPen(CH_COLORS[ch], width=1)
            c = self.time_plot.plot(pen=pen)
            c.opts["name"] = f"ADC{ch}"
            s = self.spec_plot.plot(pen=pen)
            for item in (c, s):
                item.setDownsampling(auto=True, method="peak")
                item.setClipToView(True)
                item.setSkipFiniteCheck(True)
            self.time_curves.append(c)
            self.spec_curves.append(s)
        tx_pen = pg.mkPen(sty.SELECTED, width=1.4)
        self.tx_time_curve = self.time_plot.plot(pen=tx_pen)
        self.tx_spec_curve = self.spec_plot.plot(pen=pg.mkPen(sty.SELECTED, width=1))
        for item in (self.tx_time_curve, self.tx_spec_curve):
            item.setDownsampling(auto=True, method="peak")
            item.setClipToView(True)
            item.setSkipFiniteCheck(True)
            item.setVisible(False)
        self._tx_spec_cache: dict[int, tuple] = {}
        self.m1_line = pg.InfiniteLine(angle=90, movable=False, pen=pg.mkPen("#E24B4A", width=1, style=Qt.DashLine))
        self.m1_text = pg.TextItem(color="#A32D2D", anchor=(0, 1))
        self.m2_line = pg.InfiniteLine(pos=500e6, angle=90, movable=True, pen=pg.mkPen("#534AB7", width=1))
        self.m2_text = pg.TextItem(color="#3C3489", anchor=(0, 1))
        for item in (self.m1_line, self.m1_text, self.m2_line, self.m2_text):
            self.spec_plot.addItem(item)
        self.m2_line.setVisible(False)
        self.m2_text.setVisible(False)
        self.m2_line.sigPositionChanged.connect(self._update_m2)
        plots.addWidget(self.time_plot)
        plots.addWidget(self.spec_plot)
        plots.setSizes([400, 400])
        v.addWidget(plots, 1)
        v.addWidget(self._build_meas_cards())
        return panel

    def _build_scope_controls(self):
        box = QWidget()
        v = QVBoxLayout(box)
        v.setContentsMargins(0, 0, 0, 0)
        v.setSpacing(4)
        # row 0: what to show (采集波形 / 发射预览) + preview controls + time-axis buttons
        row = QHBoxLayout()
        self.view_combo = QComboBox()
        self.view_combo.addItem("采集波形", "capture")
        self.view_combo.addItem("发射预览", "tx")
        self.view_combo.setMinimumWidth(110)
        self.view_combo.currentIndexChanged.connect(self._on_view_changed)
        row.addWidget(self.view_combo)
        self.tx_controls = QWidget()
        th = QHBoxLayout(self.tx_controls)
        th.setContentsMargins(0, 0, 0, 0)
        self.tx_ch_combo = QComboBox()
        for ch in range(8):
            self.tx_ch_combo.addItem(f"DAC{ch}", ch)
        self.tx_ch_combo.currentIndexChanged.connect(lambda *_: self._draw_tx_preview(reset=True))
        self.tx_win_combo = QComboBox()
        for text, n in TX_WINDOWS:
            self.tx_win_combo.addItem(text, n)
        self.tx_win_combo.currentIndexChanged.connect(lambda *_: self._draw_tx_preview(reset=True))
        self.tx_pos = QSlider(Qt.Horizontal)
        self.tx_pos.setMinimumWidth(160)
        self.tx_pos.valueChanged.connect(lambda *_: self._draw_tx_preview())
        th.addWidget(self.tx_ch_combo)
        th.addWidget(self.tx_win_combo)
        th.addWidget(QLabel("窗口位置"))
        th.addWidget(self.tx_pos, 1)
        row.addWidget(self.tx_controls, 1)
        self.tx_controls.setVisible(False)
        self.cap_row0 = QWidget()
        ch_ = QHBoxLayout(self.cap_row0)
        ch_.setContentsMargins(0, 0, 0, 0)
        ch_.addWidget(QLabel("窗函数"))
        self.win_combo = QComboBox()
        for k, label in measure.WINDOW_LABELS.items():
            self.win_combo.addItem(label, k)
        self.win_combo.currentIndexChanged.connect(self._push_capture_args)
        ch_.addWidget(self.win_combo)
        ch_.addWidget(QLabel("纵轴"))
        self.yunit = QComboBox()
        self.yunit.addItem("14 bit 码值", "code")
        self.yunit.addItem("满量程 (±1)", "fs")
        self.yunit.currentIndexChanged.connect(self._redraw_time)
        ch_.addWidget(self.yunit)
        ch_.addWidget(QLabel("测量通道"))
        self.meas_ch = QComboBox()
        self.meas_ch.addItems([f"ADC{i}" for i in range(8)])
        self.meas_ch.currentIndexChanged.connect(self._refresh_meas)
        ch_.addWidget(self.meas_ch)
        ch_.addStretch(1)
        row.addWidget(self.cap_row0, 1)
        auto = QPushButton("时域自动")
        auto.setToolTip("采集：显示约 10 个周期并自动纵轴（类似示波器 Auto）；发射预览：1024 点窗口")
        auto.clicked.connect(self._time_auto)
        whole = QPushButton("全长")
        whole.setToolTip("时域图显示整段记录")
        whole.clicked.connect(self._time_whole)
        row.addWidget(auto)
        row.addWidget(whole)
        v.addLayout(row)
        # row 1: spectrum view of the capture (center / span / M2)
        self.cap_row1 = QWidget()
        h = QHBoxLayout(self.cap_row1)
        h.setContentsMargins(0, 0, 0, 0)
        h.addWidget(QLabel("中心 / 跨度"))
        self.center = _mhz_spin(1250.0, 0.0, 2500.0, 3, 10)
        self.span = _mhz_spin(2500.0, 0.01, 2500.0, 3, 10)
        self.center.valueChanged.connect(self._apply_span)
        self.span.valueChanged.connect(self._apply_span)
        full = QPushButton("全跨度")
        full.clicked.connect(lambda: (self.center.setValue(1250.0), self.span.setValue(2500.0)))
        self.m2_cb = QCheckBox("M2")
        self.m2_cb.setToolTip("可拖动的第二标记，显示与 M1 的差值")
        self.m2_cb.toggled.connect(self._toggle_m2)
        for wdg in (self.center, self.span, full, self.m2_cb):
            h.addWidget(wdg)
        h.addStretch(1)
        v.addWidget(self.cap_row1)
        return box

    # ------------------------------------------------------------------ 采集波形 / 发射预览
    def _view(self) -> str:
        return self.view_combo.currentData()

    def _set_view(self, mode: str):
        index = self.view_combo.findData(mode)
        if index >= 0 and index != self.view_combo.currentIndex():
            self.view_combo.setCurrentIndex(index)

    def _on_view_changed(self, *_):
        tx = self._view() == "tx"
        self.tx_controls.setVisible(tx)
        self.cap_row0.setVisible(not tx)
        self.cap_row1.setVisible(not tx)
        for curve in self.time_curves + self.spec_curves:
            curve.setVisible(not tx)
        self.tx_time_curve.setVisible(tx)
        self.tx_spec_curve.setVisible(tx)
        has_m1 = not tx and self.last_capture is not None
        self.m1_line.setVisible(has_m1)
        self.m1_text.setVisible(has_m1)
        self.m2_line.setVisible(not tx and self.m2_cb.isChecked())
        self.m2_text.setVisible(not tx and self.m2_cb.isChecked())
        if tx:
            self._draw_tx_preview(reset=True)
        else:
            self.legend.clear()
            self._capture_titles()
            if self.last_capture is not None:
                self._redraw_time()
                self._refresh_meas()
                self.facts.setText(getattr(self, "_capture_message", "")
                                   + ("\n" + self._timing_text if getattr(self, "_timing_text", "") else ""))
            else:
                self.facts.setText("连接板卡后「⑤ 采集」。")
            self._apply_span()

    def _capture_titles(self):
        d = self.last_capture
        if d is None:
            self.time_plot.setTitle("<b>采集波形 · 时域</b>", color=sty.INK, size="10pt")
            self.spec_plot.setTitle("<b>采集频谱</b>", color=sty.INK, size="10pt")
            return
        chans = sorted(d["samples"])
        trig = "AWG 起播同步" if d["trigger"] == "start" else "手动触发"
        self.time_plot.setTitle(f"<b>采集波形 · {'、'.join(f'ADC{c}' for c in chans)}</b> · {trig}",
                                color=sty.INK, size="10pt")
        self.spec_plot.setTitle(f"<b>采集频谱</b> · {self.win_combo.currentText()}窗 · 单边 FFT",
                                color=sty.INK, size="10pt")
        self.spec_plot.setLabel("left", "dBFS")

    def _tx_spectrum(self, ch: int):
        """Full-record spectrum of the 14-bit codes that are downloaded (Hann window, dB relative to DAC
        full scale), so the floor shows the real quantization noise. Cached per waveform."""
        wave = self.waves[ch]
        key = id(wave["y"])
        cached = self._tx_spec_cache.get(ch)
        if cached and cached[0] == key:
            return cached[1], cached[2]
        y = wf.quantize(wave["y"]).astype(np.float64) / 32768.0
        n = len(y)
        w = np.hanning(n)
        mag = np.abs(np.fft.rfft((y - y.mean()) * w)) / (w.sum() / 2.0)
        db = (20.0 * np.log10(np.maximum(mag, 1e-12))).astype(np.float32)
        f = np.fft.rfftfreq(n, 1.0 / wf.DAC_FS_HZ)
        self._tx_spec_cache[ch] = (key, f, db)
        return f, db

    def _draw_tx_preview(self, reset: bool = False):
        if self._view() != "tx":
            return
        ch = self.tx_ch_combo.currentData()
        wave = self.waves.get(ch)
        self.time_plot.setTitle(f"<b>发射预览 · DAC{ch}</b>", color=sty.INK, size="10pt")
        self.spec_plot.setTitle("<b>完整记录频谱</b> · 14 bit 量化后 · Hann 窗 · 单边 FFT", color=sty.INK, size="10pt")
        self.time_plot.setLabel("left", "归一化 DAC 幅度")
        self.spec_plot.setLabel("left", "dB / DAC 满量程")
        self.legend.clear()
        if wave is None:
            self.tx_time_curve.setData([], [])
            self.tx_spec_curve.setData([], [])
            self.facts.setText(f"发射预览 | DAC{ch} 还没有波形：在「③ 选波形」生成或导入。")
            return
        y = wave["y"]
        n = len(y)
        win = self.tx_win_combo.currentData() or n
        win = min(win, n)
        self.tx_pos.blockSignals(True)
        self.tx_pos.setRange(0, max(n - win, 0))
        self.tx_pos.setSingleStep(max(win // 8, 1))
        self.tx_pos.setPageStep(max(win, 1))
        if reset:
            self.tx_pos.setValue(0)
        self.tx_pos.blockSignals(False)
        start = min(self.tx_pos.value(), max(n - win, 0))
        t = (start + np.arange(win)) / wf.DAC_FS_HZ
        self.tx_time_curve.setData(t, y[start:start + win].astype(np.float32))
        self.legend.addItem(self.tx_time_curve, f"DAC{ch}")
        self._time_setting_range = True
        self.time_plot.setXRange(t[0], t[-1], padding=0)
        peak = float(np.max(np.abs(y))) or 1.0
        self.time_plot.setYRange(-peak * 1.15, peak * 1.15, padding=0)
        self._time_setting_range = False
        f, db = self._tx_spectrum(ch)
        self.tx_spec_curve.setData(f, db)
        if reset:
            self.spec_plot.setXRange(0, wf.DAC_FS_HZ / 2, padding=0)
            self.spec_plot.setYRange(-140, 5, padding=0)
        k = int(np.argmax(db[1:])) + 1 if len(db) > 1 else 0
        self.facts.setText(
            f"发射预览 | Fs {wf.DAC_FS_HZ / 1e9:.3f} GS/s | {n:,} 点/通道 | 循环周期 {n / wf.DAC_FS_HZ * 1e6:.3f} µs | "
            f"FFT 间隔 {_fmt_hz(wf.DAC_FS_HZ / n)} | 峰值 {_fmt_hz(f[k])} {db[k]:.2f} dBFS\n"
            f"{wave['desc']} | 窗口 {start:,}～{start + win - 1:,}（{win:,} 点，{win / wf.DAC_FS_HZ * 1e6:.3f} µs）")

    def _refresh_tx_choice(self, ch: int):
        """After a waveform is set on ch: preview that channel."""
        self.tx_ch_combo.blockSignals(True)
        self.tx_ch_combo.setCurrentIndex(ch)
        self.tx_ch_combo.blockSignals(False)
        self._tx_spec_cache.pop(ch, None)
        self._draw_tx_preview(reset=True)

    def _build_meas_cards(self):
        box = QWidget()
        h = QHBoxLayout(box)
        h.setContentsMargins(0, 2, 0, 0)
        h.setSpacing(6)
        self.cards = {}
        for key, title in (("freq", "频率"), ("level", "幅度"), ("vpp", "Vpp (码值)"), ("rms", "RMS (码值)"),
                           ("sfdr", "SFDR"), ("sinad", "SINAD"), ("snr", "SNR"), ("acq", "采集")):
            card = QFrame()
            card.setStyleSheet(f"QFrame {{ background:{sty.BG}; border:1px solid {sty.BORDER}; border-radius:5px; }}")
            cv = QVBoxLayout(card)
            cv.setContentsMargins(8, 4, 8, 4)
            t = QLabel(title)
            t.setStyleSheet(f"color:{sty.MUTED}; background:transparent; border:none;")
            val = QLabel("—")
            font = QFont()
            font.setPointSize(11)
            font.setBold(True)
            val.setFont(font)
            val.setStyleSheet(f"color:{sty.INK}; background:transparent; border:none;")
            cv.addWidget(t)
            cv.addWidget(val)
            h.addWidget(card, 1)
            self.cards[key] = val
        return box

    # ================================================================== workflow steps / status row
    def _update_steps(self):
        if not hasattr(self, "steps"):
            return
        programming = self.programmer.running() if hasattr(self, "programmer") else False
        waiting = getattr(self, "_waiting_ready", False)
        has_wave = any(self.enabled[ch] and ch in self.waves for ch in range(8))
        done = [
            bool(self.device_status.get("ps_ready")) or self.connected,
            self.connected,
            has_wave,
            self.connected and self.running and getattr(self, "_downloaded_once", False),
            self.connected and self.last_capture is not None,
        ]
        states = ["done" if d else "todo" for d in done]
        if programming or waiting:
            states[0] = "current"
            states[1] = "todo"
        else:
            for i, d in enumerate(done):
                if not d:
                    states[i] = "current"
                    break
        self.steps.set_states(states)

    def _on_step_clicked(self, index: int):
        if index == 0:
            self._program_board()
        elif index == 1:
            if not self.connected:
                self._toggle_connect()
        elif index == 2:
            self.left_tabs.setCurrentIndex(1)
        elif index == 3:
            self.left_tabs.setCurrentIndex(0)
            self._download()
        else:
            self.left_tabs.setCurrentIndex(0)
            self._capture_single()

    def _refresh_status(self):
        if not self.connected:
            self._msg("未连接", error=True)
            return
        self.req_refresh.emit()

    def _clear_fault(self):
        if not self.connected:
            self._msg("未连接", error=True)
            return
        self.req_clear_fault.emit()

    def _set_leds(self):
        st = self.device_status
        self.led_link.set_color(sty.OK if self.connected else sty.OFF)
        self.led_ready.set_color(sty.OK if st.get("ps_ready") else sty.OFF)
        self.led_play.set_color(sty.OK if self.connected and self.running else sty.OFF)
        fault = bool(st.get("fault") or st.get("faults"))
        self.led_fault.set_color(sty.BAD if fault else sty.OFF)

    def _start_progress(self, text: str, indeterminate: bool = False):
        self._prog_task = text
        self._prog_t0 = time.monotonic()
        self.progress_text.setText(text)
        if indeterminate:
            self.progress.setRange(0, 0)
            self.progress_pct.setText("")
        self._prog_timer.start()
        self._tick_progress()

    def _tick_progress(self):
        if self._prog_task is None:
            self._prog_timer.stop()
            return
        elapsed = time.monotonic() - self._prog_t0
        self.progress_elapsed.setText(f"已用 {_fmt_dur(elapsed)}")

    def _progress_idle(self, text: str | None = None):
        if self._prog_task is not None and text is None:
            elapsed = time.monotonic() - self._prog_t0
            text = f"完成：{self._prog_task}（{_fmt_dur(elapsed)}）"
        self._prog_task = None
        self._prog_timer.stop()
        self.progress.setRange(0, 1)
        self.progress.setValue(1 if text and text.startswith("完成") else 0)
        self.progress_text.setText(text or "就绪")
        self.progress_pct.setText("")
        self.progress_elapsed.setText("")
        self.progress_remain.setText("")

    # ================================================================== device menu: program + init
    def _build_device_menu(self):
        self.programmer = BoardProgrammer(self)
        self.programmer.line.connect(lambda s: self._log("[xsct] " + s))
        self.programmer.finished.connect(self._on_program_finished)
        menu = self.menuBar().addMenu("设备")
        self.act_program = QAction("下载 bit 并初始化…", self)
        self.act_program.setShortcut("Ctrl+F5")
        self.act_program.triggered.connect(self._program_board)
        menu.addAction(self.act_program)
        self.act_program_cancel = QAction("取消初始化", self)
        self.act_program_cancel.setEnabled(False)
        self.act_program_cancel.triggered.connect(self._cancel_program)
        menu.addAction(self.act_program_cancel)
        menu.addSeparator()
        act = QAction("设置固件包目录…", self)
        act.triggered.connect(self._choose_package)
        menu.addAction(act)
        act = QAction("设置 XSCT 路径…", self)
        act.triggered.connect(self._choose_xsct)
        menu.addAction(act)
        act = QAction("设置 hw_server 地址…", self)
        act.triggered.connect(self._choose_hw_server)
        menu.addAction(act)
        self._refresh_paths()

    def _package_dir(self) -> str:
        saved = str(self.settings.value("fw_package", "") or "")
        if saved and not missing_package_files(saved):
            return saved
        return str(default_package())          # firmware/ next to the exe, or build/F3/package in the source tree

    def _choose_package(self):
        path = QFileDialog.getExistingDirectory(self, "选择固件包目录（含 bit/elf/psu_init.tcl/init_protocol.txt）",
                                                self._package_dir())
        if path:
            missing = missing_package_files(path)
            if missing:
                QMessageBox.warning(self, "固件包不完整", "缺少：" + "、".join(missing))
                return
            self.settings.setValue("fw_package", path)
            self._refresh_paths()
            self._msg(f"固件包：{path}")

    def _choose_xsct(self):
        start = find_xsct(self.settings.value("xsct")) or ""
        path, _ = QFileDialog.getOpenFileName(self, "选择 xsct.bat", start, "XSCT (xsct.bat xsct.exe);;所有文件 (*)")
        if path:
            self.settings.setValue("xsct", path)
            self._refresh_paths()
            self._msg(f"XSCT：{path}")

    def _choose_hw_server(self):
        from PySide6.QtWidgets import QInputDialog
        cur = str(self.settings.value("hw_server", ""))
        text, ok = QInputDialog.getText(self, "hw_server 地址",
                                        "留空 = 本机自动启动 hw_server；远程请填 host:3121", text=cur)
        if ok:
            self.settings.setValue("hw_server", text.strip())
            self._refresh_paths()

    def _program_board(self, confirm: bool = True):
        if self.transport_combo.currentIndex() == 0:
            QMessageBox.information(self, "初始化位置", "远程模式请由实验室电脑在确认无人用板后初始化；控制服务不执行 JTAG 复位或烧写。")
            return
        if self.programmer.running():
            return
        package = self._package_dir()
        missing = missing_package_files(package)
        if missing:
            QMessageBox.warning(self, "固件包不完整", f"{package}\n缺少：" + "、".join(missing)
                                + "\n请用「设备 → 设置固件包目录」选择。")
            return
        xsct = find_xsct(self.settings.value("xsct"))
        if not xsct:
            QMessageBox.warning(self, "找不到 XSCT", "请用「设备 → 设置 XSCT 路径」指定 Vitis 的 xsct.bat。")
            return
        server = str(self.settings.value("hw_server", ""))
        ret = QMessageBox.Yes if not confirm else QMessageBox.question(
            self, "下载 bit 并初始化",
            f"将通过 JTAG 复位整板、下载 FPGA bit 并初始化 LMK/RFDC，DAC/ADC 中的数据会丢失。\n\n"
            f"固件包：{package}\nXSCT：{xsct}\nhw_server：{server or '本机自动'}\n\n"
            f"全程约 1 分钟，完成后自动连接。继续？")
        if ret != QMessageBox.Yes:
            return
        self.cont_btn.setChecked(False)
        self.worker.cancel.set()
        self.req_close.emit()
        self._show_log()
        self._set_program_buttons(running=True)
        self.conn_label.setText("● 下载 bit / 初始化中…")
        self.conn_label.setStyleSheet("color:#BA7517")
        self._program_t0 = time.monotonic()
        self._msg("开始下载 bit 并初始化…")
        self.programmer.start(xsct, package, server)
        self._start_progress("① 下载 bit 并初始化（JTAG 下载、LMK/RFDC 初始化，约 1 分钟）", indeterminate=True)
        self._update_steps()

    def _set_program_buttons(self, running: bool):
        self.act_program.setEnabled(not running)
        self.act_program_cancel.setEnabled(running)
        self.program_btn.setEnabled(not running)
        self.program_cancel_btn.setEnabled(running)
        self.connect_btn.setEnabled(not running)

    def _cancel_program(self):
        self.programmer.cancel()
        self.worker.cancel.set()            # also stops a running wait-for-ready

    def _on_program_finished(self, ok: bool, message: str):
        dt = time.monotonic() - getattr(self, "_program_t0", time.monotonic())
        if not ok:
            self._set_program_buttons(running=False)
            self._progress_idle("① 下载 bit / 初始化失败")
            self._update_steps()
            self.conn_label.setText("● 未连接")
            self.conn_label.setStyleSheet("color:#888780")
            self._msg(f"下载 bit / 初始化失败：{message}", error=True)
            QMessageBox.warning(self, "下载 bit / 初始化失败", message)
            return
        self._msg(f"{message}（{dt:.0f} s），等待板卡就绪…")
        self.conn_label.setText("● 等待板卡就绪…")
        self._waiting_ready = True
        self.progress_text.setText("等待板卡就绪（PS 完成 RFDC/MTS 初始化后自动连接）…")
        self.req_connect_ready.emit(self.ip_edit.text().strip(), self.port_spin.value(),
                                    int(self.wpp_combo.currentText()), READY_TIMEOUT_S)

    def _end_program_wait(self, ok: bool):
        if not getattr(self, "_waiting_ready", False):
            return
        self._waiting_ready = False
        self._set_program_buttons(running=False)
        if ok:
            dt = time.monotonic() - self._program_t0
            self._progress_idle(f"完成：① 初始化板卡并连接（{_fmt_dur(dt)}）")
            self._msg(f"下载 bit 并初始化完成，已连接（共 {dt:.0f} s）")
        else:
            self._progress_idle("等待板卡就绪失败")
        self._update_steps()

    # ================================================================== settings
    def _restore(self):
        s = self.settings
        self.transport_combo.setCurrentIndex(int(s.value("transport", 0)))
        self.remote_host.setText(str(s.value("remote_host", "127.0.0.1")))
        self.remote_port.setValue(int(s.value("remote_port", 4748)))
        self.ip_edit.setText(s.value("ip", self.ip_edit.text()))
        self.port_spin.setValue(int(s.value("port", self.port_spin.value())))
        idx = self.wpp_combo.findText(str(s.value("wpp", "2048")))
        self.wpp_combo.setCurrentIndex(max(idx, 0))
        geo = s.value("geometry")
        if geo is not None:
            self.restoreGeometry(geo)
        self._refresh_paths()

    def closeEvent(self, event):
        if self.thread.isRunning():
            event.ignore()
            if not getattr(self, "_closing", False):
                self._closing = True
                self.setEnabled(False)
                self.programmer.cancel()
                self.worker.cancel.set()
                self.req_cap_stop.emit()
                self.req_close.emit()
                self.statusBar().showMessage("等待当前操作结束并释放连接…")
            return
        s = self.settings
        s.setValue("transport", self.transport_combo.currentIndex())
        s.setValue("remote_host", self.remote_host.text())
        s.setValue("remote_port", self.remote_port.value())
        s.setValue("ip", self.ip_edit.text())
        s.setValue("port", self.port_spin.value())
        s.setValue("wpp", self.wpp_combo.currentText())
        s.setValue("geometry", self.saveGeometry())
        super().closeEvent(event)

    def _worker_closed(self):
        if getattr(self, "_closing", False):
            self.thread.quit()

    def _finish_close(self):
        if getattr(self, "_closing", False):
            self.close()

    # ================================================================== logging / status
    def _log(self, text: str):
        line = time.strftime("%H:%M:%S ") + text.rstrip()
        self.log_view.appendPlainText(line)
        self._log_to_file(line)

    def _log_to_file(self, line: str):
        # Same text as the log panel, kept on disk for field debugging:
        # %APPDATA%\awg_gui_v2\logs\awg_gui_YYYYMMDD.log
        try:
            if getattr(self, "_log_file", None) is None:
                folder = Path(self.settings.fileName()).parent / "logs"
                folder.mkdir(parents=True, exist_ok=True)
                self._log_file_path = folder / time.strftime("awg_gui_%Y%m%d.log")
                self._log_file = open(self._log_file_path, "a", encoding="utf-8", buffering=1)
                self._log_file.write(f"==== {time.strftime('%Y-%m-%d %H:%M:%S')} {APP_VERSION} start ====\n")
            if self._log_file:
                self._log_file.write(line + "\n")
        except OSError:
            self._log_file = False                 # disk problem: keep the GUI running without a file log

    def _msg(self, text: str, error: bool = False):
        self.statusBar().showMessage(text, 0 if error else 8000)
        self._log(("错误：" if error else "") + text)

    def _on_failed(self, op: str, message: str):
        self._progress_idle(f"{op}失败：{message}")
        if op == "采集":
            self.cont_btn.blockSignals(True)
            self.cont_btn.setChecked(False)
            self.cont_btn.blockSignals(False)
        self._msg(f"{op}失败：{message}", error=True)
        if op == "连接":
            self.transport_combo.setEnabled(True)
            self.remote_host.setEnabled(True)
            self.remote_port.setEnabled(True)
            self._end_program_wait(False)
            self.conn_label.setText("● 未连接")
            self.conn_label.setStyleSheet("color:#888780")
        if op in ("连接", "下载"):
            self._capture_after_download = False
            QMessageBox.warning(self, f"{op}失败", message)

    def _on_busy(self, busy: bool):
        self._busy = busy
        self.setCursor(Qt.BusyCursor if busy else Qt.ArrowCursor)

    def _on_progress(self, text: str, done: int, total: int):
        if self._prog_task != text:
            self._start_progress(text)
        total = max(total, 1)
        self.progress.setRange(0, total)
        self.progress.setValue(min(done, total))
        frac = min(done / total, 1.0)
        self.progress_text.setText(f"{text} · {done:,} / {total:,} 点")
        self.progress_pct.setText(f"{frac * 100:.0f}%")
        elapsed = time.monotonic() - self._prog_t0
        self.progress_elapsed.setText(f"已用 {_fmt_dur(elapsed)}")
        self.progress_remain.setText(f"预计剩余 {_fmt_dur(elapsed * (1 - frac) / frac)}" if frac > 0 else "")
        if done >= total:
            self._progress_idle()

    # ================================================================== connection / output
    def _toggle_connect(self):
        if self.connected:
            self.cont_btn.setChecked(False)
            self.req_close.emit()
            return
        self.conn_label.setText("● 连接中…")
        self.conn_label.setStyleSheet("color:#BA7517")
        self._start_progress("② 连接板卡", indeterminate=True)
        self.transport_combo.setEnabled(False)
        self.remote_host.setEnabled(False)
        self.remote_port.setEnabled(False)
        if self.transport_combo.currentIndex() == 0:
            self.req_remote.emit(self.remote_host.text().strip(), self.remote_port.value())
        else:
            self.req_connect.emit(self.ip_edit.text().strip(), self.port_spin.value(), int(self.wpp_combo.currentText()))

    def _on_connected(self, info: dict):
        self.connected = True
        self.device_status = dict(info.get("status", {}))
        self.connect_btn.setText("断开连接")
        self.conn_label.setText("● 已连接")
        self.conn_label.setStyleSheet("color:#3B6D11")
        build = info.get("build_id_reg", 0)
        abi = int(info.get("status", {}).get("abi", 0))
        self._hdr_base = f"{info['ip']}:{info['port']} · BUILD 0x{build:08X} · ABI 0x{abi:08X}"
        self.info_label.setText(f"DAC 9.8 GS/s · ADC 5 GS/s raw · 40GbE 光口 · BUILD 0x{build:08X}")
        if self._prog_task == "② 连接板卡":
            self._progress_idle("完成：② 连接板卡")
        self._update_capture_limit()
        self._on_status(info["status"])
        self._msg(f"已连接 {info['ip']}:{info['port']}（协议 {info.get('protocol_version')}，"
                  f"单包最多 {info.get('max_words')} 字）")
        self._end_program_wait(True)

    def _on_disconnected(self):
        self.transport_combo.setEnabled(True)
        self.remote_host.setEnabled(True)
        self.remote_port.setEnabled(True)
        self.connected = False
        self.device_status = {}
        self.capture_limit = CAP_MAX
        self.connect_btn.setText("连接板卡")
        self.conn_label.setText("● 未连接")
        self.conn_label.setStyleSheet("color:#888780")
        self.state_label.setText("")
        self.hdr_info.setText("40GbE 光口 · 未连接")
        self._update_capture_limit()
        self._set_leds()
        self._update_steps()
        self._msg("已断开（断开不会停止 DAC 播放）")

    def _on_status(self, st: dict):
        self.device_status = dict(st)
        self.running = bool(st.get("running"))
        parts = ["输出：运行中" if self.running else "输出：已停止"]
        if not st.get("ps_ready"):
            parts.append("PS 未就绪")
        if st.get("fault") or st.get("faults"):
            parts.append(f"故障 0x{st.get('faults', 0):02X}")
        mask = st.get("channel_mask", 0)
        parts.append(f"通道掩码 0x{mask:02X}")
        self.state_label.setText(" · ".join(parts))
        self.state_label.setStyleSheet("color:#3B6D11" if self.running else f"color:{sty.MUTED}")
        if self.connected:
            self.hdr_info.setText(f"{getattr(self, '_hdr_base', '')} · 状态读取于 {time.strftime('%H:%M:%S')}")
        self._set_leds()
        self._update_capture_limit()
        self._update_steps()

    def _update_capture_limit(self):
        """Update the capture range and mode label from ABI and selected ADC channels."""
        n_channels = sum(1 for cb in getattr(self, "adc_checks", []) if cb.isChecked()) or 1
        abi = int(self.device_status.get("abi", 0))
        bank_words = int(self.device_status.get("cap_bank_words", 10240))
        if abi >= 0x00040000 and self.device_status.get("bulk_available", 0):
            slots = 1
            while slots < n_channels:
                slots <<= 1
            self.capture_limit = (8 // slots) * bank_words * 24
            duration_us = self.capture_limit / ADC_FS * 1e6
            self.cap_mode_info.setText(f"V2：{slots} 通道模式，最多 {self.capture_limit:,} 点（{duration_us:.1f} µs）")
        else:
            self.capture_limit = CAP_MAX
            self.cap_mode_info.setText("V1：最多 65520 点（13.1 µs）")
        self._update_tx_limit()
        if hasattr(self, "cap_len"):
            value = min(max(self.cap_len.value(), 24), self.capture_limit)
            value -= value % 24
            self.cap_len.blockSignals(True)
            self.cap_len.setRange(24, self.capture_limit)
            self.cap_len.setValue(max(24, value))
            self.cap_len.blockSignals(False)

    def _set_output(self, run: bool):
        if not self.connected:
            self._msg("未连接", error=True)
            return
        self.req_output.emit(run)

    # ================================================================== waveforms
    def _kind(self) -> str:
        return self.std_kind.currentData()

    def _update_kind_rows(self):
        k = self._kind()
        show = {
            "freq": k in ("sine", "square", "triangle", "ramp", "pulse", "multitone", "chirp"),
            "actual": k in ("sine", "square", "triangle", "ramp", "pulse", "multitone", "chirp"),
            "phase": k in ("sine", "square", "triangle", "ramp", "pulse", "multitone", "chirp"),
            "duty": k in ("square", "pulse"),
            "tones": k == "multitone",
            "spacing": k == "multitone",
            "stop": k == "chirp",
        }
        for key, widget in self._std_rows.items():
            self._std_form.setRowVisible(widget, show[key])
        label = {"multitone": "起始频率", "chirp": "起始频率"}.get(k, "频率")
        self._std_form.labelForField(self.std_freq).setText(label)
        self._update_actual_freq()

    def _update_actual_freq(self):
        n = wf.valid_length(self.std_len.value(), self.tx_limit)
        cycles, f_act = wf.snap_cycles(self.std_freq.value() * 1e6, n)
        self.std_actual.setText(f"{_fmt_hz(f_act)}（{cycles} 个周期 / {n} 点，步进 {_fmt_hz(wf.DAC_FS_HZ / n)}）")
        self.std_len_info.setText(f"循环周期 {n / wf.DAC_FS_HZ * 1e6:.3f} µs；"
                                  + getattr(self, "_tx_limit_note", ""))

    def _spec(self) -> wf.WaveSpec:
        return wf.WaveSpec(kind=self._kind(), freq_hz=self.std_freq.value() * 1e6, amp_dbfs=self.std_amp.value(),
                           phase_deg=self.std_phase.value(), offset_fs=self.std_offset.value() / 100.0,
                           duty=self.std_duty.value() / 100.0, tones=self.std_tones.value(),
                           spacing_hz=self.std_spacing.value() * 1e6, stop_hz=self.std_stop.value() * 1e6,
                           samples=self.std_len.value())

    def _generate(self):
        spec = self._spec()
        targets = range(8) if self.std_target.currentIndex() == 8 else [self.std_target.currentIndex()]
        for ch in targets:
            spec.seed = ch + 1
            y, info = wf.generate(spec)
            desc = wf.KIND_LABELS[spec.kind]
            if "freq_hz" in info:
                desc += f" {_fmt_hz(info['freq_hz'])}"
            elif "start_hz" in info:
                desc += f" {_fmt_hz(info['start_hz'])}→{_fmt_hz(info['stop_hz'])}"
            elif "freqs_hz" in info:
                desc += f" {len(info['freqs_hz'])} 音"
            desc += f" {spec.amp_dbfs:.1f} dBFS"
            self._set_wave(ch, y, desc)
            if info.get("clipped"):
                self._msg(f"CH{ch}：幅度加偏置超过满量程，已限幅")
        self.ch_table.selectRow(targets[0] if isinstance(targets, list) else 0)
        self._refresh_tx_choice(targets[0] if isinstance(targets, list) else 0)
        if not self._continuous_on():
            self._set_view("tx")
        self._msg(f"已生成：{desc}（{len(y)} 点）→ " + ("全部通道" if len(targets) == 8 else f"CH{targets[0]}"))
        self._auto_download()

    def _auto_download(self):
        if self.auto_dl_cb.isChecked() and self.connected:
            self._download()

    def _set_wave(self, ch: int, y: np.ndarray, desc: str):
        self.waves[ch] = {"y": np.asarray(y, dtype=np.float64), "desc": desc}
        self.ch_table.item(ch, 0).setText(desc)
        peak = float(np.max(np.abs(y))) if len(y) else 0.0
        self.ch_table.item(ch, 1).setText(f"{20 * np.log10(max(peak, 1e-9)):.1f} dBFS")
        self.ch_table.item(ch, 2).setText(str(len(y)))
        self.ch_checks[ch].setToolTip(f"{desc} · {len(y)} 点")
        if not self.ch_checks[ch].isChecked():
            self.ch_checks[ch].setChecked(True)
        self._update_src_label()
        self._update_preview()
        self._refresh_tx_choice(ch)
        self._update_steps()

    def _update_src_label(self):
        lines = [f"DAC{ch}：{self.waves[ch]['desc']}（{len(self.waves[ch]['y']):,} 点）"
                 for ch in range(8) if ch in self.waves and self.enabled[ch]]
        self.src_label.setText("\n".join(lines) if lines else "尚未生成或导入发射波形（或没有选中输出通道）。")

    def _set_enabled(self, ch: int, on: bool):
        self.enabled[ch] = on
        self._update_tx_limit()
        self._update_src_label()
        self._update_steps()

    def _update_tx_limit(self):
        """TX length limit: V2.1 pools banks by TX channel count, and the loop must fit twice into a
        capture of the selected ADC channels (doc/04 §4). Older bitstreams: 131072 points."""
        n_tx = sum(1 for on in self.enabled if on) or 1
        abi = int(self.device_status.get("abi", 0))
        if abi >= 0x00050000:
            slots = 1
            while slots < n_tx:
                slots <<= 1
            tx_max = (8 // slots) * wf.TX_MAX_SAMPLES
            by_rx = int((self.capture_limit - CAPTURE_MARGIN) * wf.DAC_FS_HZ / ADC_FS / 2) // 32 * 32
            self.tx_limit = max(32, min(tx_max, by_rx))
            why = (f"{n_tx} 路输出最多 {tx_max:,} 点" if self.tx_limit == tx_max
                   else f"受采集 2 倍时长限制（采集最多 {self.capture_limit:,} 点）")
        else:
            self.tx_limit = wf.TX_MAX_SAMPLES
            why = "此版本 FPGA 每通道最多 131072 点"
        self._tx_limit_note = f"最长 {self.tx_limit:,} 点（{self.tx_limit / wf.DAC_FS_HZ * 1e6:.1f} µs，{why}）"
        if hasattr(self, "tx_info"):
            self.tx_info.setText(f"DAC 9.8 GS/s 实数样点 · {n_tx} 路输出 · {self._tx_limit_note}")
        if hasattr(self, "std_len"):
            value = min(self.std_len.value(), self.tx_limit)
            self.std_len.blockSignals(True)
            self.std_len.setRange(32, self.tx_limit)
            self.std_len.setValue(value - value % 32)
            self.std_len.blockSignals(False)
            self._update_actual_freq()

    def _selected_ch(self) -> int:
        rows = self.ch_table.selectionModel().selectedRows()
        return rows[0].row() if rows else 0

    def _update_preview(self):
        ch = self._selected_ch()
        wave = self.waves.get(ch)
        self.preview_curve.setPen(pg.mkPen(CH_COLORS[ch], width=1))
        if wave is None:
            self.preview_curve.setData([], [])
            return
        y = wave["y"]
        t = np.arange(len(y)) / wf.DAC_FS_HZ
        self.preview_curve.setData(t, y)
        self.preview.setXRange(0, min(len(y), 2048) / wf.DAC_FS_HZ, padding=0)

    # ------------------------------------------------------------------ import
    def _pick_file_and_show(self):
        self.left_tabs.setCurrentIndex(1)
        self._pick_file()

    def _pick_file(self):
        start = self.settings.value("last_dir", str(Path.home()))
        path, _ = QFileDialog.getOpenFileName(self, "选择波形文件", start,
                                              "波形文件 (*.npy *.csv *.txt *.dat *.mat);;所有文件 (*)")
        if path:
            self._load_import(path)

    def _pick_dir(self):
        start = self.settings.value("last_dir", str(Path.home()))
        path = QFileDialog.getExistingDirectory(self, "选择 hex 目录（waveform.meta + chN.hex）", start)
        if path:
            self._load_import(path)

    def _load_import(self, path: str):
        try:
            data = importers.load_file(path)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.warning(self, "导入失败", str(exc))
            return
        self.settings.setValue("last_dir", str(Path(path).parent if Path(path).is_file() else path))
        self._imported = data
        self.imp_list.clear()
        for name, arr in data.items():
            item = QListWidgetItem(f"{name}  ·  {len(arr)} 点 · 峰值 {np.max(np.abs(arr)):.4g}")
            item.setData(Qt.UserRole, name)
            self.imp_list.addItem(item)
        if self.imp_list.count():
            self.imp_list.item(0).setSelected(True)
        self.imp_path.setText(path)
        self._msg(f"已读取 {Path(path).name}：{len(data)} 个变量/列")

    def _import_selected(self):
        items = self.imp_list.selectedItems()
        if not items:
            self._msg("先选择要导入的变量或列", error=True)
            return
        start = self.imp_start.currentIndex()
        notes = []
        for i, item in enumerate(items):
            ch = start + i
            if ch > 7:
                notes.append("超出 CH7 的列已忽略")
                break
            name = item.data(Qt.UserRole)
            y, scale_note = importers.scale(self._imported[name], self.imp_scale.currentData())
            y, len_note = wf.fit_length(y, self.imp_len.currentData(), self.tx_limit)
            self._set_wave(ch, y, f"导入 {name}")
            notes.append(f"CH{ch} ← {name}（{scale_note}{'；' + len_note if len_note else ''}）")
        self._msg("；".join(notes))
        self._refresh_tx_choice(start)
        if not self._continuous_on():
            self._set_view("tx")
        self._auto_download()

    # ------------------------------------------------------------------ download
    def _download_and_capture(self):
        self._capture_after_download = bool(self._download())

    def _download(self) -> bool:
        if not self.connected:
            self._msg("未连接", error=True)
            return False
        chans = [ch for ch in range(8) if self.enabled[ch]]
        missing = [ch for ch in chans if ch not in self.waves]
        if not chans:
            self._msg("没有选中输出通道", error=True)
            return False
        if missing:
            self._msg("这些通道选中了输出但没有波形：" + ", ".join(f"DAC{c}" for c in missing), error=True)
            return False
        lengths = {len(self.waves[ch]["y"]) for ch in chans}
        if len(lengths) != 1:
            self._msg("所有输出通道的波形长度必须相同：" +
                      ", ".join(f"DAC{c}={len(self.waves[c]['y'])}" for c in chans), error=True)
            return False
        self._update_tx_limit()
        if lengths.pop() > self.tx_limit:
            self._msg(f"波形长度超过上限：{self._tx_limit_note}", error=True)
            return False
        payload = {ch: wf.quantize(self.waves[ch]["y"]) for ch in chans}
        mask = sum(1 << ch for ch in chans)
        self.worker.cancel.clear()
        self.dl_info.setText("下载中…")
        self.dl_info.setStyleSheet(f"color:{sty.BUSY}")
        self._start_progress("④ 下载" + ("并校验" if self.verify_cb.isChecked() else ""))
        self.req_download.emit(payload, mask, self.verify_cb.isChecked())
        return True

    def _on_downloaded(self, r: dict):
        self._downloaded_once = True
        self._progress_idle()
        crc = "，CRC 全部一致" if r["verified"] else "（未校验）"
        run = self.auto_run_cb.isChecked()
        text = (f"已下载 {len(r['channels'])} 个通道 × {r['samples']} 点，{r['bytes'] / 1024:.0f} KiB，"
                f"共 {r['seconds'] * 1e3:.0f} ms，其中数据写入 {r['write_s'] * 1e3:.0f} ms"
                f"（{r['data_mb_s']:.1f} MB/s，{r['data_mb_s'] * 8 / 1000:.3f} Gb/s）{crc}。"
                + ("已自动输出 Run。" if run else "点「输出 Run」开始播放。"))
        # doc/04 §4: capture at least twice the TX loop so one whole period is always inside.
        need = capture_samples_for_tx(int(r["samples"]), self.capture_limit)
        if self.cap_len.value() < need:
            self.cap_len.setValue(need)
            text += f" 采集长度已设为 {need:,} 点（≥ 2 倍输出周期）。"
        self.dl_info.setText(text)
        self.dl_info.setStyleSheet("color:#3B6D11")
        self._msg(text)
        if run or self._capture_after_download:
            self._set_output(True)
        else:
            self.req_release.emit()
        if self._capture_after_download:
            self._capture_after_download = False
            QTimer.singleShot(0, self._capture_single)      # queued after Run in the worker
        self._update_steps()

    # ================================================================== capture
    def _capture_args(self) -> dict:
        mask = sum(1 << ch for ch, cb in enumerate(self.adc_checks) if cb.isChecked())
        n = min(self.cap_len.value(), self.capture_limit)
        n -= n % 24
        return {"trigger": self.trig_combo.currentData(), "mask": mask or 1, "samples": max(n, 24),
                "window": self.win_combo.currentData()}

    def _push_capture_args(self, *_):
        self._update_capture_limit()
        if self.cont_btn.isChecked():
            self.req_cap_args.emit(self._capture_args())

    def _capture_single(self):
        if not self.connected:
            self._msg("未连接", error=True)
            return
        self.cont_btn.setChecked(False)
        self._set_view("capture")
        self.req_cap_once.emit(self._capture_args())

    def _capture_continuous(self, on: bool):
        if on and not self.connected:
            self._msg("未连接", error=True)
            self.cont_btn.blockSignals(True)
            self.cont_btn.setChecked(False)
            self.cont_btn.blockSignals(False)
            return
        self.cont_btn.setText("停止连续采集" if on else "连续采集")
        if on:
            self._set_view("capture")
            self.req_cap_start.emit(self._capture_args())
        else:
            self.req_cap_stop.emit()

    def _on_captured(self, d: dict):
        # Continuous capture can deliver frames faster than they are drawn: keep only the newest one and
        # draw it once the queued signals are handled, so the display never lags behind a backlog.
        if getattr(self, "_pending_capture", None) is not None:
            self._dropped_frames = getattr(self, "_dropped_frames", 0) + 1
        self._pending_capture = d
        if not getattr(self, "_draw_scheduled", False):
            self._draw_scheduled = True
            QTimer.singleShot(0, self._draw_pending_capture)

    def _draw_pending_capture(self):
        self._draw_scheduled = False
        d, self._pending_capture = self._pending_capture, None
        if d is None:
            return
        t_start = time.perf_counter()
        wait_s = t_start - d["emit_t"] if "emit_t" in d else None
        self._show_capture(d)
        # Paint now (not on a later UpdateRequest) so the time below includes painting and the worker
        # only starts the next capture after this frame is on screen.
        self.time_plot.repaint()
        self.spec_plot.repaint()
        draw_s = time.perf_counter() - t_start
        period = t_start - getattr(self, "_last_frame_t", 0.0)
        self._last_frame_t = t_start
        self.frame_shown.emit()
        parts = [f"耗时 | 采集 {d['capture_s'] * 1e3:5.1f} ms"]
        if d.get("control_s") is not None:
            parts[-1] += f"（控制 {d['control_s'] * 1e3:4.1f} + 读回 {d['read_s'] * 1e3:4.1f}）"
        if d.get("process_s") is not None:
            parts.append(f"FFT/测量 {d['process_s'] * 1e3:5.1f} ms")
            if d.get("process_cpu_s") is not None:
                parts[-1] += f"（CPU {d['process_cpu_s'] * 1e3:5.1f}）"
        if wait_s is not None:
            parts.append(f"等待界面 {wait_s * 1e3:5.1f} ms")
        parts.append(f"界面更新(含绘制) {draw_s * 1e3:5.1f} ms")
        if period < 2.0:
            parts.append(f"刷新 {1.0 / period:5.1f} 帧/s")
        dropped = getattr(self, "_dropped_frames", 0)
        if dropped:
            parts.append(f"跳过旧帧 {dropped}")
        self._timing_text = " | ".join(parts)
        now = time.monotonic()
        if self._view() == "capture" and (not self._continuous_on() or now - self._facts_t >= FACTS_MIN_INTERVAL_S):
            self._facts_t = now
            self.facts.setText(self._capture_message + "\n" + self._timing_text)


    def _show_capture(self, d: dict):
        self.last_capture = d
        if self._prog_task is not None:
            self._progress_idle()
        self._redraw_time()
        for ch in range(8):
            if ch in d["spectra"]:
                f, db = d["spectra"][ch]
                self.spec_curves[ch].setData(f, db)
            else:
                self.spec_curves[ch].setData([], [])
        chans = sorted(d["samples"])
        if self.meas_ch.currentIndex() not in chans and chans:
            self.meas_ch.blockSignals(True)
            self.meas_ch.setCurrentIndex(chans[0])
            self.meas_ch.blockSignals(False)
        if not getattr(self, "_span_applied", False):
            self._apply_span()
            self._span_applied = True
        self._refresh_meas()
        rate = d["count"] * 2 * len(chans) / max(d["read_s"], 1e-9) / 1e6
        self.cards["acq"].setText(f"{d['total_s'] * 1e3:.0f} ms")
        analysis_note = f" · FFT/测量取开头 {d.get('analysis_points', d['count']):,} 点" if d.get("analysis_limited") else ""
        trig = "AWG 起播同步" if d["trigger"] == "start" else "手动"
        self._capture_message = (
            f"采集 | {d['count']:>9,} 点 × {len(chans)} 通道 | 触发 {trig} | Fs 5.000 GS/s | "
            f"读回 {rate * 8 / 1000:6.3f} Gb/s | RBW {d['rbw_hz'] / 1e3:9.3f} kHz | cap_tx_word {d['cap_tx_word']:>6}"
            f"{analysis_note}")
        if d.get("offline"):
            self._capture_message = (f"本地记录 | {d['count']:,} 点 × {len(chans)} 通道 | Fs 5.000 GS/s"
                                     f" | RBW {d['rbw_hz'] / 1e3:.3f} kHz{analysis_note}")
        if self._view() == "capture":
            self._capture_titles()
            if not self._continuous_on() or time.monotonic() - self._facts_t >= FACTS_MIN_INTERVAL_S:
                self.facts.setText(self._capture_message)
        self._update_steps()

    def _continuous_on(self) -> bool:
        return self.cont_btn.isChecked()

    def _redraw_time(self, *_):
        d = self.last_capture
        if d is None:
            return
        fs_units = self.yunit.currentData() == "fs"
        capture_view = self._view() == "capture"
        if capture_view:
            self.time_plot.setLabel("left", "满量程" if fs_units else "14 bit 码值")
            self.legend.clear()
            for ch in sorted(d["samples"]):
                self.legend.addItem(self.time_curves[ch], f"ADC{ch}")
        n = 0
        for ch in range(8):
            y = d["samples"].get(ch)
            if y is None:
                self.time_curves[ch].setData([], [])
                continue
            yy = y.astype(np.float32) / (32768.0 if fs_units else 4.0)
            t = np.arange(len(yy), dtype=np.float64) / ADC_FS
            self.time_curves[ch].setData(t, yy)
            n = max(n, len(yy))
        # With clipToView + peak downsampling the curve draws nothing until the x range is near the
        # data (13 us vs the default 0..1 s), so set the range explicitly instead of relying on auto-range.
        if n and not self._time_user_zoom and capture_view:
            self._time_full_range(n)

    def _time_full_range(self, n: int | None = None, whole: bool = False):
        """Like a scope's auto-set: ~10 periods of the measured tone; whole=True shows the full record."""
        d = self.last_capture
        if n is None:
            n = d["count"] if d else 0
        if not n:
            return
        span = n / ADC_FS
        if not whole and d is not None:
            m = d["meas"].get(self.meas_ch.currentIndex()) or next(iter(d["meas"].values()), {})
            f = m.get("freq_hz", 0.0)
            if f > 0:
                span = min(span, max(10.0 / f, 50e-9))
        self._time_setting_range = True
        self.time_plot.setXRange(0, span, padding=0)
        self.time_plot.enableAutoRange(axis="y")
        self._time_setting_range = False

    def _time_whole(self):
        if self._view() == "tx":
            self.tx_win_combo.setCurrentIndex(len(TX_WINDOWS) - 1)
            return
        self._time_user_zoom = True                      # keep the full view on later captures
        self._time_full_range(whole=True)

    def _on_time_zoom(self, *_):
        if not self._time_setting_range:
            self._time_user_zoom = True

    def _time_auto(self):
        if self._view() == "tx":
            self.tx_win_combo.setCurrentIndex(0)
            self._draw_tx_preview(reset=True)
            return
        self._time_user_zoom = False
        self._time_full_range()

    def _refresh_meas(self, *_):
        d = self.last_capture
        ch = self.meas_ch.currentIndex()
        if d is None or ch not in d["meas"]:
            for key in self.cards:
                if key != "acq":
                    self.cards[key].setText("—")
            self.m1_line.setVisible(False)
            self.m1_text.setVisible(False)
            return
        m = d["meas"][ch]
        self.cards["freq"].setText(_fmt_hz(m["freq_hz"]) if "freq_hz" in m else "—")
        self.cards["level"].setText(f"{m['peak_dbfs']:.2f} dBFS" if "peak_dbfs" in m else "—")
        self.cards["vpp"].setText(f"{m['vpp_lsb'] / 4:.0f}")
        self.cards["rms"].setText(f"{m['rms_lsb'] / 4:.1f}")
        self.cards["sfdr"].setText(f"{m['sfdr_dbc']:.1f} dBc" if "sfdr_dbc" in m else "—")
        self.cards["sinad"].setText(f"{m['sinad_db']:.1f} dB" if "sinad_db" in m else "—")
        self.cards["snr"].setText(f"{m['snr_db']:.1f} dB" if "snr_db" in m else "—")
        if "freq_hz" in m:
            self.m1_line.setPos(m["freq_hz"])
            self.m1_text.setPos(m["freq_hz"], m["peak_dbfs"])
            self.m1_text.setText(f" M1 {_fmt_hz(m['freq_hz'])}  {m['peak_dbfs']:.2f} dBFS")
            self.m1_line.setVisible(self._view() == "capture")
            self.m1_text.setVisible(self._view() == "capture")
        self._update_m2()

    def _toggle_m2(self, on: bool):
        if on:
            self.m2_line.setPos(self.center.value() * 1e6)
        self.m2_line.setVisible(on and self._view() == "capture")
        self.m2_text.setVisible(on and self._view() == "capture")
        self._update_m2()

    def _update_m2(self, *_):
        if not self.m2_cb.isChecked() or self.last_capture is None:
            return
        ch = self.meas_ch.currentIndex()
        spec = self.last_capture["spectra"].get(ch)
        if spec is None:
            return
        f, db = spec
        x = float(self.m2_line.value())
        i = int(np.clip(np.searchsorted(f, x), 0, len(f) - 1))
        level = float(db[i])
        text = f" M2 {_fmt_hz(f[i])}  {level:.2f} dBFS"
        m = self.last_capture["meas"].get(ch, {})
        if "freq_hz" in m:
            text += f"\n ΔM2-M1 {_fmt_hz(f[i] - m['freq_hz'])}  {level - m['peak_dbfs']:.2f} dB"
        self.m2_text.setText(text)
        ylo, yhi = self.spec_plot.viewRange()[1]
        self.m2_text.setPos(x, ylo + 0.18 * (yhi - ylo))       # lower part, away from the M1 label

    def _apply_span(self, *_):
        if self._view() != "capture":
            return
        c = self.center.value() * 1e6
        s = self.span.value() * 1e6
        self.spec_plot.setXRange(max(c - s / 2, 0), min(c + s / 2, ADC_FS / 2), padding=0)

    def _load_capture(self):
        if self.cont_btn.isChecked():
            self._msg("请先停止连续采集，再打开记录", error=True)
            return
        path, _ = QFileDialog.getOpenFileName(self, "打开采集记录（CSV + 同名 JSON）",
            self.settings.value("last_dir", str(Path.home())), "CSV (*.csv)")
        if path:
            self._set_view("capture")
            self.req_load_capture.emit(path, self.win_combo.currentData())

    def _save_capture(self):
        d = self.last_capture
        if d is None:
            self._msg("还没有采集数据", error=True)
            return
        start = self.settings.value("last_dir", str(Path.home()))
        path, _ = QFileDialog.getSaveFileName(self, "保存采集数据", str(Path(start) / "capture.csv"), "CSV (*.csv)")
        if not path:
            return
        chans = sorted(d["samples"])
        arr = np.column_stack([d["samples"][ch] for ch in chans])
        np.savetxt(path, arr, fmt="%d", delimiter=",", header=",".join(f"ADC{c}" for c in chans), comments="")
        meta = {"format": "47dr-raw-adc-v2", "fs_hz": ADC_FS, "channel_mask": sum(1 << c for c in chans),
                "channels": chans, "samples": int(d["count"]), "sample_bits": 14, "signed": True,
                "container": "int16 left-aligned (low 2 bits zero)", "trigger": d["trigger"],
                "cap_tx_word": int(d["cap_tx_word"]),
                "measurements": {f"ADC{c}": d["meas"][c] for c in chans}}
        Path(path).with_suffix(".json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n",
                                                   encoding="utf-8")
        self.settings.setValue("last_dir", str(Path(path).parent))
        self._msg(f"已保存 {path}（及同名 .json）")
