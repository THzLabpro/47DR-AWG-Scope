"""Opt-in operation gate. An enabled but unavailable service always blocks."""
import json
import os
import uuid
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler
from .state import ticket_hash


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def request(url, ticket, action, data=None):
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.netloc or parts.username or parts.query or parts.fragment:
        raise RuntimeError("板卡共用服务地址格式不正确。")
    ticket_hash(ticket)
    body = json.dumps(data or {}).encode() if action != "status" else None
    req = Request(url.rstrip("/") + "/api/" + action, data=body,
                  headers={"Authorization": "Bearer " + ticket, "Content-Type": "application/json"})
    try:
        # Do not route the lab coordination endpoint through desktop proxy settings.
        with build_opener(ProxyHandler({}), NoRedirect()).open(req, timeout=3) as response:
            return json.load(response)
    except HTTPError as exc:
        try:
            message = json.load(exc).get("message", "占用检查失败。")
        except (ValueError, AttributeError):
            message = "占用检查失败。"
        raise RuntimeError(message) from None
    except (OSError, URLError, ValueError):
        raise RuntimeError("无法确认板卡占用，操作未获准。请检查共用服务后重试。") from None


def credentials(path=None):
    path = path or os.environ.get("BOARD_SHARE_TICKET_FILE")
    if not path:
        raise RuntimeError("请先选择从共用面板保存的领用文件。")
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        ticket_hash(data["ticket"])
        if not isinstance(data["url"], str):
            raise ValueError()
        return data
    except (OSError, ValueError, KeyError, TypeError):
        raise RuntimeError("领用文件无法读取，请从共用面板重新保存。") from None


class Lease:
    def __init__(self, url, ticket, project, label):
        self.url, self.ticket = url, ticket
        self.id = uuid.uuid4().hex
        self.closed = False
        request(url, ticket, "begin", dict(project=project, label=label, operation_id=self.id))

    def close(self):
        if not self.closed:
            request(self.url, self.ticket, "end", {"operation_id": self.id})
            self.closed = True


def from_environment(project, label):
    url = os.environ.get("BOARD_SHARE_URL")
    ticket_file = os.environ.get("BOARD_SHARE_TICKET_FILE")
    if not url and not ticket_file:
        return None  # Existing installations remain unchanged until deployment.
    data = credentials()
    return Lease(url or data["url"], data["ticket"], project, label)
