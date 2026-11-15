"""Real Qt worker and widgets over loopback service; never opens hardware."""
import os
import threading
import time
import numpy as np
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtWidgets import QApplication, QMessageBox
from awg_eth.fpga_emu import FpgaEmulator
from awg_eth.remote import RemoteServer, RemoteClient
from awg_gui.main_window import MainWindow
from awg_gui import measure


def wait(app, predicate, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        app.processEvents()
        if predicate():
            return True
        time.sleep(.005)
    return False


def test_remote_gui_and_offline_record(tmp_path, monkeypatch):
    monkeypatch.setenv("AWG_APP_DATA", str(tmp_path))
    warnings = []
    monkeypatch.setattr(QMessageBox, "warning", lambda *args: warnings.append(args[2]))
    app = QApplication.instance() or QApplication([])
    with FpgaEmulator(abi=3, build_id=0xD4B02026, loopback=True) as emu:
        with RemoteServer(("127.0.0.1", 0), fpga_ip="127.0.0.1", fpga_port=emu.port) as server:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .02}, daemon=True)
            thread.start()
            win = MainWindow()
            errors, captures, downloads, analysis_locks = [], [], [], []
            analyze = measure.analyze
            def observed_analyze(*args, **kwargs):
                analysis_locks.append(server.owner.locked())
                return analyze(*args, **kwargs)
            monkeypatch.setattr(measure, "analyze", observed_analyze)
            win.worker.failed.connect(lambda op, msg: errors.append((op, msg)))
            win.worker.captured.connect(captures.append)
            win.worker.downloaded.connect(downloads.append)
            try:
                win.remote_host.setText("127.0.0.1")
                win.remote_port.setValue(server.server_address[1])
                win._toggle_connect()
                assert wait(app, lambda: win.connected or errors), errors
                assert win.connected and not server.owner.locked()
                win.std_len.setValue(4096)
                win._generate()
                assert wait(app, lambda: win.running or errors), errors
                assert not errors and downloads
                assert wait(app, lambda: not server.owner.locked())
                win.cap_len.setValue(65544)
                win._capture_single()
                assert wait(app, lambda: captures or errors), errors
                assert captures and not errors and analysis_locks == [False]
                assert wait(app, lambda: win.last_capture is not None)
                original = win.last_capture["samples"][0].copy()
                # File save and reanalysis proceed while someone else owns the board.
                path = tmp_path / "capture.csv"
                monkeypatch.setattr("awg_gui.main_window.QFileDialog.getSaveFileName", lambda *a: (str(path), ""))
                monkeypatch.setattr("awg_gui.main_window.QFileDialog.getOpenFileName", lambda *a: (str(path), ""))
                with RemoteClient("127.0.0.1", server.server_address[1]):
                    win._save_capture()
                    win._load_capture()
                    assert wait(app, lambda: len(captures) == 2 or errors), errors
                    np.testing.assert_array_equal(captures[-1]["samples"][0], original)
                    assert captures[-1]["offline"] and server.owner.locked()
                assert wait(app, lambda: "本地记录" in win.facts.text())
                # Running output must not be silently stopped by a second download.
                win._download()
                assert wait(app, lambda: errors), errors
                assert "手动停止" in errors[-1][1] and emu._running
                errors.clear()
                win._set_output(False)
                assert wait(app, lambda: not win.running)
                win._download()
                assert wait(app, lambda: len(downloads) == 2 and win.running or errors), errors
                # Continuous acquisition holds a lease, stopping it releases without stopping DAC.
                win.cont_btn.setChecked(True)
                assert wait(app, lambda: len(captures) >= 4 or errors), errors
                assert not errors and server.owner.locked()
                win.cont_btn.setChecked(False)
                assert wait(app, lambda: not server.owner.locked())
                assert emu._running
                win._toggle_connect()
                assert wait(app, lambda: not win.connected)
                # Failed connect restores editing of the transport fields.
                with RemoteClient("127.0.0.1", server.server_address[1]):
                    win._toggle_connect()
                    assert wait(app, lambda: errors)
                    assert win.remote_host.isEnabled() and win.transport_combo.isEnabled()
            finally:
                win.close()
                assert wait(app, lambda: not win.thread.isRunning())
                assert not server.owner.locked()
                server.shutdown()
                thread.join(5)
