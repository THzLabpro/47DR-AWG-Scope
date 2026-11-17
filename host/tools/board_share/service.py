"""Version 2 service API. No hardware adapters are constructed implicitly."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from .coordinator import Rejected


class Service(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, coordinator):
        self.coordinator = coordinator
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def do_POST(self):
        code = 200
        try:
            if self.headers.get("Origin") and urlsplit(self.headers["Origin"]).netloc != self.headers.get("Host"):
                raise Rejected("来源不允许。")
            if not self.path.startswith("/v2/"):
                raise Rejected("接口版本不匹配。")
            n = int(self.headers.get("Content-Length", 0))
            if not 0 < n <= 32 * 1024 * 1024:
                raise Rejected("请求长度不正确。")
            data = json.loads(self.rfile.read(n))
            if not isinstance(data, dict):
                raise Rejected("请求内容不正确。")
            token = self.headers.get("Authorization", "").removeprefix("Bearer ")
            action = self.path[4:]
            result = (self.server.coordinator.status(token) if action == "status"
                      else self.server.coordinator.act(action, token, data))
        except (ValueError, OSError) as exc:
            code, result = 409, {"message": str(exc)}
        except Exception:
            code, result = 503, {"message": "服务暂不可用，板卡状态未确认。"}
        body = json.dumps(result, ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)
