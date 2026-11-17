"""Persisted desktop identity and asynchronous-task client (no ticket import)."""
import json
import threading
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler
from .client import NoRedirect


class Session:
    def __init__(self, url, identity_path):
        from urllib.parse import urlsplit
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.netloc or parts.username or parts.query or parts.fragment:
            raise ValueError("服务地址无效")
        self.url = url.rstrip("/")
        self.path = Path(identity_path)
        self.token = None
        self.name = ""
        if self.path.exists():
            stored = json.loads(self.path.read_text(encoding="utf-8"))
            if stored.get("url") == self.url:
                self.token, self.name = stored["token"], stored["name"]
        self.stop = threading.Event()
        self.thread = None

    def call(self, action, data=None):
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = Request(self.url + "/v2/" + action, json.dumps(data or {}, allow_nan=False).encode(), headers)
        try:
            with build_opener(ProxyHandler({}), NoRedirect()).open(req, timeout=10) as response:
                return json.load(response)
        except HTTPError as exc:
            raise RuntimeError(json.load(exc).get("message", "操作失败")) from None

    def identify(self, name):
        if self.token:
            self.call("rename", {"name": name})
        else:
            self.token = self.call("register", {"name": name})["token"]
        self.name = name
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Per-user app data, never a project/shared folder. No secret in logs.
        self.path.write_text(json.dumps({"url": self.url, "token": self.token, "name": name}), encoding="utf-8")

    def start(self):
        def beat():
            while not self.stop.is_set():
                try:
                    self.call("heartbeat")
                except Exception:
                    pass  # UI status polling independently reports connection failures.
                self.stop.wait(3)
        if self.thread is None:
            self.thread = threading.Thread(target=beat, daemon=True)
            self.thread.start()

    def submit(self, project, operation, parameters, package, *, enqueue=False, switch=False):
        return self.call("submit", dict(project=project, operation=operation, parameters=parameters,
                                       package=package, enqueue=enqueue, switch=switch))["id"]

    def wait(self, job, cancel=None):
        while True:
            result = self.call("result", {"id": job})
            if result["state"] == "done":
                return result["result"]
            if result["state"] in ("failed", "cancelled"):
                raise RuntimeError(result["error"] or "任务已取消")
            if cancel is not None and cancel.is_set():
                self.call("cancel")
            time.sleep(.15)

    def end(self):
        return self.call("end")

    def close(self):
        self.stop.set()
        if self.thread:
            self.thread.join(11)
