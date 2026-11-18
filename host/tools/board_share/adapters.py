"""Lab-only hardware adapters. Importing this module performs no hardware I/O.

Commands and paths come exclusively from the lab administrator's catalog. Client
requests supply bounded numeric/enumerated parameters, never executable paths.
"""
import base64
from collections import deque
import json
import math
import os
import re
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from .coordinator import Rejected


def command(argv, cancel, timeout=300, cwd=None):
    env = dict(os.environ, PROCESSOR_ARCHITECTURE="AMD64")
    env.pop("NoDefaultCurrentDirectoryInExePath", None)
    env.pop("PSModulePath", None)
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    with tempfile.TemporaryFile() as output:
        p = subprocess.Popen(argv, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT,
                             creationflags=flags)
        deadline = time.monotonic() + timeout
        while p.poll() is None:
            if cancel.wait(.1) or time.monotonic() >= deadline:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   creationflags=flags, timeout=15, check=True)
                else:
                    p.kill()
                p.wait(timeout=15)
                raise RuntimeError("操作已取消或超时，需确认板卡状态")
        output.seek(0)
        text = output.read().decode("utf-8", errors="replace")
        if p.returncode:
            raise RuntimeError(f"实验室硬件命令失败（退出码 {p.returncode}）: {text[-1500:]}")
        return text


class Events:
    def __init__(self):
        self.items = deque(maxlen=2048)
        self.sequence = 0
        self.lock = threading.Lock()

    def emit(self, kind, value):
        with self.lock:
            self.sequence += 1
            self.items.append({"id": self.sequence, "kind": kind, "value": value})

    def read(self, after):
        if type(after) is not int or after < 0:
            raise Rejected("事件游标不正确")
        with self.lock:
            return {"events": [x for x in self.items if x["id"] > after],
                    "cursor": self.sequence,
                    "lost": bool(self.items and after and after < self.items[0]["id"] - 1)}


class HardwareAdapter:
    def __init__(self, config):
        self.config = config
        self.package = None
        self.evidence = {"responsive": False, "verified_project": None}
        self.event_buffer = Events()

    def events(self, after):
        return self.event_buffer.read(after)

    def begin_experiment(self):
        with self.event_buffer.lock:
            self.event_buffer.items.clear()

    def verify(self):
        return dict(self.evidence)

    def program(self, package, cancel):
        # A complete immutable package includes every command/script dependency in files.
        output = command(package["program"], cancel, cwd=self.config.get("root"))
        if package["program_pass"] not in output:
            raise RuntimeError("初始化命令没有返回成功标记")
        self.event_buffer.emit("log", output)
        self.package = package

    def recover(self, package, cancel):
        self.program(package, cancel)
        return self.execute({"operation": "status", "parameters": {}, "package": package}, cancel)


