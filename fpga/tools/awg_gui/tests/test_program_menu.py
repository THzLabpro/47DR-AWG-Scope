"""'设备 → 下载 bit 并初始化' with a fake xsct.bat (never touches JTAG) and the loopback emulator."""
import os
import time
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication, QMessageBox  # noqa: E402

from awg_eth.fpga_emu import FpgaEmulator  # noqa: E402
from awg_gui import programmer  # noqa: E402


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


def _wait(app, cond, timeout=30.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        app.processEvents()
        if cond():
            return True
        time.sleep(0.01)
    return False


def _fake_xsct(tmp_path: Path, exit_code: int) -> Path:
    bat = tmp_path / f"fake_xsct_{exit_code}.bat"
    args_file = tmp_path / "xsct_args.txt"
    last = "RF initializer is running. Wait for AWG READY on PS UART before JTAG wave commands."
    bat.write_text(
        "@echo off\r\n"
        f"echo %* > \"{args_file}\"\r\n"
        "echo LMK clocks are stable; programming the matching PL before RFDC initialization.\r\n"
        + (f"echo {last}\r\n" if exit_code == 0 else "echo ERROR: No Zynq UltraScale+ PSU found\r\n")
        + f"echo PROCESSOR_ARCHITECTURE=%PROCESSOR_ARCHITECTURE%>> \"{args_file}\"\r\n"
        f"exit /b {exit_code}\r\n", encoding="ascii")
    return bat


def test_program_then_auto_connect(app, tmp_path, monkeypatch):
    monkeypatch.setenv("APPDATA", str(tmp_path))
    from awg_gui.main_window import MainWindow
    monkeypatch.setattr(QMessageBox, "question", lambda *a, **k: QMessageBox.Yes)
    warnings = []
    monkeypatch.setattr(QMessageBox, "warning", lambda *a, **k: warnings.append(a[2] if len(a) > 2 else a))
    with FpgaEmulator(loopback=True) as emu:
        win = MainWindow("127.0.0.1", emu.port)
        try:
            win.ip_edit.setText("127.0.0.1")
            win.port_spin.setValue(emu.port)
            win.settings.setValue("xsct", str(_fake_xsct(tmp_path, 0)))
            win.settings.setValue("hw_server", "localhost:3121")
            win._program_board()
            assert not win.act_program.isEnabled() and win.act_program_cancel.isEnabled()
            assert _wait(app, lambda: win.connected or warnings, 60), warnings
            assert not warnings
            assert win.act_program.isEnabled() and not win.act_program_cancel.isEnabled()
            assert win.connect_btn.isEnabled()
            args = (tmp_path / "xsct_args.txt").read_text(encoding="ascii", errors="replace")
            assert str(programmer.PROGRAM_TCL) in args
            assert "-server localhost:3121" in args
            assert "-package " + str(programmer.DEFAULT_PACKAGE) in args
            assert "PROCESSOR_ARCHITECTURE=AMD64" in args
            log = win.log_view.toPlainText()
            assert "[xsct] RF initializer is running" in log and "下载 bit 并初始化完成" in log

            # failing XSCT: error shown, menu re-enabled, no connect attempt
            win._toggle_connect()                    # disconnect first
            assert _wait(app, lambda: not win.connected)
            win.settings.setValue("xsct", str(_fake_xsct(tmp_path, 1)))
            win._program_board()
            assert _wait(app, lambda: warnings, 60)
            assert "退出码 1" in warnings[0] and "No Zynq" in warnings[0]
            assert win.act_program.isEnabled() and not win.connected
        finally:
            win.close()


def test_missing_package_and_xsct_lookup(tmp_path):
    assert programmer.missing_package_files(tmp_path) == list(programmer.PACKAGE_FILES)
    fake = tmp_path / "xsct.bat"
    fake.write_text("@echo off\r\n", encoding="ascii")
    assert programmer.find_xsct(str(fake)) == str(fake)
