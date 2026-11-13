"""Main window: instrument-style AWG (left) + oscilloscope / spectrum analyzer (right)."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

import numpy as np
import pyqtgraph as pg
from PySide6.QtCore import QSettings, Qt, QThread, Signal
from PySide6.QtGui import QAction, QColor, QFont
from PySide6.QtWidgets import (
    QAbstractItemView, QCheckBox, QComboBox, QDockWidget, QDoubleSpinBox, QFileDialog, QFormLayout,
    QFrame, QGridLayout, QGroupBox, QHBoxLayout, QHeaderView, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QMainWindow, QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QSpinBox,
    QSplitter, QTableWidget, QTableWidgetItem, QTabWidget, QVBoxLayout, QWidget,
)

from . import importers, measure, waveforms as wf
from .programmer import BoardProgrammer, default_package, find_xsct, missing_package_files
from .worker import DeviceWorker

APP_VERSION = "V1.2"            # V1 release line (branch v1-release); V2 is developed on eth40g
READY_TIMEOUT_S = 120.0          # program.tcl returns before RFDC/MTS init finishes on the PS

CH_COLORS = ["#378ADD", "#D85A30", "#1D9E75", "#BA7517", "#7F77DD", "#D4537E", "#639922", "#888780"]
ADC_FS = measure.ADC_FS_HZ
CAP_MAX = 65520

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


def _fmt_hz(hz: float) -> str:
    for unit, scale in (("GHz", 1e9), ("MHz", 1e6), ("kHz", 1e3)):
        if abs(hz) >= scale:
            return f"{hz / scale:.6f} {unit}"
    return f"{hz:.3f} Hz"


class MainWindow(QMainWindow):
    req_connect = Signal(str, int, int)
    req_connect_ready = Signal(str, int, int, float)
    req_close = Signal()
    req_download = Signal(object, int, bool)
    req_output = Signal(bool)
    req_cap_once = Signal(dict)
    req_cap_start = Signal(dict)
    req_cap_stop = Signal()
    req_cap_args = Signal(dict)
    req_abort = Signal()

    def __init__(self, default_ip: str = "192.168.42.2", default_port: int = 9100):
        super().__init__()
        self.setWindowTitle(f"47DR AWG / 示波器 — 40GbE 光口  {APP_VERSION}")
        self.settings = QSettings(str(Path(os.environ.get("APPDATA", ".")) / "awg_gui_v1" / "settings.ini"),
                                  QSettings.IniFormat)
        self.waves: dict[int, dict] = {}          # ch -> {"y": float array, "desc": str}
        self.enabled = [False] * 8
        self.last_capture: dict | None = None
        self.connected = False
        self.running = False
        self._busy = False

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
        self.req_connect_ready.connect(self.worker.connect_when_ready)
        self.req_close.connect(self.worker.close_device)
        self.req_download.connect(self.worker.download)
        self.req_output.connect(self.worker.set_output)
        self.req_cap_once.connect(self.worker.capture_once)
        self.req_cap_start.connect(self.worker.capture_start)
        self.req_cap_stop.connect(self.worker.capture_stop)
        self.req_cap_args.connect(self.worker.update_capture_args)
        self.req_abort.connect(self.worker.abort_capture)
        self.worker.connected.connect(self._on_connected)
        self.worker.disconnected.connect(self._on_disconnected)
        self.worker.status.connect(self._on_status)
        self.worker.progress.connect(self._on_progress)
        self.worker.downloaded.connect(self._on_downloaded)
        self.worker.captured.connect(self._on_captured)
        self.worker.failed.connect(self._on_failed)
        self.worker.log.connect(self._log)
        self.worker.busy.connect(self._on_busy)
        self.thread.start()

    # ================================================================== UI
    def _build_ui(self, ip, port):
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(6, 6, 6, 6)
        root.addWidget(self._build_topbar(ip, port))
        split = QSplitter(Qt.Horizontal)
        split.addWidget(self._build_awg_panel())
        split.addWidget(self._build_scope_panel())
        split.setStretchFactor(0, 0)
        split.setStretchFactor(1, 1)
        split.setSizes([380, 1100])
        root.addWidget(split, 1)
        self.setCentralWidget(central)

        self.log_view = QPlainTextEdit(readOnly=True)
        self.log_view.setMaximumBlockCount(2000)
        dock = QDockWidget("日志", self)
        dock.setWidget(self.log_view)
        dock.setObjectName("log_dock")
        self.addDockWidget(Qt.BottomDockWidgetArea, dock)
        dock.hide()
        self.log_dock = dock
        self._build_device_menu()
        view_menu = self.menuBar().addMenu("视图")
        view_menu.addAction(dock.toggleViewAction())
        act = QAction("清空日志", self)
        act.triggered.connect(self.log_view.clear)
        view_menu.addAction(act)

        self.progress = QProgressBar()
        self.progress.setMaximumWidth(260)
        self.progress.setTextVisible(True)
        self.progress.hide()
        self.statusBar().addPermanentWidget(self.progress)
        self.statusBar().showMessage("未连接。请先用 program.tcl 初始化板卡，再点「连接」。")

    def _build_topbar(self, ip, port):
        bar = QFrame()
        bar.setFrameShape(QFrame.StyledPanel)
        h = QHBoxLayout(bar)
        h.setContentsMargins(8, 4, 8, 4)
        h.addWidget(QLabel("FPGA IP"))
        self.ip_edit = QLineEdit(ip)
        self.ip_edit.setFixedWidth(120)
        h.addWidget(self.ip_edit)
        h.addWidget(QLabel("端口"))
        self.port_spin = QSpinBox()
        self.port_spin.setRange(1, 65535)
        self.port_spin.setValue(port)
        h.addWidget(self.port_spin)
        h.addWidget(QLabel("每包字数"))
        self.wpp_combo = QComboBox()
        self.wpp_combo.addItems(["2048", "1024", "350", "256"])
        self.wpp_combo.setToolTip("D3C 位流支持 2048（需 PC 网卡 MTU 9000）；D3B 位流最多 350")
        h.addWidget(self.wpp_combo)
        self.connect_btn = QPushButton("连接")
        self.connect_btn.clicked.connect(self._toggle_connect)
        h.addWidget(self.connect_btn)
        self.conn_label = QLabel("● 未连接")
        self.conn_label.setStyleSheet("color:#888780")
        h.addWidget(self.conn_label)
        self.info_label = QLabel("DAC 9.8 GS/s · ADC 5 GS/s")
        self.info_label.setStyleSheet("color:#5F5E5A")
        h.addWidget(self.info_label)
        h.addStretch(1)
        self.state_label = QLabel("")
        h.addWidget(self.state_label)
        self.run_btn = QPushButton("▶ 输出 Run")
        self.run_btn.clicked.connect(lambda: self._set_output(True))
        self.stop_btn = QPushButton("■ 输出 Stop")
        self.stop_btn.clicked.connect(lambda: self._set_output(False))
        self.single_btn = QPushButton("采集 Single")
        self.single_btn.clicked.connect(self._capture_single)
        self.cont_btn = QPushButton("采集 Run")
        self.cont_btn.setCheckable(True)
        self.cont_btn.toggled.connect(self._capture_continuous)
        for b in (self.run_btn, self.stop_btn, self.single_btn, self.cont_btn):
            b.setMinimumWidth(96)
            h.addWidget(b)
        return bar

    # ------------------------------------------------------------------ AWG side
    def _build_awg_panel(self):
        panel = QWidget()
        v = QVBoxLayout(panel)
        v.setContentsMargins(0, 0, 0, 0)
        tabs = QTabWidget()
        tabs.addTab(self._build_std_tab(), "标准波形")
        tabs.addTab(self._build_import_tab(), "导入波形")
        v.addWidget(tabs)
        v.addWidget(self._build_download_bar())

        box = QGroupBox("AWG 通道")
        bv = QVBoxLayout(box)
        self.ch_table = QTableWidget(8, 4)
        self.ch_table.setHorizontalHeaderLabels(["输出", "波形", "峰值", "点数"])
        self.ch_table.setVerticalHeaderLabels([f"CH{i}" for i in range(8)])
        hdr = self.ch_table.horizontalHeader()
        for col in (0, 2, 3):
            hdr.setSectionResizeMode(col, QHeaderView.ResizeToContents)
        hdr.setSectionResizeMode(1, QHeaderView.Stretch)
        self.ch_table.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.ch_table.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.ch_table.setWordWrap(False)
        self.ch_table.setTextElideMode(Qt.ElideRight)
        self.ch_table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.ch_table.setSelectionMode(QAbstractItemView.SingleSelection)
        self.ch_table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.ch_checks = []
        for ch in range(8):
            cb = QCheckBox()
            cb.toggled.connect(lambda on, c=ch: self._set_enabled(c, on))
            cell = QWidget()
            lay = QHBoxLayout(cell)
            lay.setContentsMargins(6, 0, 0, 0)
            lay.addWidget(cb)
            self.ch_table.setCellWidget(ch, 0, cell)
            self.ch_checks.append(cb)
            for col in (1, 2, 3):
                self.ch_table.setItem(ch, col, QTableWidgetItem("—"))
        row_h = self.ch_table.fontMetrics().height() + 8
        self.ch_table.verticalHeader().setDefaultSectionSize(row_h)
        self.ch_table.verticalHeader().setSectionResizeMode(QHeaderView.Fixed)
        self.ch_table.setFixedHeight(8 * row_h + self.ch_table.horizontalHeader().sizeHint().height() + 4)
        self.ch_table.itemSelectionChanged.connect(self._update_preview)
        bv.addWidget(self.ch_table)
        self.preview = pg.PlotWidget()
        self.preview.setMinimumHeight(120)
        self.preview.setLabel("bottom", "时间", units="s")
        self.preview.showGrid(x=True, y=True, alpha=0.25)
        self.preview.setYRange(-1.05, 1.05)
        self.preview.setMouseEnabled(x=True, y=False)
        self.preview_curve = self.preview.plot(pen=pg.mkPen(CH_COLORS[0], width=1))
        self.preview_curve.setDownsampling(auto=True, method="peak")
        self.preview_curve.setClipToView(True)
        bv.addWidget(QLabel("预览（选中通道，满量程 ±1）"))
        bv.addWidget(self.preview)
        v.addWidget(box, 1)
        panel.setMinimumWidth(340)
        return panel

    def _build_std_tab(self):
        w = QWidget()
        f = QFormLayout(w)
        self.std_target = QComboBox()
        self.std_target.addItems([f"CH{i}" for i in range(8)] + ["全部通道"])
        f.addRow("目标通道", self.std_target)
        self.std_kind = QComboBox()
        for k in wf.KINDS:
            self.std_kind.addItem(wf.KIND_LABELS[k], k)
        self.std_kind.currentIndexChanged.connect(self._update_kind_rows)
        f.addRow("函数", self.std_kind)
        self.std_freq = _mhz_spin(100.0)
        self.std_freq.valueChanged.connect(self._update_actual_freq)
        f.addRow("频率", self.std_freq)
        self.std_actual = QLabel("")
        self.std_actual.setStyleSheet("color:#5F5E5A")
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
        self.std_len_info = QLabel("")
        self.std_len_info.setStyleSheet("color:#5F5E5A")
        f.addRow("", self.std_len_info)
        btn = QPushButton("生成到通道")
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
        row = QHBoxLayout()
        b1 = QPushButton("选择文件…")
        b1.clicked.connect(self._pick_file)
        b2 = QPushButton("选择 hex 目录…")
        b2.clicked.connect(self._pick_dir)
        row.addWidget(b1)
        row.addWidget(b2)
        v.addLayout(row)
        self.imp_path = QLabel("支持 .npy / .csv / .txt / .mat / v1 hex 目录")
        self.imp_path.setWordWrap(True)
        self.imp_path.setStyleSheet("color:#5F5E5A")
        v.addWidget(self.imp_path)
        self.imp_list = QListWidget()
        self.imp_list.setSelectionMode(QAbstractItemView.ExtendedSelection)
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
        self.imp_start.addItems([f"CH{i}" for i in range(8)])
        f.addRow("起始通道", self.imp_start)
        v.addLayout(f)
        btn = QPushButton("导入到通道")
        btn.clicked.connect(self._import_selected)
        v.addWidget(btn)
        self._imported: dict[str, np.ndarray] = {}
        return w

    def _build_download_bar(self):
        """Always-visible download controls (not inside a tab)."""
        box = QGroupBox("下载 / 输出")
        g = QGridLayout(box)
        g.setContentsMargins(8, 6, 8, 6)
        self.dl_btn = QPushButton("⬇ 下载到 AWG")
        self.dl_btn.setMinimumHeight(30)
        self.dl_btn.setStyleSheet("QPushButton { font-weight:bold; }")
        self.dl_btn.setToolTip("把「输出」列勾选的通道下载到 FPGA（下载时会先停止播放）")
        self.dl_btn.clicked.connect(self._download)
        cancel = QPushButton("取消")
        cancel.clicked.connect(self.worker.cancel.set)
        g.addWidget(self.dl_btn, 0, 0, 1, 2)
        g.addWidget(cancel, 0, 2)
        self.auto_dl_cb = QCheckBox("生成/导入后自动下载")
        self.auto_dl_cb.setChecked(True)
        self.auto_run_cb = QCheckBox("下载后自动 Run")
        self.auto_run_cb.setChecked(True)
        self.verify_cb = QCheckBox("CRC 校验")
        self.verify_cb.setChecked(True)
        self.verify_cb.setToolTip("下载后逐通道比对 FPGA 计算的 CRC（推荐保留）")
        g.addWidget(self.auto_dl_cb, 1, 0)
        g.addWidget(self.auto_run_cb, 1, 1)
        g.addWidget(self.verify_cb, 1, 2)
        self.dl_info = QLabel("勾选下表「输出」列选择播放通道；所有启用通道的波形长度必须相同。")
        self.dl_info.setWordWrap(True)
        self.dl_info.setStyleSheet("color:#5F5E5A")
        g.addWidget(self.dl_info, 2, 0, 1, 3)
        return box

    # ------------------------------------------------------------------ scope side
    def _build_scope_panel(self):
        panel = QWidget()
        v = QVBoxLayout(panel)
        v.setContentsMargins(0, 0, 0, 0)
        v.addWidget(self._build_scope_controls())

        plots = QSplitter(Qt.Vertical)
        self.time_plot = pg.PlotWidget()
        self.time_plot.setLabel("bottom", "时间", units="s")
        self.time_plot.setLabel("left", "14 bit 码值")
        self.time_plot.showGrid(x=True, y=True, alpha=0.25)
        self.legend = self.time_plot.addLegend(offset=(-10, 10))
        self._time_user_zoom = False
        self._time_setting_range = False
        self.time_plot.getViewBox().sigRangeChangedManually.connect(self._on_time_zoom)
        self.spec_plot = pg.PlotWidget()
        self.spec_plot.setLabel("bottom", "频率", units="Hz")
        self.spec_plot.setLabel("left", "dBFS")
        self.spec_plot.showGrid(x=True, y=True, alpha=0.25)
        self.spec_plot.setYRange(-140, 5)
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
        box = QFrame()
        box.setFrameShape(QFrame.StyledPanel)
        g = QGridLayout(box)
        g.setContentsMargins(8, 4, 8, 4)
        g.addWidget(QLabel("触发"), 0, 0)
        self.trig_combo = QComboBox()
        self.trig_combo.addItem("手动（立即）", "manual")
        self.trig_combo.addItem("AWG 起播同步", "start")
        self.trig_combo.currentIndexChanged.connect(self._push_capture_args)
        g.addWidget(self.trig_combo, 0, 1)
        g.addWidget(QLabel("采集长度"), 0, 2)
        self.cap_len = QSpinBox()
        self.cap_len.setRange(24, CAP_MAX)
        self.cap_len.setSingleStep(24)
        self.cap_len.setValue(CAP_MAX)
        self.cap_len.setSuffix(" 点")
        self.cap_len.setKeyboardTracking(False)
        self.cap_len.valueChanged.connect(self._push_capture_args)
        g.addWidget(self.cap_len, 0, 3)
        g.addWidget(QLabel("窗函数"), 0, 4)
        self.win_combo = QComboBox()
        for k, label in measure.WINDOW_LABELS.items():
            self.win_combo.addItem(label, k)
        self.win_combo.currentIndexChanged.connect(self._push_capture_args)
        g.addWidget(self.win_combo, 0, 5)
        g.addWidget(QLabel("纵轴"), 0, 6)
        self.yunit = QComboBox()
        self.yunit.addItem("14 bit 码值", "code")
        self.yunit.addItem("满量程 (±1)", "fs")
        self.yunit.currentIndexChanged.connect(self._redraw_time)
        g.addWidget(self.yunit, 0, 7)
        save = QPushButton("保存数据…")
        save.clicked.connect(self._save_capture)
        g.addWidget(save, 0, 8)
        auto = QPushButton("时域自动")
        auto.setToolTip("时域图显示约 10 个周期并自动纵轴（类似示波器 Auto）")
        auto.clicked.connect(self._time_auto)
        g.addWidget(auto, 0, 9)
        whole = QPushButton("全长")
        whole.setToolTip("时域图显示整段采集记录")
        whole.clicked.connect(self._time_whole)
        g.addWidget(whole, 1, 9)

        g.addWidget(QLabel("ADC 通道"), 1, 0)
        chans = QHBoxLayout()
        self.adc_checks = []
        for ch in range(8):
            cb = QCheckBox(f"{ch}")
            cb.setStyleSheet(f"QCheckBox {{ color: {CH_COLORS[ch]}; }}")
            cb.setChecked(ch == 0)
            cb.toggled.connect(self._push_capture_args)
            chans.addWidget(cb)
            self.adc_checks.append(cb)
        g.addLayout(chans, 1, 1, 1, 3)
        g.addWidget(QLabel("测量通道"), 1, 4)
        self.meas_ch = QComboBox()
        self.meas_ch.addItems([f"ADC{i}" for i in range(8)])
        self.meas_ch.currentIndexChanged.connect(self._refresh_meas)
        g.addWidget(self.meas_ch, 1, 5)
        g.addWidget(QLabel("中心 / 跨度"), 1, 6)
        span_row = QHBoxLayout()
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
            span_row.addWidget(wdg)
        g.addLayout(span_row, 1, 7, 1, 2)
        return box

    def _build_meas_cards(self):
        box = QFrame()
        h = QHBoxLayout(box)
        h.setContentsMargins(0, 2, 0, 2)
        self.cards = {}
        for key, title in (("freq", "频率"), ("level", "幅度"), ("vpp", "Vpp (码值)"), ("rms", "RMS (码值)"),
                           ("sfdr", "SFDR"), ("sinad", "SINAD"), ("snr", "SNR"), ("acq", "采集")):
            card = QFrame()
            card.setStyleSheet("QFrame { background:#F1EFE8; border-radius:6px; }")
            cv = QVBoxLayout(card)
            cv.setContentsMargins(8, 4, 8, 4)
            t = QLabel(title)
            t.setStyleSheet("color:#5F5E5A; background:transparent;")
            val = QLabel("—")
            font = QFont()
            font.setPointSize(11)
            font.setBold(True)
            val.setFont(font)
            val.setStyleSheet("background:transparent;")
            cv.addWidget(t)
            cv.addWidget(val)
            h.addWidget(card, 1)
            self.cards[key] = val
        return box

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

    def _package_dir(self) -> str:
        saved = str(self.settings.value("fw_package", "") or "")
        if saved and not missing_package_files(saved):
            return saved
        return str(default_package())          # firmware/ next to the exe, or build/F1/package in the source tree

    def _choose_package(self):
        path = QFileDialog.getExistingDirectory(self, "选择固件包目录（含 bit/elf/psu_init.tcl/init_protocol.txt）",
                                                self._package_dir())
        if path:
            missing = missing_package_files(path)
            if missing:
                QMessageBox.warning(self, "固件包不完整", "缺少：" + "、".join(missing))
                return
            self.settings.setValue("fw_package", path)
            self._msg(f"固件包：{path}")

    def _choose_xsct(self):
        start = find_xsct(self.settings.value("xsct")) or ""
        path, _ = QFileDialog.getOpenFileName(self, "选择 xsct.bat", start, "XSCT (xsct.bat xsct.exe);;所有文件 (*)")
        if path:
            self.settings.setValue("xsct", path)
            self._msg(f"XSCT：{path}")

    def _choose_hw_server(self):
        from PySide6.QtWidgets import QInputDialog
        cur = str(self.settings.value("hw_server", ""))
        text, ok = QInputDialog.getText(self, "hw_server 地址",
                                        "留空 = 本机自动启动 hw_server；远程请填 host:3121", text=cur)
        if ok:
            self.settings.setValue("hw_server", text.strip())

    def _program_board(self, confirm: bool = True):
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
        self.log_dock.show()
        self.act_program.setEnabled(False)
        self.act_program_cancel.setEnabled(True)
        self.connect_btn.setEnabled(False)
        self.conn_label.setText("● 下载 bit / 初始化中…")
        self.conn_label.setStyleSheet("color:#BA7517")
        self._program_t0 = time.monotonic()
        self._msg("开始下载 bit 并初始化…")
        self.programmer.start(xsct, package, server)

    def _cancel_program(self):
        self.programmer.cancel()
        self.worker.cancel.set()            # also stops a running wait-for-ready

    def _on_program_finished(self, ok: bool, message: str):
        dt = time.monotonic() - getattr(self, "_program_t0", time.monotonic())
        if not ok:
            self.act_program.setEnabled(True)
            self.act_program_cancel.setEnabled(False)
            self.connect_btn.setEnabled(True)
            self.conn_label.setText("● 未连接")
            self.conn_label.setStyleSheet("color:#888780")
            self._msg(f"下载 bit / 初始化失败：{message}", error=True)
            QMessageBox.warning(self, "下载 bit / 初始化失败", message)
            return
        self._msg(f"{message}（{dt:.0f} s），等待板卡就绪…")
        self.conn_label.setText("● 等待板卡就绪…")
        self._waiting_ready = True
        self.req_connect_ready.emit(self.ip_edit.text().strip(), self.port_spin.value(),
                                    int(self.wpp_combo.currentText()), READY_TIMEOUT_S)

    def _end_program_wait(self, ok: bool):
        if not getattr(self, "_waiting_ready", False):
            return
        self._waiting_ready = False
        self.act_program.setEnabled(True)
        self.act_program_cancel.setEnabled(False)
        self.connect_btn.setEnabled(True)
        if ok:
            dt = time.monotonic() - self._program_t0
            self._msg(f"下载 bit 并初始化完成，已连接（共 {dt:.0f} s）")

    # ================================================================== settings
    def _restore(self):
        s = self.settings
        self.ip_edit.setText(s.value("ip", self.ip_edit.text()))
        self.port_spin.setValue(int(s.value("port", self.port_spin.value())))
        idx = self.wpp_combo.findText(str(s.value("wpp", "2048")))
        self.wpp_combo.setCurrentIndex(max(idx, 0))
        geo = s.value("geometry")
        if geo is not None:
            self.restoreGeometry(geo)

    def closeEvent(self, event):
        s = self.settings
        s.setValue("ip", self.ip_edit.text())
        s.setValue("port", self.port_spin.value())
        s.setValue("wpp", self.wpp_combo.currentText())
        s.setValue("geometry", self.saveGeometry())
        self.programmer.cancel()
        self.worker.cancel.set()
        self.req_cap_stop.emit()
        self.req_close.emit()
        self.thread.quit()
        self.thread.wait(3000)
        super().closeEvent(event)

    # ================================================================== logging / status
    def _log(self, text: str):
        line = time.strftime("%H:%M:%S ") + text.rstrip()
        self.log_view.appendPlainText(line)
        self._log_to_file(line)

    def _log_to_file(self, line: str):
        # Same text as the log dock, kept on disk for field debugging:
        # %APPDATA%\awg_gui_v1\logs\awg_gui_YYYYMMDD.log
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
        self.progress.hide()
        if op == "采集":
            self.cont_btn.blockSignals(True)
            self.cont_btn.setChecked(False)
            self.cont_btn.blockSignals(False)
        self._msg(f"{op}失败：{message}", error=True)
        if op == "连接":
            self._end_program_wait(False)
            self.conn_label.setText("● 未连接")
            self.conn_label.setStyleSheet("color:#888780")
        if op in ("连接", "下载"):
            QMessageBox.warning(self, f"{op}失败", message)

    def _on_busy(self, busy: bool):
        self._busy = busy
        self.setCursor(Qt.BusyCursor if busy else Qt.ArrowCursor)

    def _on_progress(self, text: str, done: int, total: int):
        self.progress.show()
        self.progress.setMaximum(max(total, 1))
        self.progress.setValue(done)
        self.progress.setFormat(f"{text}  %p%")
        if done >= total:
            self.progress.hide()

    # ================================================================== connection / output
    def _toggle_connect(self):
        if self.connected:
            self.cont_btn.setChecked(False)
            self.req_close.emit()
            return
        self.conn_label.setText("● 连接中…")
        self.conn_label.setStyleSheet("color:#BA7517")
        self.req_connect.emit(self.ip_edit.text().strip(), self.port_spin.value(), int(self.wpp_combo.currentText()))

    def _on_connected(self, info: dict):
        self.connected = True
        self.connect_btn.setText("断开")
        self.conn_label.setText("● 已连接")
        self.conn_label.setStyleSheet("color:#3B6D11")
        build = info.get("build_id_reg", 0)
        self.info_label.setText(f"DAC 9.8 GS/s · ADC 5 GS/s · BUILD 0x{build:08X}")
        self._on_status(info["status"])
        self._msg(f"已连接 {info['ip']}:{info['port']}（协议 {info.get('protocol_version')}，"
                  f"单包最多 {info.get('max_words')} 字）")
        self._end_program_wait(True)

    def _on_disconnected(self):
        self.connected = False
        self.connect_btn.setText("连接")
        self.conn_label.setText("● 未连接")
        self.conn_label.setStyleSheet("color:#888780")
        self.state_label.setText("")
        self._msg("已断开（断开不会停止 DAC 播放）")

    def _on_status(self, st: dict):
        self.running = bool(st.get("running"))
        parts = ["输出：运行中" if self.running else "输出：已停止"]
        if not st.get("ps_ready"):
            parts.append("PS 未就绪")
        if st.get("fault") or st.get("faults"):
            parts.append(f"故障 0x{st.get('faults', 0):02X}")
        mask = st.get("channel_mask", 0)
        parts.append(f"通道掩码 0x{mask:02X}")
        self.state_label.setText(" · ".join(parts))
        self.state_label.setStyleSheet("color:#3B6D11" if self.running else "color:#5F5E5A")
        self.run_btn.setStyleSheet("QPushButton { color:#3B6D11; font-weight:bold; }" if self.running else "")

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
        n = wf.valid_length(self.std_len.value())
        cycles, f_act = wf.snap_cycles(self.std_freq.value() * 1e6, n)
        self.std_actual.setText(f"{_fmt_hz(f_act)}（{cycles} 个周期 / {n} 点，步进 {_fmt_hz(wf.DAC_FS_HZ / n)}）")
        self.std_len_info.setText(f"循环周期 {n / wf.DAC_FS_HZ * 1e6:.3f} µs")

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
        self._msg(f"已生成：{desc}（{len(y)} 点）→ " + ("全部通道" if len(targets) == 8 else f"CH{targets[0]}"))
        self._auto_download()

    def _auto_download(self):
        if self.auto_dl_cb.isChecked() and self.connected:
            self._download()

    def _set_wave(self, ch: int, y: np.ndarray, desc: str):
        self.waves[ch] = {"y": np.asarray(y, dtype=np.float64), "desc": desc}
        self.ch_table.item(ch, 1).setText(desc)
        peak = float(np.max(np.abs(y))) if len(y) else 0.0
        self.ch_table.item(ch, 2).setText(f"{20 * np.log10(max(peak, 1e-9)):.1f} dBFS")
        self.ch_table.item(ch, 3).setText(str(len(y)))
        if not self.ch_checks[ch].isChecked():
            self.ch_checks[ch].setChecked(True)
        self._update_preview()

    def _set_enabled(self, ch: int, on: bool):
        self.enabled[ch] = on

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
            y, len_note = wf.fit_length(y, self.imp_len.currentData())
            self._set_wave(ch, y, f"导入 {name}")
            notes.append(f"CH{ch} ← {name}（{scale_note}{'；' + len_note if len_note else ''}）")
        self._msg("；".join(notes))
        self._auto_download()

    # ------------------------------------------------------------------ download
    def _download(self):
        if not self.connected:
            self._msg("未连接", error=True)
            return
        chans = [ch for ch in range(8) if self.enabled[ch]]
        missing = [ch for ch in chans if ch not in self.waves]
        if not chans:
            self._msg("没有勾选输出通道", error=True)
            return
        if missing:
            self._msg("这些通道勾选了输出但没有波形：" + ", ".join(f"CH{c}" for c in missing), error=True)
            return
        lengths = {len(self.waves[ch]["y"]) for ch in chans}
        if len(lengths) != 1:
            self._msg("所有启用通道的波形长度必须相同：" +
                      ", ".join(f"CH{c}={len(self.waves[c]['y'])}" for c in chans), error=True)
            return
        payload = {ch: wf.quantize(self.waves[ch]["y"]) for ch in chans}
        mask = sum(1 << ch for ch in chans)
        self.worker.cancel.clear()
        self.dl_info.setText("下载中…")
        self.req_download.emit(payload, mask, self.verify_cb.isChecked())

    def _on_downloaded(self, r: dict):
        self.progress.hide()
        crc = "，CRC 全部一致" if r["verified"] else "（未校验）"
        run = self.auto_run_cb.isChecked()
        text = (f"已下载 {len(r['channels'])} 个通道 × {r['samples']} 点，{r['bytes'] / 1024:.0f} KiB，"
                f"共 {r['seconds'] * 1e3:.0f} ms，其中数据写入 {r['write_s'] * 1e3:.0f} ms"
                f"（{r['data_mb_s']:.1f} MB/s）{crc}。"
                + ("已自动输出 Run。" if run else "点「输出 Run」开始播放。"))
        self.dl_info.setText(text)
        self.dl_info.setStyleSheet("color:#3B6D11")
        self._msg(text)
        if run:
            self._set_output(True)

    # ================================================================== capture
    def _capture_args(self) -> dict:
        mask = sum(1 << ch for ch, cb in enumerate(self.adc_checks) if cb.isChecked())
        n = self.cap_len.value()
        n -= n % 24
        return {"trigger": self.trig_combo.currentData(), "mask": mask or 1, "samples": max(n, 24),
                "window": self.win_combo.currentData()}

    def _push_capture_args(self, *_):
        if self.cont_btn.isChecked():
            self.req_cap_args.emit(self._capture_args())

    def _capture_single(self):
        if not self.connected:
            self._msg("未连接", error=True)
            return
        self.cont_btn.setChecked(False)
        self.req_cap_once.emit(self._capture_args())

    def _capture_continuous(self, on: bool):
        if on and not self.connected:
            self._msg("未连接", error=True)
            self.cont_btn.blockSignals(True)
            self.cont_btn.setChecked(False)
            self.cont_btn.blockSignals(False)
            return
        self.cont_btn.setText("采集 Stop" if on else "采集 Run")
        if on:
            self.req_cap_start.emit(self._capture_args())
        else:
            self.req_cap_stop.emit()

    def _on_captured(self, d: dict):
        self.last_capture = d
        self.progress.hide()
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
        self.statusBar().showMessage(
            f"采集 {d['count']} 点 × {len(chans)} 通道 · 触发 {'起播同步' if d['trigger'] == 'start' else '手动'} · "
            f"采集共 {d['capture_s'] * 1e3:.0f} ms，其中数据读回 {d['read_s'] * 1e3:.0f} ms（{rate:.1f} MB/s）· RBW {_fmt_hz(d['rbw_hz'])} · "
            f"cap_tx_word {d['cap_tx_word']}", 0)

    def _redraw_time(self, *_):
        d = self.last_capture
        if d is None:
            return
        fs_units = self.yunit.currentData() == "fs"
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
        if n and not self._time_user_zoom:
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
        self._time_user_zoom = True                      # keep the full view on later captures
        self._time_full_range(whole=True)

    def _on_time_zoom(self, *_):
        if not self._time_setting_range:
            self._time_user_zoom = True

    def _time_auto(self):
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
            self.m1_line.setVisible(True)
            self.m1_text.setVisible(True)
        self._update_m2()

    def _toggle_m2(self, on: bool):
        if on:
            self.m2_line.setPos(self.center.value() * 1e6)
        self.m2_line.setVisible(on)
        self.m2_text.setVisible(on)
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
        c = self.center.value() * 1e6
        s = self.span.value() * 1e6
        self.spec_plot.setXRange(max(c - s / 2, 0), min(c + s / 2, ADC_FS / 2), padding=0)

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
