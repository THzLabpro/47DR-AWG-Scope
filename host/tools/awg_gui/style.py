"""Look of the GUI, following the rf_awg_scope_v1 MATLAB app (AWGScopeApp.m): light blue-gray page,
white cards, teal accent, numbered workflow steps, dark log panel."""
from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QPushButton, QWidget

BG = "#F2F7FA"          # page                 (MATLAB bg     [.95 .97 .98])
INK = "#1F3347"         # text                 (MATLAB ink    [.12 .20 .28])
ACCENT = "#086B82"      # headings, primary    (MATLAB accent [.03 .42 .51])
SELECTED = "#2E8295"    # toggled channel      (MATLAB selectedColor)
IDLE = "#E9F2F4"        # buttons              (MATLAB idleColor)
BORDER = "#C9D8DE"
MUTED = "#5B6B78"
LOG_BG = "#1A2936"      # log panel            (MATLAB [.10 .16 .21])
LOG_FG = "#C9E3ED"      #                      (MATLAB [.79 .89 .93])
DONE_BG = "#E1F1E7"
DONE_FG = "#2E7D4F"
OK = "#0B7559"          # (MATLAB [.02 .46 .35])
BUSY = "#AB5F0F"        # (MATLAB [.67 .37 .06])
BAD = "#BF2B21"         # (MATLAB [.75 .17 .13])
OFF = "#B9C4CA"

QSS = f"""
QMainWindow, QWidget#root {{ background: {BG}; }}
QWidget {{ color: {INK}; font-family: "Microsoft YaHei UI", "Segoe UI"; font-size: 9pt; }}
QFrame#card {{ background: white; border: 1px solid {BORDER}; border-radius: 6px; }}
QLabel#title {{ font-size: 17pt; font-weight: bold; background: transparent; }}
QLabel#section {{ color: {ACCENT}; font-weight: bold; font-size: 10pt; background: transparent; }}
QLabel#muted {{ color: {MUTED}; background: transparent; }}
QLabel#facts {{ color: {ACCENT}; background: transparent; }}
QPushButton {{ background: {IDLE}; border: 1px solid {BORDER}; border-radius: 4px; padding: 5px 10px; }}
QPushButton:hover {{ background: #DCEBEE; }}
QPushButton:pressed {{ background: #CFE3E8; }}
QPushButton:disabled {{ color: #9AA8B0; background: #EEF2F4; border-color: #DCE4E8; }}
QPushButton:checked {{ background: {SELECTED}; color: white; border-color: {SELECTED}; font-weight: bold; }}
QPushButton[primary="true"] {{ background: {ACCENT}; color: white; border-color: {ACCENT}; font-weight: bold; }}
QPushButton[primary="true"]:hover {{ background: #0A7C96; }}
QPushButton[primary="true"]:disabled {{ background: #8FB8C2; border-color: #8FB8C2; }}
QPushButton[chan="true"] {{ padding: 3px 4px; min-height: 20px; }}
QTabWidget::pane {{ border: 1px solid {BORDER}; background: white; border-radius: 4px; top: -1px; }}
QTabBar::tab {{ background: {IDLE}; border: 1px solid {BORDER}; padding: 5px 14px; margin-right: 2px;
               border-top-left-radius: 4px; border-top-right-radius: 4px; }}
QTabBar::tab:selected {{ background: white; border-bottom-color: white; font-weight: bold; }}
QProgressBar {{ border: 1px solid {BORDER}; border-radius: 3px; background: {IDLE}; max-height: 12px; }}
QProgressBar::chunk {{ background: {ACCENT}; }}
QPlainTextEdit#log {{ background: {LOG_BG}; color: {LOG_FG}; font-family: Consolas, "Microsoft YaHei UI";
                      font-size: 9pt; border: none; border-radius: 4px; padding: 4px; }}
QScrollArea {{ border: none; background: white; }}
QScrollArea > QWidget > QWidget {{ background: white; }}
QStatusBar {{ color: {MUTED}; }}
QStatusBar QLabel {{ color: {MUTED}; }}
"""


def card() -> QFrame:
    frame = QFrame()
    frame.setObjectName("card")
    return frame


def label(text: str = "", kind: str = "") -> QLabel:
    lab = QLabel(text)
    if kind:
        lab.setObjectName(kind)
    return lab


def primary(button: QPushButton) -> QPushButton:
    button.setProperty("primary", True)
    return button


def chan_button(text: str) -> QPushButton:
    button = QPushButton(text)
    button.setCheckable(True)
    button.setProperty("chan", True)
    return button


class Led(QWidget):
    """A round indicator with a caption, like the MATLAB uilamp."""

    def __init__(self, caption: str):
        super().__init__()
        h = QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(5)
        self.dot = QLabel()
        self.dot.setFixedSize(14, 14)
        self.caption = QLabel(caption)
        h.addWidget(self.dot)
        h.addWidget(self.caption)
        self.set_color(OFF)

    def set_color(self, color: str):
        self.dot.setStyleSheet(f"background: {color}; border-radius: 7px; border: 1px solid rgba(0,0,0,40);")


class StepBar(QWidget):
    """① 初始化板卡 › ② 连接板卡 › ③ 选波形 › ④ 下载并播放 › ⑤ 采集 — done / current / todo."""

    clicked = Signal(int)
    TITLES = ("① 初始化板卡", "② 连接板卡", "③ 选波形", "④ 下载并播放", "⑤ 采集")

    def __init__(self):
        super().__init__()
        h = QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(6)
        self.buttons: list[QPushButton] = []
        for i, title in enumerate(self.TITLES):
            if i:
                arrow = QLabel("›")
                arrow.setStyleSheet(f"color: {MUTED}; font-size: 13pt; background: transparent;")
                h.addWidget(arrow)
            b = QPushButton(title)
            b.setMinimumWidth(128)
            b.setCursor(Qt.PointingHandCursor)
            b.clicked.connect(lambda _=False, k=i: self.clicked.emit(k))
            self.buttons.append(b)
            h.addWidget(b)
        self.states = ["todo"] * len(self.TITLES)
        self.set_states(self.states)

    def set_states(self, states: list[str]):
        self.states = list(states)
        for b, title, state in zip(self.buttons, self.TITLES, states):
            if state == "done":
                b.setText(title + " ✓")
                b.setStyleSheet(f"QPushButton {{ background: {DONE_BG}; color: {DONE_FG}; border: 1px solid #BFE0CC; }}")
            elif state == "current":
                b.setText(title)
                b.setStyleSheet(f"QPushButton {{ background: {ACCENT}; color: white; border: 1px solid {ACCENT};"
                                f" font-weight: bold; }}")
            else:
                b.setText(title)
                b.setStyleSheet(f"QPushButton {{ background: #EEF2F4; color: {MUTED}; border: 1px solid #DCE4E8; }}")
