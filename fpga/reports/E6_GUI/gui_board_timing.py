"""Drive the real MainWindow (offscreen) against the board and print download/capture timings."""
import os, sys, time
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, r"D:\ClaudeProject\47DR_DAAD\rf_awg_eth_v1\tools")
os.environ["APPDATA"] = os.path.join(os.path.dirname(__file__), "appdata")
from PySide6.QtWidgets import QApplication
app = QApplication([])
from awg_gui.main_window import MainWindow
from awg_gui import waveforms as wf

BUSY = 'busy' in sys.argv
for a in sys.argv:
    if a.startswith('si='): sys.setswitchinterval(float(a[3:])); print('switchinterval', sys.getswitchinterval())
def wait(cond, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        app.processEvents()
        if cond():
            return True
        if BUSY:
            x = 0
            for k in range(200000): x += k
        else:
            time.sleep(0.002)
    return False

win = MainWindow("192.168.42.2", 9100)
win.ip_edit.setText("192.168.42.2"); win.port_spin.setValue(9100)
errors = []
win.worker.failed.connect(lambda op, m: errors.append((op, m)))
win._toggle_connect(); assert wait(lambda: win.connected), errors
mode = sys.argv[1] if len(sys.argv) > 1 else "capture"
got = []
win.worker.captured.connect(got.append)
done = []
win.worker.downloaded.connect(done.append)
if mode == "download":
    win.std_target.setCurrentIndex(0)
    win.std_kind.setCurrentIndex(list(wf.KINDS).index("sine"))
    win.std_freq.setValue(100.0); win.std_amp.setValue(-6.0)
    for i in range(3):
        n = len(done)
        win._generate() if i == 0 else win._download()
        assert wait(lambda: len(done) > n or errors, 60), errors
        d = done[-1]; print(f"download ch={d['channels']} total {d['seconds']*1e3:.1f} ms write {d['write_s']*1e3:.1f} ms ({d['data_mb_s']:.1f} MB/s) total {d['mb_s']:.1f} MB/s")
for nch in (1, 8):
    for i, cb in enumerate(win.adc_checks):
        cb.setChecked(i < nch)
    for i in range(3):
        n = len(got)
        t = time.perf_counter()
        if 'start' in sys.argv: win.trig_combo.setCurrentIndex(1)
        win._capture_single()
        assert wait(lambda: len(got) > n or errors, 30), errors
        d = got[-1]
        print(f"capture {nch}ch read_s={d['read_s']*1e3:.1f} ms total_s={d['total_s']*1e3:.1f} ms "
              f"wall={(time.perf_counter()-t)*1e3:.1f} ms trig={d['trigger']}")
print("errors", errors)
win.close()



