"""Framed JSON client and single-owner remote 47DR service (use over Tailscale)."""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import socket
import socketserver
import struct
import tempfile
import threading

from .gui_bridge import GuiBridge, write_fields

MAX_FRAME = 16 * 1024 * 1024
TIMEOUT = 300


def _receive_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        block = sock.recv(min(count - len(data), 65536))
        if not block:
            raise EOFError("connection closed")
        data.extend(block)
    return bytes(data)


def receive(sock):
    size = struct.unpack("!I", _receive_exact(sock, 4))[0]
    if not 1 <= size <= MAX_FRAME:
        raise ValueError("invalid frame size")
    obj = json.loads(_receive_exact(sock, size).decode("utf-8"))
    if not isinstance(obj, dict):
        raise ValueError("frame must contain an object")
    return obj


def send(sock, obj):
    body = json.dumps(obj, separators=(",", ":"), ensure_ascii=True).encode("ascii")
    if len(body) > MAX_FRAME:
        raise ValueError("frame too large")
    sock.sendall(struct.pack("!I", len(body)) + body)


def unpack_files(files, folder):
    if not isinstance(files, dict) or not 1 <= len(files) <= 9:
        raise ValueError("invalid waveform files")
    allowed = {"waveform.meta", *(f"ch{i}.hex" for i in range(8))}
    if "waveform.meta" not in files or not set(files).issubset(allowed):
        raise ValueError("unexpected waveform filename")
    for name, encoded in files.items():
        if not isinstance(encoded, str):
            raise ValueError("invalid waveform file")
        (folder / name).write_bytes(base64.b64decode(encoded, validate=True))


class RemoteServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, *, fpga_ip, fpga_port=9100, words=256, workdir=None):
        self.fpga_ip = fpga_ip
        self.fpga_port = fpga_port
        self.words = words
        self.workdir = workdir
        self.owner = threading.Lock()
        super().__init__(address, Handler)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(TIMEOUT)
        acquired = False
        bridge = None
        try:
            hello = receive(sock)
            if hello.get("action") != "connect":
                send(sock, {"ok": 0, "message": "expected connect"})
                return
            acquired = self.server.owner.acquire(blocking=False)
            if not acquired:
                send(sock, {"ok": 0, "message": "board is busy: another remote session owns it"})
                return
            with tempfile.TemporaryDirectory(prefix="remote_", dir=self.server.workdir) as temp:
                session = Path(temp)
                write_fields(session / "config.txt", {"fpga_ip": self.server.fpga_ip,
                             "port": self.server.fpga_port, "words_per_packet": self.server.words})
                bridge = GuiBridge(session)
                try:
                    send(sock, bridge.connect())
                except Exception as exc:
                    send(sock, {"ok": 0, "message": str(exc)})
                    return
                while True:
                    request = receive(sock)
                    action = request.get("action")
                    if action == "disconnect":
                        bridge.client.close()
                        bridge.client = None
                        self.server.owner.release()
                        acquired = False
                        send(sock, {"ok": 1, "message": "disconnected"})
                        return
                    try:
                        if action not in {"status", "start", "stop", "clear", "load", "capture", "run"}:
                            raise ValueError("unsupported action")
                        fields = {key: str(request[key]) for key in ("verify", "samples", "mask", "trigger") if key in request}
                        fields["action"] = action
                        if action in {"load", "run"}:
                            wave = session / "wave"
                            wave.mkdir(exist_ok=True)
                            for item in wave.iterdir():
                                item.unlink()
                            unpack_files(request.get("files"), wave)
                            fields["directory"] = str(wave)
                        if action in {"capture", "run"}:
                            fields["capture"] = str(session / "capture.csv")
                        result = bridge.dispatch(fields)
                        if action in {"capture", "run"}:
                            result.pop("capture", None)
                            result["capture_csv"] = base64.b64encode((session / "capture.csv").read_bytes()).decode("ascii")
                            result["capture_json"] = base64.b64encode((session / "capture.json").read_bytes()).decode("ascii")
                        send(sock, result)
                    except Exception as exc:
                        send(sock, {"ok": 0, "message": str(exc), "state": "check board status before retrying"})
        except (OSError, EOFError, ValueError, json.JSONDecodeError):
            pass
        finally:
            if bridge and bridge.client:
                bridge.client.close()
            if acquired:
                self.server.owner.release()


class RemoteClient:
    def __init__(self, host, port):
        self.socket = socket.create_connection((host, port), timeout=15)
        self.socket.settimeout(TIMEOUT)
        try:
            send(self.socket, {"action": "connect"})
            self.info = receive(self.socket)
            self._check(self.info)
        except BaseException:
            self.socket.close()
            raise

    @staticmethod
    def _check(reply):
        if not reply.get("ok"):
            raise RuntimeError(reply.get("message", "remote operation failed"))
        return reply

    def request(self, action, *, waveform=None, capture=None, **parameters):
        if action in {"capture", "run"}:
            if capture is None:
                raise ValueError("capture output path is required")
            path = Path(capture)
            if path.exists() or path.with_suffix(".json").exists():
                raise FileExistsError("capture output already exists")
        request = {"action": action, **parameters}
        if waveform is not None:
            folder = Path(waveform)
            names = ["waveform.meta", *(f"ch{i}.hex" for i in range(8))]
            request["files"] = {name: base64.b64encode((folder / name).read_bytes()).decode("ascii")
                                for name in names if (folder / name).is_file()}
        send(self.socket, request)
        result = self._check(receive(self.socket))
        if "capture_csv" in result:
            if capture is None:
                raise ValueError("capture output path is required")
            path = Path(capture)
            if path.exists() or path.with_suffix(".json").exists():
                raise FileExistsError("capture output already exists")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(base64.b64decode(result.pop("capture_csv"), validate=True))
            path.with_suffix(".json").write_bytes(base64.b64decode(result.pop("capture_json"), validate=True))
            result["capture"] = str(path)
        return result

    def close(self):
        try:
            send(self.socket, {"action": "disconnect"})
            receive(self.socket)
        except (OSError, EOFError, ValueError):
            pass
        finally:
            self.socket.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    server = sub.add_parser("serve")
    server.add_argument("--bind", default="127.0.0.1")
    server.add_argument("--port", type=int, default=4748)
    server.add_argument("--fpga-ip", required=True)
    server.add_argument("--fpga-port", type=int, default=9100)
    server.add_argument("--words", type=int, default=256)
    client = sub.add_parser("call")
    client.add_argument("--host", required=True)
    client.add_argument("--port", type=int, default=4748)
    client.add_argument("action", choices=["status", "start", "stop", "clear", "load", "capture", "run"])
    client.add_argument("--waveform")
    client.add_argument("--capture")
    client.add_argument("--samples", type=int, default=65520)
    client.add_argument("--mask", type=lambda s: int(s, 0), default=255)
    client.add_argument("--trigger", choices=["manual", "start"], default="manual")
    args = parser.parse_args()
    if args.mode == "serve":
        with RemoteServer((args.bind, args.port), fpga_ip=args.fpga_ip,
                          fpga_port=args.fpga_port, words=args.words) as service:
            print(f"Listening on {args.bind}:{args.port}", flush=True)
            service.serve_forever()
    else:
        if args.action in {"load", "run"} and not args.waveform:
            parser.error("--waveform is required")
        if args.action in {"capture", "run"} and not args.capture:
            parser.error("--capture is required")
        with RemoteClient(args.host, args.port) as peer:
            result = peer.request(args.action, waveform=args.waveform, capture=args.capture,
                                  samples=args.samples, mask=args.mask, trigger=args.trigger, verify=1)
            print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
