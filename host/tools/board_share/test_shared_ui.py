import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
from PySide6.QtWidgets import QApplication
from unittest.mock import patch
from board_share.widget import ShareWidget


def test_awg_shared_window_has_native_controls():
    from awg_gui.shared_window import SharedMainWindow
    app = QApplication.instance() or QApplication([])
    with patch.object(ShareWidget, 'connect_saved'):
        window = SharedMainWindow()
        app.processEvents()
        assert window.share.project == '47DR'
        assert window.share.end_button.text() == '结束使用'
        assert not window.transport_combo.isEnabled()
        window.close()
        import time
        deadline = time.monotonic() + 3
        while window.thread.isRunning() and time.monotonic() < deadline:
            app.processEvents()
            time.sleep(.01)
        assert not window.thread.isRunning()


def test_rfudp_remote_window_never_opens_local_hardware():
    import pytest
    pytest.importorskip('host.analyzer.remote_window')
    from host.analyzer.remote_window import RemoteRFUDPAnalyzer
    app = QApplication.instance() or QApplication([])
    with patch.object(ShareWidget, 'connect_saved'), patch('serial.Serial', side_effect=AssertionError('local UART')):
        window = RemoteRFUDPAnalyzer()
        app.processEvents()
        assert window.share.project == 'RF-UDP'
        with pytest.raises(RuntimeError, match='客户端'):
            window.launch_process('cmd.exe', [], None, 1)
        assert window.serial_factory() is window.remote_stream
        window.close()
        app.processEvents()
