"""47DR integrated shared-board mode; DSP stays on this client."""
import time
from PySide6.QtCore import QTimer
from .main_window import MainWindow
from . import waveforms as wf, measure
from awg_eth.remote import encode_arrays, decode_arrays
from board_share.widget import ShareWidget


class SharedMainWindow(MainWindow):
    def __init__(self, *args, share_url=None, **kwargs):
        self.shared_continuous = False
        self.shared_closing = False
        self.shared_released = False
        super().__init__(*args, **kwargs)
        self.share = ShareWidget('47DR', self, url=share_url)
        self.centralWidget().layout().insertWidget(1, self.share)
        self.share.ended.connect(self._shared_ended)
        self.share.changed.connect(self._shared_status)
        self.transport_combo.setEnabled(False)
        self.remote_port.setEnabled(False)
        self.connect_btn.setText('连接共用服务')
        self.setWindowTitle(self.windowTitle() + ' · 共板模式')
        QTimer.singleShot(0, self.share.connect_saved)

    def _shared_status(self, status):
        self.connected = self.share.session is not None
        self.conn_label.setText('● 共用服务已连接')
        self.connect_btn.setText('结束使用' if status['mine'] else '共用服务已连接')
        if not status['mine']:
            self.running = False
        self._update_steps()

    def _toggle_connect(self):
        if not self.share.session:
            self.share.configure()
        elif self.share.snapshot.get('mine'):
            self.shared_continuous = False
            self.share.end()

    def _program_board(self, confirm=True):
        self.share.submit('program', {}, self._shared_result)

    def _shared_result(self, result, error):
        if error:
            self._msg(error, error=True)
            return
        if 'status' in result:
            self._on_status(result['status'])
        self._progress_idle('操作完成')

    def _refresh_status(self):
        self.share.poll()
        if self.share.snapshot.get('mine'):
            self.share.submit('status', {}, self._shared_result)

    def _clear_fault(self):
        self.share.submit('clear', {}, self._shared_result)

    def _set_output(self, run):
        self.share.submit('start' if run else 'stop', {}, self._shared_result)

    def _download(self):
        chans = [ch for ch in range(8) if self.enabled[ch]]
        if not chans or any(ch not in self.waves for ch in chans):
            self._msg('请为启用通道准备波形', error=True)
            return False
        lengths = {len(self.waves[ch]['y']) for ch in chans}
        if len(lengths) != 1:
            self._msg('所有启用通道的波形长度必须相同', error=True)
            return False
        n = lengths.pop()
        if n % 32 or n > 1048576 // (1 if len(chans) == 1 else 2 if len(chans) == 2 else 4 if len(chans) <= 4 else 8):
            self._msg('波形长度超出容量或未按 32 点对齐', error=True)
            return False
        packed = {ch: wf.pack_words(wf.quantize(self.waves[ch]['y'])) for ch in chans}
        capture = self._capture_args() if self._capture_after_download else None
        parameters = dict(channels=encode_arrays(packed), samples=n, mask=sum(1 << c for c in chans),
                          verify=self.verify_cb.isChecked(), auto_run=self.auto_run_cb.isChecked() or bool(capture),
                          capture=capture)
        self._capture_after_download = False
        def done(result, error):
            self._shared_result(result, error)
            if not error:
                self._downloaded_once = True
                self.dl_info.setText(f'已下载 {len(chans)} 通道 × {n} 点' + ('，已启动播放' if parameters['auto_run'] else ''))
                if result.get('capture'):
                    self._analyze_capture(result['capture'], capture)
        return self.share.submit('load_words', parameters, done)

    def _capture_single(self):
        self.shared_continuous = False
        self._shared_capture(self._capture_args())

    def _capture_continuous(self, on):
        self.shared_continuous = on
        self.cont_btn.setText('停止连续采集' if on else '连续采集')
        if on:
            self.shared_capture_args = dict(self._capture_args())
            self._shared_capture(self.shared_capture_args)

    def _push_capture_args(self, *_):
        # Submitted frame settings remain frozen. New settings apply after stopping/restarting.
        self._update_capture_limit()

    def _shared_capture(self, args):
        def done(result, error):
            if error:
                self.shared_continuous = False
                self._msg(error, error=True)
            else:
                self._analyze_capture(result, args)
        if not self.share.submit('capture_raw', args, done):
            self.shared_continuous = False

    def _analyze_capture(self, result, args):
        def analyze():
            started = time.perf_counter()
            count = result['count']
            arrays = decode_arrays(result['channels'])
            data = {ch: wf.unpack_pairs(v)[:count] for ch, v in arrays.items()}
            spectra, measurements = {}, {}
            window = args.get('window', 'blackmanharris')
            for ch, y in data.items():
                f, db, rbw, measurements[ch] = measure.analyze(y[:262144], measure.ADC_FS_HZ, window)
                spectra[ch] = (f, db)
            return dict(samples=data, spectra=spectra, meas=measurements, rbw_hz=rbw,
                        cap_tx_word=result['cap_tx_word'], count=count, trigger=args.get('trigger'),
                        read_s=result['read_s'], capture_s=result['read_s'], total_s=time.perf_counter()-started,
                        control_s=None, process_s=time.perf_counter()-started, process_cpu_s=None,
                        emit_t=time.perf_counter(), window=window, analysis_points=min(count, 262144),
                        analysis_limited=count > 262144)
        def done(data, error):
            if error:
                self._msg(error, error=True)
                self.shared_continuous = False
                return
            self._set_view('capture')
            self._on_captured(data)
            if self.shared_continuous and not self.shared_closing:
                QTimer.singleShot(100, lambda: self._shared_capture(self.shared_capture_args))
        self.share.background(analyze, done)

    def closeEvent(self, event):
        if hasattr(self, 'share') and self.share.session and not self.shared_released:
            event.ignore()
            self.shared_closing = True
            self.shared_continuous = False
            if not self.share.ending:
                self.share.end()
            return
        super().closeEvent(event)

    def _shared_ended(self):
        self.shared_continuous = False
        self.cont_btn.blockSignals(True)
        self.cont_btn.setChecked(False)
        self.cont_btn.blockSignals(False)
        self.cont_btn.setText('连续采集')
        if self.shared_closing:
            self.shared_released = True
            self.share.shutdown()
            self.close()
