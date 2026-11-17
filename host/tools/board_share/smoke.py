"""Packaged native-window smoke check; no network/hardware access."""
import json
import time
from pathlib import Path
from PySide6.QtWidgets import QApplication
from .widget import ShareWidget


def run(window_class, output):
    app = QApplication.instance() or QApplication([])
    saved = ShareWidget.connect_saved
    ShareWidget.connect_saved = lambda self: None
    window = None
    try:
        window = window_class()
        window.show()
        for _ in range(5):
            app.processEvents()
        path = Path(output)
        path.parent.mkdir(parents=True, exist_ok=True)
        if not window.grab().save(str(path.with_suffix('.png'))):
            raise RuntimeError('screenshot failed')
        assert window.share.session is None
        project = window.share.project
        window.close()
        deadline = time.monotonic() + 5
        worker = getattr(window, 'thread', None)
        if callable(worker):
            worker = None  # QWidget.thread() is not a separately owned device worker.
        while worker is not None and worker.isRunning() and time.monotonic() < deadline:
            app.processEvents()
            time.sleep(.01)
        if worker is not None and worker.isRunning():
            raise RuntimeError('worker did not close')
        path.write_text(json.dumps({'passed': True, 'project': project, 'hardware_accessed': False}), encoding='utf-8')
        return 0
    finally:
        ShareWidget.connect_saved = saved
