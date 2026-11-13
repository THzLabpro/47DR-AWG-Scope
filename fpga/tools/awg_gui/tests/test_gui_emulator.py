"""Headless end-to-end GUI flow against the loopback FPGA emulator (no hardware)."""
import os
import time

import numpy as np
import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication  # noqa: E402

from awg_eth.fpga_emu import FpgaEmulator  # noqa: E402
from awg_gui import waveforms as wf  # noqa: E402


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


def test_full_flow(app, tmp_path, monkeypatch):
    monkeypatch.setenv("APPDATA", str(tmp_path))
    from awg_gui.main_window import MainWindow
    with FpgaEmulator(loopback=True) as emu:
        win = MainWindow("127.0.0.1", emu.port)
        win.ip_edit.setText("127.0.0.1")
        win.port_spin.setValue(emu.port)
        errors = []
        win.worker.failed.connect(lambda op, msg: errors.append((op, msg)))
        try:
            win._toggle_connect()
            assert _wait(app, lambda: win.connected), errors

            # CH0 sine 100 MHz, CH1 square; all 8 channels sine for a multi-channel download
            # Generate on all channels: auto-download (with CRC) then auto Run (defaults on).
            assert win.auto_dl_cb.isChecked() and win.auto_run_cb.isChecked()
            done = []
            win.worker.downloaded.connect(done.append)
            win.std_target.setCurrentIndex(8)
            win.std_kind.setCurrentIndex(list(wf.KINDS).index("sine"))
            win.std_freq.setValue(100.0)
            win.std_amp.setValue(-6.0)
            win._generate()
            assert all(win.enabled) and len(win.waves) == 8
            assert _wait(app, lambda: done or errors, 120), errors
            assert not errors and done[0]["verified"] and done[0]["channels"] == list(range(8))
            assert _wait(app, lambda: win.running or errors), errors
            win._set_output(True)                       # Run while running is a no-op
            _wait(app, lambda: False, 0.5)
            assert not errors

            # explicit download button still works (stop -> load -> auto run)
            win._download()
            assert _wait(app, lambda: len(done) >= 2 or errors, 120), errors
            assert _wait(app, lambda: win.running or errors), errors

            for cb in win.adc_checks:
                cb.setChecked(True)
            got = []
            win.worker.captured.connect(got.append)
            win._capture_single()
            assert _wait(app, lambda: got or errors, 60), errors
            d = got[0]
            assert sorted(d["samples"]) == list(range(8)) and d["count"] == 65520
            # Emulator loops TX samples 1:1 into the ADC buffer, so the tone reads at cycles * 5 GS/s / 131072.
            cycles, _ = wf.snap_cycles(100e6, 131072)
            m = d["meas"][0]
            assert abs(m["freq_hz"] - cycles * 5e9 / 131072) < 50e3
            assert abs(m["peak_dbfs"] - (-6.0)) < 0.3
            assert m["sfdr_dbc"] > 60
            assert win.cards["freq"].text() != "—"
            # time plot shows the whole capture without manual zoom (regression: blank plot)
            x0, x1 = win.time_plot.getViewBox().viewRange()[0]
            assert x0 == 0 and abs(x1 - max(10 / m["freq_hz"], 50e-9)) < 1e-12      # auto: ~10 periods
            win._time_whole()
            assert abs(win.time_plot.getViewBox().viewRange()[0][1] - 65520 / 5e9) < 1e-12
            xs, ys = win.time_curves[0].getData()
            assert xs is not None and len(xs) > 100

            # continuous capture runs and stops cleanly
            n0 = len(got)
            win.cont_btn.setChecked(True)
            assert _wait(app, lambda: len(got) >= n0 + 2 or errors, 60), errors
            win.cont_btn.setChecked(False)
            app.processEvents()
            time.sleep(0.5)
            _wait(app, lambda: False, 1.0)
            n1 = len(got)
            _wait(app, lambda: False, 1.0)
            assert len(got) <= n1 + 1

            out = tmp_path / "cap.csv"
            monkeypatch.setattr("awg_gui.main_window.QFileDialog.getSaveFileName", lambda *a, **k: (str(out), ""))
            win._save_capture()
            assert out.exists() and out.with_suffix(".json").exists()
            arr = np.loadtxt(out, delimiter=",", skiprows=1)
            assert arr.shape == (65520, 8)
            assert not errors
        finally:
            win.close()