class AwgAdapter(HardwareAdapter):
    operations = {"connect", "status", "load_words", "start", "stop", "clear", "capture_raw", "abort_capture", "program", "recover"}

    def __init__(self, config):
        super().__init__(config)
        self.client = self.awg = None

    def validate(self, task):
        if task["operation"] not in self.operations or not isinstance(task["parameters"], dict):
            raise Rejected("47DR 操作无效")

    def _open(self):
        if self.awg is None:
            from awg_eth.device import open_device
            self.client, self.awg, self.info = open_device(self.config["fpga_ip"], self.config.get("fpga_port", 9100), 2048)

    @staticmethod
    def _link_timeout(exc):
        from awg_eth.client import AwgEthError
        return (isinstance(exc, TimeoutError) or
                (isinstance(exc, AwgEthError) and str(exc).startswith("FPGA timeout")) or
                (isinstance(exc, RuntimeError) and
                 str(exc).startswith("V2.1 bulk port unavailable")))

    def _wait_ready(self, cancel, seconds):
        deadline = time.monotonic() + seconds
        while True:
            if cancel.is_set():
                raise RuntimeError('操作已取消')
            try:
                self._open()
                status = self.awg.status()
                if status.get('fault') or status.get('fault_channels'):
                    raise ValueError('FPGA 故障状态，不能恢复网卡')
                if status.get('ps_ready'):
                    return
                raise RuntimeError('PS 初始化尚未完成')
            except Exception as exc:
                self._close()
                if not self._link_timeout(exc) and str(exc) != 'PS 初始化尚未完成':
                    raise
                if cancel.wait(.5):
                    raise RuntimeError('操作已取消') from exc
                if time.monotonic() >= deadline:
                    raise

    def _recover_link(self, package, cancel):
        # These administrator commands and helper files belong to the sealed
        # package. No interface names or executable paths come from clients.
        recovery = package['link_recovery']
        self.event_buffer.emit('log', '光口连接超时，正在核对板卡工程和初始化状态。')
        for key, marker in [('verify', 'AWG_F3_JTAG_READY'),
                            ('restart', 'OPTICAL_ADAPTER_RESTARTED')]:
            if cancel.is_set():
                raise RuntimeError('操作已取消')
            output = command(recovery[key], cancel, timeout=180,
                             cwd=self.config.get('root'))
            self.event_buffer.emit('log', output)
            # A marker echoed as part of a Tcl command is not a successful probe.
            if marker not in {line.strip() for line in output.splitlines()}:
                raise RuntimeError('光口恢复检查未通过：' + key)
            if key == 'verify':
                self.event_buffer.emit('log', 'F3 已就绪，正在恢复板卡光口网卡。')

    def program(self, package, cancel):
        self._close()
        super().program(package, cancel)
        try:
            self._wait_ready(cancel, 60)
        except Exception as exc:
            if cancel.is_set() or not self._link_timeout(exc) or not package.get('link_recovery'):
                raise
            self._recover_link(package, cancel)
            self._wait_ready(cancel, 30)
            self.event_buffer.emit('log', '光口恢复完成，控制和批量端口验证通过。')

    def _close(self):
        if self.awg:
            self.awg.close()
        if self.client:
            self.client.close()
        self.awg = self.client = None

    def execute(self, task, cancel):
        from awg_eth.remote import decode_arrays, encode_arrays
        operation, p, package = task["operation"], task["parameters"], task["package"]
        if self.package != package or operation == "program":
            self.program(package, cancel)
        self._open()
        if cancel.is_set():
            raise RuntimeError("任务已取消")
        if operation in ("connect", "program", "status"):
            result = {"info": self.info, "status": self.awg.status()}
        elif operation == "load_words":
            channels = decode_arrays(p["channels"])
            samples, mask = p["samples"], p["mask"]
            if type(samples) is not int or type(mask) is not int or not 1 <= mask <= 255:
                raise ValueError("invalid waveform mask/length")
            if set(channels) != {c for c in range(8) if mask & (1 << c)} or samples % 32 or not 32 <= samples <= self.awg.max_tx_samples(len(channels)):
                raise ValueError("invalid waveform capacity/mask")
            if any(len(x) != samples // 2 for x in channels.values()):
                raise ValueError("waveform length mismatch")
            if self.awg.status()["running"]:
                raise RuntimeError("DAC 正在播放，请先停止播放")
            st = self.awg.load_words(channels, samples, mask, verify=p.get("verify", True), cancel=cancel.is_set)
            if p.get("auto_run"):
                st = self.awg.start()
            result = {"status": st, "write_s": self.awg.last_write_seconds}
            if p.get("capture"):
                result['capture'] = self.execute({"operation": "capture_raw", "parameters": p['capture'], "package": package}, cancel)
        elif operation == "capture_raw":
            count, word, arrays = self.awg.capture_raw(p.get("trigger", "manual"), p.get("mask", 1),
                samples=p.get("samples", 65520), slots=p.get("slots"), cancel=cancel.is_set)
            result = {"count": count, "cap_tx_word": word, "channels": encode_arrays(arrays),
                      "read_s": self.awg.last_read_seconds, "status": self.awg.status()}
        else:
            result = {"status": getattr(self.awg, operation)()}
        if not self.awg.status().get('ps_ready'):
            raise RuntimeError('PS 未就绪')
        self.evidence = {"responsive": True, "verified_project": "47DR", "checked_at": time.time()}
        return result

    def cleanup(self):
        try:
            self._open()
            self.awg.abort_capture()
            self.awg.stop()
            st = self.awg.status()
            stopped = (not st["running"] and not st["busy"] and not st["cap_busy"]
                       and bool(st["ps_ready"]) and not st["fault"])
        finally:
            self._close()
        # Enable after bench acceptance of stop/readback/resource release.
        # This is a digital handoff check, not an RF power measurement.
        return stopped and self.config.get("cleanup_validated") is True


class RfUdpAdapter(HardwareAdapter):
    operations = {"program", "recover", "status", "uart_start", "uart_stop", "lms", "dac", "rate", "traffic", "listen", "listen_stop"}

    def __init__(self, config):
        super().__init__(config)
        self.serial = None
        self.reader = None
        self.read_stop = threading.Event()
        self.udp = self.udp_thread = None
        self.udp_stop = threading.Event()

    def validate(self, task):
        op, p = task["operation"], task["parameters"]
        if op not in self.operations or not isinstance(p, dict):
            raise Rejected("RF-UDP 操作无效")
        if op == "lms" and p.get("value") not in (2, 6):
            raise Rejected("LMS 参数无效")
        if op == "dac" and (type(p.get("value")) is not int or not (p["value"] == 0 or 2250 <= p["value"] <= 40500)):
            raise Rejected("DAC 电流参数无效")
        if op == "rate" and p.get("value") not in ("1M", "10M", "100M", "1000M"):
            raise Rejected("速率档位无效")
        if op == "traffic":
            from host.rfudp_traffic import TrafficConfig
            args = dict(p["config"])
            if args.get('iperf_path'):
                raise Rejected('iperf 路径只能由实验室端配置')
            rates = p.get('rates')
            if rates is not None and (not isinstance(rates, list) or not 1 <= len(rates) <= 64 or
                                      any(type(v) not in (int, float) or not math.isfinite(v) or v <= 0 for v in rates)):
                raise Rejected('扫速率参数无效')
            args.update(bind=self.config["bind"], target=self.config["fpga_ip"])
            TrafficConfig(**args).validate()

    def _command(self, name, cancel, value=None):
        spec = self.config["commands"][name]
        wire_value = {'1M': 3, '10M': 2, '100M': 1, '1000M': 0}[value] if name == 'rate' else value
        argv = [arg.replace("{value}", str(wire_value)) for arg in spec["argv"]]
        output = command(argv, cancel, timeout=spec.get("timeout", 90), cwd=self.config["root"])
        marker = spec["pass"].replace("{value}", str(value))
        if marker not in output:
            raise RuntimeError(f"{name} 回读未确认: {output[-1500:]}")
        if name == 'lms':
            match = re.search(r'AFTER\s+(0x[0-9A-Fa-f]+)', output)
            if not match or int(match[1], 16) != value:
                raise RuntimeError('LMS 回读未确认')
        if name == 'dac':
            match = re.search(r'DAC0_CURRENT_PASS requested=(\d+) actual=(\d+(?:\.\d+)?)', output)
            if not match or int(match[1]) != value:
                raise RuntimeError('DAC 电流回读未确认')
        self.event_buffer.emit("log", output)
        return output

    def _verify(self, cancel):
        output = self._command("identity", cancel)
        # Identity command must print all expected values after reading registers.
        for marker in self.package["identity_markers"]:
            if marker not in output:
                raise RuntimeError("RF-UDP 寄存器身份与固件版本不符")
        self.evidence = {"responsive": True, "verified_project": "RF-UDP", "checked_at": time.time()}

    def program(self, package, cancel):
        self._stop_uart()
        self._stop_udp()
        super().program(package, cancel)
        self._command("lms", cancel, 2)
        self._verify(cancel)

    def _stop_uart(self):
        self.read_stop.set()
        if self.reader:
            self.reader.join(3)
            if self.reader.is_alive():
                raise RuntimeError("串口读取尚未退出")
        if self.serial:
            self.serial.close()
        self.serial = self.reader = None

    def _start_uart(self):
        if self.reader:
            return
        import serial
        self.serial = serial.Serial(self.config.get("serial_port", "COM8"), self.config.get("baud", 115200), timeout=.1)
        self.read_stop.clear()
        def read():
            try:
                while not self.read_stop.is_set():
                    data = self.serial.read(4096)
                    if data:
                        self.event_buffer.emit("uart", base64.b64encode(data).decode())
            except Exception as exc:
                self.event_buffer.emit("error", str(exc))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def _start_udp(self):
        if self.udp:
            return
        import socket
        from host.traffic_telemetry import TelemetrySnapshots
        self.snapshots = TelemetrySnapshots()
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind((self.config["bind"], self.config.get("telemetry_port", 9001)))
        self.udp.settimeout(.2)
        self.udp_stop.clear()
        def read():
            while not self.udp_stop.is_set():
                try:
                    raw, peer = self.udp.recvfrom(65536)
                    from model.telemetry_udp import decode
                    if peer[0] == self.config['fpga_ip']:
                        self.snapshots.push(decode(raw))
                    self.event_buffer.emit("udp", {"data": base64.b64encode(raw).decode(), "peer": list(peer)})
                except socket.timeout:
                    continue
                except Exception as exc:
                    self.event_buffer.emit("error", str(exc))
                    return
        self.udp_thread = threading.Thread(target=read, daemon=True)
        self.udp_thread.start()

    def _stop_udp(self):
        self.udp_stop.set()
        if self.udp_thread:
            self.udp_thread.join(3)
            if self.udp_thread.is_alive():
                raise RuntimeError("UDP 遥测尚未退出")
        if self.udp:
            self.udp.close()
        self.udp = self.udp_thread = None

    def execute(self, task, cancel):
        op, p, package = task["operation"], task["parameters"], task["package"]
        if self.package != package or op == "program":
            self.program(package, cancel)
        if op in ("status", "program"):
            if op == 'status':
                self._verify(cancel)
            return self.verify()
        if op in ("lms", "dac", "rate"):
            return {"output": self._command(op, cancel, p["value"])}
        if op == "uart_start":
            self._command('start_output', cancel)
            self._start_uart()
        elif op == "uart_stop":
            self._stop_uart()
        elif op == "listen":
            self._start_udp()
        elif op == 'listen_stop':
            self._stop_udp()
        elif op == "traffic":
            from host.rfudp_traffic import TrafficConfig, run_traffic, run_sweep
            self._command('start_output', cancel)
            self._start_udp()
            args = dict(p["config"])
            args.update(bind=self.config["bind"], target=self.config["fpga_ip"], telemetry_port=self.config.get("telemetry_port", 9001),
                        iperf_path=str(Path(self.config['root']) / 'host/tools/iperf-1.7.0/iperf.exe'))
            cfg = TrafficConfig(**args)
            progress = lambda row: self.event_buffer.emit("traffic", row)
            return (run_sweep(cfg, p["rates"], progress, cancel, self.snapshots) if p.get("rates")
                    else run_traffic(cfg, progress, cancel, self.snapshots))
        return {"ok": True}

    def cleanup(self):
        errors = []
        # A failed reader must not prevent attempting to stop the FPGA output.
        for stop in (self._stop_uart, self._stop_udp,
                     lambda: self._command("stop_output", threading.Event())):
            try:
                stop()
            except Exception as exc:
                errors.append(str(exc))
        if errors:
            raise RuntimeError("; ".join(errors))
        return self.config.get("cleanup_validated") is True
