"""One-click 'program bitstream + initialize' through XSCT (scripts/program.tcl).

program.tcl resets the PS, runs psu_init, starts the RF initializer ELF, waits for the LMK clocks,
programs the PL bitstream and lets the initializer finish RFDC/MTS setup. The GUI then waits on the
optical port until STATUS.ps_ready=1 (DeviceWorker.connect_when_ready).
"""
from __future__ import annotations

import os
import re
import shutil
import string
import sys
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, Signal

PROJECT_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_FILES = ("rf_awg_scope_v1.bit", "rf_awg_init.elf", "psu_init.tcl", "init_protocol.txt")


def app_dir() -> Path:
    """Folder of the packaged exe (PyInstaller), or the source project root when run from source."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return PROJECT_ROOT


def missing_package_files(package: str | Path) -> list[str]:
    folder = Path(package)
    return [name for name in PACKAGE_FILES if not (folder / name).is_file()]


def default_package() -> Path:
    """The firmware package shipped next to the exe (firmware/), else the source tree's build/F1/package."""
    for cand in (app_dir() / "firmware", PROJECT_ROOT / "build" / "F1" / "package"):
        if not missing_package_files(cand):
            return cand
    return app_dir() / "firmware"


def program_tcl_for(package: str | Path) -> Path:
    """program.tcl shipped inside the package folder wins; otherwise the source tree's scripts/program.tcl."""
    for cand in (Path(package) / "program.tcl", app_dir() / "firmware" / "program.tcl",
                 PROJECT_ROOT / "scripts" / "program.tcl"):
        if cand.is_file():
            return cand
    return PROJECT_ROOT / "scripts" / "program.tcl"


# Kept for source-tree callers and tests.
DEFAULT_PACKAGE = default_package()
PROGRAM_TCL = program_tcl_for(DEFAULT_PACKAGE)


def _version_key(path: Path) -> tuple:
    nums = [int(n) for n in re.findall(r"\d+", str(path))]
    return tuple(nums)


def _scan_installs() -> list[Path]:
    """Look for Vitis/Vivado xsct.bat on every drive in the usual AMD/Xilinx install layouts."""
    patterns = ("AMDDesignTools/*/Vitis/bin/xsct.bat", "Xilinx/*/Vitis/bin/xsct.bat",
                "Xilinx/Vitis/*/bin/xsct.bat", "AMD/*/Vitis/bin/xsct.bat", "AMD/Vitis/*/bin/xsct.bat",
                "Xilinx/Vivado/*/bin/xsct.bat", "Xilinx/*/Vivado/bin/xsct.bat")
    hits: list[Path] = []
    for letter in string.ascii_uppercase[2:]:          # C: .. Z:
        root = Path(f"{letter}:/")
        try:
            if not root.exists():
                continue
        except OSError:
            continue
        for pat in patterns:
            try:
                hits.extend(p for p in root.glob(pat) if p.is_file())
            except OSError:
                pass
    return sorted(set(hits), key=_version_key, reverse=True)      # newest version first


def find_xsct(preferred: str | None = None) -> str | None:
    """Saved path, then $XILINX_VITIS / $XILINX_VIVADO, PATH, then every drive's usual install folders."""
    candidates = [preferred] if preferred else []
    for var in ("XILINX_VITIS", "XILINX_VIVADO"):
        if os.environ.get(var):
            candidates.append(str(Path(os.environ[var]) / "bin" / "xsct.bat"))
    for name in ("xsct.bat", "xsct"):
        hit = shutil.which(name)
        if hit:
            candidates.append(hit)
    for c in candidates:
        if c and Path(c).is_file():
            return str(Path(c))
    found = _scan_installs()
    return str(found[0]) if found else None


class BoardProgrammer(QObject):
    """Runs program.tcl in XSCT without blocking the GUI. Emits every output line."""
    line = Signal(str)
    finished = Signal(bool, str)          # ok, message

    def __init__(self, parent=None):
        super().__init__(parent)
        self.proc: QProcess | None = None
        self._cancelled = False
        self._last_lines: list[str] = []

    def running(self) -> bool:
        return self.proc is not None and self.proc.state() != QProcess.NotRunning

    def start(self, xsct: str, package: str | Path, server: str = "", script: str | Path | None = None):
        if self.running():
            raise RuntimeError("初始化已在进行中")
        script = Path(script) if script else program_tcl_for(package)
        if not script.is_file():
            raise FileNotFoundError(f"找不到 program.tcl：{script}")
        args = [str(script)]
        if server.strip():
            args += ["-server", server.strip()]
        args += ["-package", str(Path(package))]
        env = QProcessEnvironment.systemEnvironment()
        env.insert("PROCESSOR_ARCHITECTURE", "AMD64")      # Vivado/Vitis 2025.2 tools need this on this PC
        env.remove("NoDefaultCurrentDirectoryInExePath")
        self.proc = QProcess(self)
        self.proc.setProcessEnvironment(env)
        self.proc.setWorkingDirectory(str(Path(package)))
        self.proc.setProcessChannelMode(QProcess.MergedChannels)
        self.proc.readyReadStandardOutput.connect(self._read)
        self.proc.finished.connect(self._done)
        self.proc.errorOccurred.connect(self._error)
        self._cancelled = False
        self._last_lines = []
        self.line.emit(f"$ {xsct} {' '.join(args)}")
        self.proc.start(xsct, args)

    def cancel(self):
        if self.running():
            self._cancelled = True
            self.proc.kill()

    def _read(self):
        text = bytes(self.proc.readAllStandardOutput()).decode("utf-8", errors="replace")
        for ln in text.splitlines():
            ln = ln.rstrip()
            if ln:
                self._last_lines = (self._last_lines + [ln])[-6:]
                self.line.emit(ln)

    def _done(self, code: int, status):
        self._read()
        if self._cancelled:
            self.finished.emit(False, "已取消（板子可能处于未初始化状态，需要重新下载）")
        elif status == QProcess.NormalExit and code == 0 and any("initializer is running" in s for s in self._last_lines):
            self.finished.emit(True, "bit 已下载，PS 正在初始化 RFDC")
        else:
            tail = "\n".join(self._last_lines[-3:])
            self.finished.emit(False, f"XSCT 退出码 {code}\n{tail}")
        self.proc = None

    def _error(self, err):
        if err == QProcess.FailedToStart:
            self.finished.emit(False, "无法启动 XSCT，请在菜单「设备 → 设置 XSCT 路径」中指定 xsct.bat")
            self.proc = None
