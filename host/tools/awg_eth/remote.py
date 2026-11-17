"""V2.1 remote service: raw data transfer, exclusive leases, analysis on the client PC."""
from __future__ import annotations
import argparse
import base64
import json
import os
import socket
import socketserver
import struct
import threading
import numpy as np
from .awg import pool_slots
from .device import open_device
from board_share.client import Lease, credentials

PROTOCOL = "47dr-remote-v21-1"
MAX_FRAME = 16 * 1024 * 1024
TIMEOUT = 120


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
    body = json.dumps(obj, separators=(",", ":")).encode("ascii")
    if len(body) > MAX_FRAME:
        raise ValueError("frame too large")
    sock.sendall(struct.pack("!I", len(body)) + body)


def encode_arrays(channels):
    return {str(ch): base64.b64encode(np.asarray(data, dtype="<u4").tobytes()).decode("ascii")
            for ch, data in channels.items()}


def decode_arrays(channels):
    if not isinstance(channels, dict) or not 1 <= len(channels) <= 8:
        raise ValueError("expected 1..8 channels")
    result = {}
    for key, value in channels.items():
        if key not in {str(ch) for ch in range(8)} or not isinstance(value, str):
            raise ValueError("invalid channel")
        raw = base64.b64decode(value, validate=True)
        if not raw or len(raw) % 4:
            raise ValueError("invalid packed samples")
        result[int(key)] = np.frombuffer(raw, dtype="<u4")
    return result


class RemoteServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, *, fpga_ip, fpga_port=9100, words=2048, board_share_url=None):
        self.fpga_ip, self.fpga_port, self.words = fpga_ip, fpga_port, words
        self.board_share_url = board_share_url
        self.owner = threading.Lock()
        super().__init__(address, Handler)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(TIMEOUT)
        acquired = False
        client = awg = None
        lease = None
        try:
            hello = receive(sock)
            if (not isinstance(hello, dict) or hello.get("action") != "connect"
                    or hello.get("protocol") != PROTOCOL
                    or set(hello) - {"action", "protocol", "board_ticket"}):
                send(sock, {"ok": 0, "message": "remote protocol mismatch; update client and service together"})
                return
            if "board_ticket" in hello and not self.server.board_share_url:
                send(sock, {"ok": 0, "message": "控制服务尚未启用板卡共用检查，请先配置 --board-share-url。"})
                return
            acquired = self.server.owner.acquire(blocking=False)
            if not acquired:
                send(sock, {"ok": 0, "message": "board is busy: another remote session owns it"})
                return
            try:
                if self.server.board_share_url:
                    lease = Lease(self.server.board_share_url, hello.get("board_ticket"),
                                  "47DR", "47DR 远程下载与测试")
                client, awg, info = open_device(self.server.fpga_ip, self.server.fpga_port, self.server.words)
                send(sock, {"ok": 1, "protocol": PROTOCOL, "info": info})
            except Exception as exc:
                send(sock, {"ok": 0, "message": str(exc)})
                return
            while True:
                request = receive(sock)
                action = request.get("action")
                if action == "disconnect":
                    awg.close()
                    client.close()
                    awg = client = None
                    self.server.owner.release()
                    acquired = False
                    if lease:
                        lease.close()
                        lease = None
                    send(sock, {"ok": 1})
                    return
                try:
                    if action == "status":
                        result = {"status": awg.status()}
                    elif action == "load_words":
                        channels = decode_arrays(request["channels"])
                        samples, mask = request["samples"], request["mask"]
                        if type(samples) is not int or type(mask) is not int or not 1 <= mask <= 255:
                            raise ValueError("invalid samples or mask")
                        if set(channels) != {ch for ch in range(8) if mask & (1 << ch)}:
                            raise ValueError("channel mask does not match data")
                        if not 32 <= samples <= awg.max_tx_samples(len(channels)) or samples % 32:
                            raise ValueError("waveform exceeds V2.1 pooled capacity or is not 32-point aligned")
                        if any(len(v) != samples // 2 for v in channels.values()):
                            raise ValueError("waveform sample count mismatch")
                        if type(request.get("verify", True)) is not bool:
                            raise ValueError("verify must be boolean")
                        if awg.status()["running"]:
                            raise RuntimeError("DAC is playing; stop playback manually before downloading")
                        st = awg.load_words(channels, samples, mask, verify=request.get("verify", True))
                        result = {"status": st, "write_s": awg.last_write_seconds}
                    elif action in {"start", "stop", "clear"}:
                        result = {"status": getattr(awg, action)()}
                    elif action == "capture_raw":
                        count, word, data = awg.capture_raw(request.get("trigger", "manual"),
                            request.get("mask", 1), samples=request.get("samples", 65520), slots=request.get("slots"))
                        if count != request.get("samples", 65520):
                            raise RuntimeError("capture sample count mismatch")
                        result = {"count": count, "cap_tx_word": word, "channels": encode_arrays(data),
                                  "read_s": awg.last_read_seconds, "status": awg.status()}
                    elif action == "abort_capture":
                        awg.abort_capture()
                        result = {"status": awg.status()}
                    else:
                        raise ValueError("unsupported action")
                    send(sock, {"ok": 1, **result})
                except Exception as exc:
                    send(sock, {"ok": 0, "message": str(exc)})
        except (OSError, EOFError, ValueError, RuntimeError):
            pass
        finally:
            if awg:
                awg.close()
            if client:
                client.close()
            if acquired:
                self.server.owner.release()
            if lease:
                try:
                    lease.close()
                except RuntimeError:
                    pass  # Durable operation remains blocked for manual reconciliation.


class RemoteClient:
    def __init__(self, host, port=4748, *, board_ticket=None):
        if board_ticket is None and os.environ.get("BOARD_SHARE_TICKET_FILE"):
            board_ticket = credentials()["ticket"]
        self.socket = socket.create_connection((host, port), timeout=10)
        self.socket.settimeout(TIMEOUT)
        try:
            hello = {"action": "connect", "protocol": PROTOCOL}
            if board_ticket is not None:
                hello["board_ticket"] = board_ticket
            send(self.socket, hello)
            self.info = self._check(receive(self.socket))["info"]
        except BaseException:
            self.socket.close()
            raise

    @staticmethod
    def _check(reply):
        if not reply.get("ok"):
            raise RuntimeError(reply.get("message", "remote operation failed"))
        return reply

    def request(self, action, **parameters):
        send(self.socket, {"action": action, **parameters})
        return self._check(receive(self.socket))

    def close(self):
        try:
            self.request("disconnect")
        except (OSError, EOFError, ValueError):
            pass
        finally:
            self.socket.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class RemoteAwg:
    """Awg-shaped proxy; release after output/single capture, retain during continuous capture."""
    remote = True

    def __init__(self, host, port=4748, progress_callback=None):
        self.host, self.port = host, port
        self.peer = None
        self.progress_callback = progress_callback
        self.last_write_seconds = self.last_read_seconds = 0.0
        self.info = self._connect().info
        self.release()

    def _connect(self):
        if self.peer is None:
            self.peer = RemoteClient(self.host, self.port)
        return self.peer

    def _request(self, action, **parameters):
        try:
            return self._connect().request(action, **parameters)
        except BaseException:
            self.release()
            raise

    def release(self):
        if self.peer:
            peer = self.peer
            self.peer = None
            peer.close()

    close = release

    def status(self):
        held = self.peer is not None
        try:
            return self._request("status")["status"]
        finally:
            if not held:
                self.release()

    def max_tx_samples(self, n_channels):
        return 1048576 // pool_slots(n_channels)

    def max_capture_samples(self, n_channels):
        return 1966080 // pool_slots(n_channels)

    def load_words(self, channels, samples, channel_mask, *, verify=True, cancel=None):
        if cancel and cancel():
            raise RuntimeError("cancelled")
        result = self._request("load_words", channels=encode_arrays(channels), samples=samples,
                               mask=channel_mask, verify=verify)
        self.last_write_seconds = result["write_s"]
        return result["status"]

    def start(self):
        return self._request("start")["status"]

    def stop(self):
        return self._request("stop")["status"]

    def clear(self):
        return self._request("clear")["status"]

    def abort_capture(self):
        return self._request("abort_capture")

    def capture_raw(self, trigger="manual", channel_mask=1, *, samples=65520, slots=None, cancel=None):
        if cancel and cancel():
            raise RuntimeError("cancelled")
        result = self._request("capture_raw", trigger=trigger, mask=channel_mask, samples=samples, slots=slots)
        self.last_read_seconds = result["read_s"]
        return result["count"], result["cap_tx_word"], decode_arrays(result["channels"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    server = sub.add_parser("serve")
    server.add_argument("--bind", default="127.0.0.1")
    server.add_argument("--port", type=int, default=4748)
    server.add_argument("--fpga-ip", required=True)
    server.add_argument("--fpga-port", type=int, default=9100)
    server.add_argument("--board-share-url", help="启用整场实验占用检查，例如 http://127.0.0.1:4749")
    client = sub.add_parser("call")
    client.add_argument("--host", required=True)
    client.add_argument("--port", type=int, default=4748)
    client.add_argument("action", choices=["status", "stop"])
    args = parser.parse_args()
    if args.mode == "serve":
        with RemoteServer((args.bind, args.port), fpga_ip=args.fpga_ip, fpga_port=args.fpga_port,
                          board_share_url=args.board_share_url) as service:
            print(f"V2.1 service listening on {args.bind}:{args.port}", flush=True)
            service.serve_forever()
    else:
        with RemoteClient(args.host, args.port) as peer:
            print(json.dumps(peer.request(args.action), indent=2))


if __name__ == "__main__":
    main()
