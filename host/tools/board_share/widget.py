"""Shared native Qt status/task strip, used unchanged by both desktop clients."""
import copy
import json
import os
import threading
import time
from pathlib import Path
from PySide6.QtCore import QTimer, Signal
from PySide6.QtWidgets import QWidget, QHBoxLayout, QLabel, QPushButton, QComboBox, QInputDialog, QMessageBox
from .session import Session


class ShareWidget(QWidget):
    delivered = Signal(object, object, object)
    changed = Signal(dict)
    event_received = Signal(dict)
    ended = Signal()

    def __init__(self, project, parent=None, url=None):
        super().__init__(parent)
        self.project = project
        self.session = None
        self.snapshot = {}
        self.pending = False
        self.polling = False
        self.ending = False
        self.cursor = 0
        self.callback = None
        self.url = url
        self.folder = Path(os.environ.get("LOCALAPPDATA", Path.home() / '.local/share')) / 'FPGA-BoardShare' / project
        self.label = QLabel("板卡共用：未连接")
        self.identity = QPushButton("连接共用服务")
        self.package = QComboBox()
        self.cancel_button = QPushButton("取消排队")
        self.end_button = QPushButton("结束使用")
        self.recover_button = QPushButton("重新初始化并恢复")
        layout = QHBoxLayout(self)
        for w in (self.label, self.identity, self.package, self.cancel_button, self.end_button, self.recover_button):
            layout.addWidget(w)
        layout.setStretch(0, 1)
        self.identity.clicked.connect(self.configure)
        self.cancel_button.clicked.connect(lambda: self.background(lambda: self.session.call('cancel'), self._display))
        self.end_button.clicked.connect(self.end)
        self.recover_button.clicked.connect(self.recover)
        self.delivered.connect(self._delivered)
        self.timer = QTimer(self)
        self.timer.setInterval(2000)
        self.timer.timeout.connect(self.poll)
        self.timer.start()
        self._buttons()

    def background(self, work, done):
        def run():
            try:
                value, error = work(), None
            except Exception as exc:
                value, error = None, str(exc)
            self.delivered.emit(done, value, error)
        threading.Thread(target=run, daemon=True).start()

    def _delivered(self, done, value, error):
        done(value, error)

    def configure(self):
        if self.session:
            name, ok = QInputDialog.getText(self, "使用人", "姓名", text=self.session.name)
            if ok:
                self.background(lambda: self.session.identify(name), lambda v, e: self.poll() if not e else self.label.setText(e))
            return
        url, ok = QInputDialog.getText(self, "实验室共用服务", "服务地址", text=self.url or 'http://100.121.70.53:4749')
        if not ok:
            return
        try:
            session = Session(url, self.folder / 'identity.json')
        except Exception as exc:
            self.label.setText(str(exc))
            return
        name = session.name
        if not session.token:
            name, ok = QInputDialog.getText(self, "使用人", "首次使用请输入姓名（以后自动记住）")
            if not ok:
                return
        def connect():
            session.identify(name)
            session.start()
            return session.call('status')
        def ready(value, error):
            if not error:
                self.session = session
                self.url = url
                self.identity.setText(name)
            self._display(value, error)
        self.background(connect, ready)

    def connect_saved(self):
        path = self.folder / 'identity.json'
        if not path.exists():
            self.configure()
            return
        try:
            saved = json.loads(path.read_text(encoding='utf-8'))
            session = Session(self.url or saved['url'], path)
            if not session.token:
                self.configure()
                return
        except Exception as exc:
            self.label.setText(str(exc))
            return
        def ready(value, error):
            if not error:
                self.session = session
                session.start()
                self.identity.setText(session.name)
            self._display(value, error)
        self.background(lambda: session.call('status'), ready)

    def _buttons(self):
        self.cancel_button.setEnabled(bool(self.session and self.pending))
        self.end_button.setEnabled(bool(self.session and (self.snapshot.get('mine') or self.pending)))
        self.recover_button.setEnabled(bool(self.session and self.snapshot.get('phase') == 'recovery' and
                                           self.snapshot.get('can_recover', False)))
        self.package.setEnabled(not self.pending and not self.ending)

    def poll(self):
        if not self.session or self.polling:
            return
        self.polling = True
        def work():
            status = self.session.call('status')
            events = self.session.call('events', {'after': self.cursor}) if status.get('mine') and status['phase'] == 'owned' else None
            return status, events
        def done(value, error):
            self.polling = False
            if error:
                self._display(None, error)
                return
            status, events = value
            self._display(status, None)
            if events:
                if events['lost']:
                    self.event_received.emit({'kind': 'error', 'value': '远程遥测缓冲溢出，部分数据丢失'})
                for item in events['events']:
                    self.event_received.emit(item)
                self.cursor = events['cursor']
        self.background(work, done)

    def _display(self, status, error=None):
        if error:
            self.label.setText('服务连接中断 · FPGA 状态未确认 · ' + error)
            return
        if status is None:
            return
        self.snapshot = status
        owner = status.get('owner')
        state = {'recovery': '待恢复', 'recovering': '正在恢复', 'closing': '正在结束使用…', 'ready': '空闲', 'owned': '使用中'}.get(status['phase'], status['phase'])
        who = f"{owner['name']} · {status.get('project')}" if owner else '无人使用'
        hw = status['hardware']
        verified = hw.get('verified_project') or '未确认'
        if hw.get('checked_at'):
            verified += '（上次确认 ' + time.strftime('%H:%M:%S', time.localtime(hw['checked_at'])) + '）'
        names = '、'.join(x['name'] for x in status['queue']) or '无'
        self.label.setText(f"服务已连接 · FPGA {verified} · {state} · {who} · 排队：{names}")
        self.label.setToolTip(status.get('error') or '')
        current = self.package.currentText()
        keys = [p['key'] for p in status['packages'] if p['project'] == self.project]
        if keys != [self.package.itemText(i) for i in range(self.package.count())]:
            self.package.clear()
            self.package.addItems(keys)
            if current in keys:
                self.package.setCurrentText(current)
        self._buttons()
        self.changed.emit(status)
        if self.ending and not status.get('mine'):
            self.ending = False
            self.ended.emit()
        elif self.ending and status['phase'] == 'recovery':
            self.ending = False
            self.label.setText('清理未确认，已阻止交接：' + (status.get('error') or '待恢复'))

    def submit(self, operation, parameters, done):
        if not self.session:
            self.configure()
            return False
        if self.pending or self.ending:
            self.label.setText('已有待执行任务；请取消后重新提交')
            return False
        package = self.package.currentText()
        if not package:
            self.label.setText('实验室尚未登记本工程固件包')
            return False
        owner = self.snapshot.get('owner')
        enqueue = bool(owner and not self.snapshot.get('mine'))
        if enqueue:
            response = QMessageBox.question(self, '有人正在使用',
                f"{owner['name']} 正在使用 {self.snapshot.get('project')}。\n加入队列后，将自动加载 {package} 并执行本次操作；参数和数据保持本次提交值。",
                QMessageBox.Yes | QMessageBox.No)
            if response != QMessageBox.Yes:
                return False
        elif not self.snapshot.get('mine'):
            if QMessageBox.question(self, '切换到本工程', f'允许加载实验室版本 {package} 并执行本次操作？') != QMessageBox.Yes:
                return False
        frozen = copy.deepcopy(parameters)
        self.pending = True
        self._buttons()
        self.label.setText('正在提交…' if not enqueue else '正在加入队列…')
        def work():
            job = self.session.submit(self.project, operation, frozen, package, enqueue=enqueue, switch=True)
            return self.session.wait(job)
        def finished(value, error):
            self.pending = False
            self._buttons()
            if error:
                self.label.setText(error)
            done(value, error)
            self.poll()
        self.background(work, finished)
        return True

    def end(self):
        if not self.session:
            self.ended.emit()
            return
        self.ending = True
        self.label.setText('正在结束使用…')
        def finished(value, error):
            if error:
                self.ending = False
            self._display(value, error)
        self.background(self.session.end, finished)

    def recover(self):
        if self.pending:
            return
        package = self.package.currentText()
        if not package or QMessageBox.question(self, '重新初始化并恢复', f'将重新初始化 FPGA 并加载 {package}。继续？') != QMessageBox.Yes:
            return
        self.pending = True
        self._buttons()
        def work():
            job = self.session.call('recover', {'project': self.project, 'package': package, 'confirmed': True})['id']
            return self.session.wait(job)
        def done(value, error):
            self.pending = False
            self._buttons()
            if error:
                self.label.setText(error)
            self.poll()
        self.background(work, done)

    def shutdown(self):
        self.timer.stop()
        if self.session:
            self.session.stop.set()
