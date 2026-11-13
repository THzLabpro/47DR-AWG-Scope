"""Entry point:  cd tools && py -X utf8 -m awg_gui [--emulator] [--ip 192.168.42.2] [--port 9100]

--emulator starts the loopback FPGA emulator on 127.0.0.1 for offline use (ADC returns the DAC samples).
"""
from __future__ import annotations

import argparse
import sys

from PySide6.QtWidgets import QApplication


def selftest(out_path: str | None) -> int:
    """No hardware: emulator + download with CRC + capture + spectrum, and check the firmware/xsct lookup.

    Writes a text report (default %TEMP%\\awg47dr_selftest.txt) and returns 0 on success.
    """
    import os
    import tempfile
    import time
    import traceback
    from pathlib import Path

    lines: list[str] = []
    ok = True
    try:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        import numpy as np
        app = QApplication.instance() or QApplication([sys.argv[0]])
        from awg_eth.awg import Awg
        from awg_eth.client import AwgEthClient
        from awg_eth.fpga_emu import FpgaEmulator
        from . import measure, waveforms as wf
        from .main_window import APP_VERSION, MainWindow
        from .programmer import app_dir, default_package, find_xsct, missing_package_files, program_tcl_for
        lines.append(f"version {APP_VERSION}; exe dir {app_dir()}")
        pkg = default_package()
        miss = missing_package_files(pkg)
        lines.append(f"firmware {pkg}: {'OK' if not miss else 'MISSING ' + ','.join(miss)}; program.tcl {program_tcl_for(pkg)}")
        lines.append(f"xsct: {find_xsct() or '未找到（一键下载 bit 需要安装 Vivado/Vitis，或在菜单里指定 xsct.bat）'}")
        win = MainWindow()                      # widgets + pyqtgraph import check
        win.close()
        with FpgaEmulator(loopback=True).start() as emu:
            with AwgEthClient("127.0.0.1", port=emu.port, words_per_packet=2048) as client:
                awg = Awg(client)
                y = wf.quantize(wf.generate(wf.WaveSpec(kind="sine", freq_hz=100e6, amp_dbfs=-6.0, samples=131072))[0])
                words = {ch: wf.pack_words(y) for ch in range(8)}
                t0 = time.perf_counter()
                awg.load_words(words, 131072, 0xFF, verify=True)
                lines.append(f"download 8ch x 131072 with CRC: OK {time.perf_counter() - t0:.2f} s")
                awg.start()
                captured, _, raw = awg.capture_raw("manual", 0x01, samples=65520)
                sig = wf.unpack_pairs(raw[0])[:captured]
                m = measure.measure(sig, measure.ADC_FS_HZ, "blackmanharris")
                lines.append(f"capture {captured}: peak {m['peak_dbfs']:.2f} dBFS, SFDR {m['sfdr_dbc']:.1f} dBc")
                ok = ok and captured == 65520 and abs(m["peak_dbfs"] + 6.0) < 0.5 and not miss
        del app
    except Exception:  # noqa: BLE001
        ok = False
        lines.append(traceback.format_exc())
    lines.append("SELFTEST " + ("PASS" if ok else "FAIL"))
    target = Path(out_path) if out_path else Path(tempfile.gettempdir()) / "awg47dr_selftest.txt"
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if sys.stdout:
        print("\n".join(lines))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="47DR AWG / 示波器上位机")
    ap.add_argument("--ip", default="192.168.42.2")
    ap.add_argument("--port", type=int, default=9100)
    ap.add_argument("--emulator", action="store_true", help="在本机启动 FPGA 模拟器（回环）")
    ap.add_argument("--selftest", action="store_true", help="不接硬件的自检，结果写到 --selftest-out")
    ap.add_argument("--selftest-out", default=None)
    ap.add_argument("--program", action="store_true",
                    help="启动后立即「下载 bit 并初始化」（仍会弹确认框，加 --yes 跳过），完成后自动连接")
    ap.add_argument("--yes", action="store_true", help="与 --program 一起使用：不弹确认框")
    args, qt_args = ap.parse_known_args()
    if args.selftest:
        return selftest(args.selftest_out)

    emulator = None
    if args.emulator:
        from awg_eth.fpga_emu import FpgaEmulator
        emulator = FpgaEmulator(loopback=True, loopback_delay_samples=37).start()
        args.ip, args.port = "127.0.0.1", emulator.port

    app = QApplication([sys.argv[0]] + qt_args)
    app.setApplicationName("47DR AWG")
    from .main_window import MainWindow
    win = MainWindow(args.ip, args.port)
    if emulator is not None:
        win.ip_edit.setText(args.ip)
        win.port_spin.setValue(args.port)
        win.setWindowTitle(win.windowTitle() + "（模拟器）")
    win.resize(1500, 900)
    win.show()
    if args.program and emulator is None:
        from PySide6.QtCore import QTimer
        QTimer.singleShot(300, lambda: win._program_board(confirm=not args.yes))
    code = app.exec()
    if emulator is not None:
        emulator.close()
    return code


if __name__ == "__main__":
    sys.exit(main())
