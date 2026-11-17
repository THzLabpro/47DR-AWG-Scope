"""Small shared panel/API; no FPGA probing, flashing, or subprocess execution."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from .state import Store, Conflict


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, state_file):
        self.store = Store(state_file)
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *_):
        pass  # No request bodies, credentials or client identifiers in console logs.

    def reply(self, status, value, content_type="application/json; charset=utf-8"):
        body = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)

    def ticket(self):
        auth = self.headers.get("Authorization", "")
        return auth[7:] if auth.startswith("Bearer ") else None

    def do_GET(self):
        if self.path == "/":
            self.reply(200, Path(__file__).with_name("panel.html").read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/api/status":
            try:
                self.reply(200, self.server.store.status(self.ticket()))
            except Conflict as exc:
                self.reply(409, {"message": str(exc)})
        else:
            self.reply(404, {"message": "页面不存在。"})

    def do_POST(self):
        # Browser writes must originate from this panel, never a third-party page.
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).netloc != self.headers.get("Host"):
            self.reply(403, {"message": "请从共用面板操作。"})
            return
        if not self.path.startswith("/api/"):
            self.reply(404, {"message": "接口不存在。"})
            return
        try:
            if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                raise Conflict("请求需使用 JSON。")
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 8192:
                raise Conflict("请求长度不正确。")
            data = json.loads(self.rfile.read(size))
            if not isinstance(data, dict):
                raise Conflict("请求内容不正确。")
            result = self.server.store.act(self.path[5:], self.ticket(), data)
            self.reply(200, result)
        except (ValueError, UnicodeError) as exc:
            self.reply(409, {"message": str(exc)})
        except Exception:
            self.reply(503, {"message": "登记服务暂不可用；占用状态未确认，请稍后刷新。"})
