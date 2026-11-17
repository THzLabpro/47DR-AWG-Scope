"""Single-board durable scheduler. Hardware is accessible only on its worker thread.

Adapters implement execute(task, cancel), cleanup(), recover(package), and verify().
cleanup/verify must return positive evidence; exceptions never free the board.
"""
import hashlib
import json
import secrets
import sqlite3
import threading
import time
import uuid
from pathlib import Path


class Rejected(ValueError):
    pass


class Catalog:
    def __init__(self, packages=None):
        self.packages = packages or {}

    def resolve(self, key):
        try:
            item = self.packages[key]
        except KeyError:
            raise Rejected("请选择实验室已登记的固件版本。") from None
        files = item.get("files", {})
        if not files:
            raise Rejected("固件包没有校验清单。")
        for path, digest in files.items():
            if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
                raise Rejected("固件包已变化，请重新登记版本并提交任务。")
        identity = hashlib.sha256(json.dumps(item, sort_keys=True).encode()).hexdigest()
        return {**item, "key": key, "identity": identity}

    def public(self):
        return [{"key": k, "project": v["project"]} for k, v in self.packages.items()]


class Coordinator:
    GRACE = 30

    def __init__(self, path, adapters, catalog=None, clock=time.time):
        self.lock = threading.RLock()
        self.clock = clock
        self.adapters = adapters
        self.catalog = catalog or Catalog()
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
          CREATE TABLE IF NOT EXISTS people(token TEXT PRIMARY KEY, id TEXT UNIQUE, name TEXT, seen REAL);
          CREATE TABLE IF NOT EXISTS jobs(seq INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT UNIQUE, token TEXT, payload TEXT, state TEXT, result TEXT, error TEXT);
          CREATE TABLE IF NOT EXISTS board(id INTEGER PRIMARY KEY CHECK(id=1),
            owner TEXT, project TEXT, phase TEXT, error TEXT);
          INSERT OR IGNORE INTO board VALUES(1,NULL,NULL,'recovery','服务启动后板卡状态未确认');
        ''')
        # Never replay queued commands or trust pre-restart physical state.
        self.db.execute("UPDATE jobs SET state='cancelled',error='服务重启，任务未重放' WHERE state IN ('queued','running')")
        self.db.execute("UPDATE board SET phase='recovery',error='服务启动后板卡状态未确认'")
        self.db.commit()
        self.cancel = threading.Event()
        self.wake = threading.Event()
        self.stopping = threading.Event()
        self.cached = {"responsive": False, "verified_project": None}
        self.thread = None

    @staticmethod
    def digest(token):
        if not isinstance(token, str) or len(token) != 64:
            raise Rejected("客户端身份无效，请重新登记。")
        return hashlib.sha256(token.encode()).hexdigest()

    def _person(self, token):
        key = self.digest(token)
        row = self.db.execute("SELECT * FROM people WHERE token=?", (key,)).fetchone()
        if not row:
            raise Rejected("客户端尚未登记。")
        return key, row

    def register(self, name):
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 40:
            raise Rejected("请输入姓名（最多 40 字）。")
        token = secrets.token_hex(32)
        with self.lock, self.db:
            self.db.execute("INSERT INTO people VALUES(?,?,?,?)",
                            (self.digest(token), uuid.uuid4().hex, name.strip(), self.clock()))
        return {"token": token}

    def _board(self):
        return self.db.execute("SELECT * FROM board WHERE id=1").fetchone()

    def status(self, token):
        with self.lock:
            key, person = self._person(token)
            b = self._board()
            owner = self.db.execute("SELECT id,name FROM people WHERE token=?", (b["owner"],)).fetchone()
            queue = [dict(r) for r in self.db.execute('''SELECT jobs.id,people.name,
                json_extract(payload,'$.project') AS project FROM jobs JOIN people USING(token)
                WHERE state='queued' ORDER BY seq''')]
            return {"phase": b["phase"], "error": b["error"], "owner": dict(owner) if owner else None,
                    "mine": key == b["owner"], "name": person["name"], "project": b["project"],
                    "can_recover": not b['owner'] or b['owner'] == key or self.db.execute('SELECT seen FROM people WHERE token=?', (b['owner'],)).fetchone()['seen'] < self.clock() - self.GRACE,
                    "queue": queue, "hardware": dict(self.cached), "packages": self.catalog.public()}

    def act(self, action, token, data):
        if action == "register":
            return self.register(data.get("name"))
        with self.lock, self.db:
            key, person = self._person(token)
            b = self._board()
            if action == "heartbeat":
                self.db.execute("UPDATE people SET seen=? WHERE token=?", (self.clock(), key))
            elif action == "rename":
                name = data.get("name", "").strip()
                if not 1 <= len(name) <= 40:
                    raise Rejected("请输入姓名（最多 40 字）。")
                self.db.execute("UPDATE people SET name=? WHERE token=?", (name, key))
            elif action == "submit":
                if data.get("operation") == "recover":
                    raise Rejected("请使用明确确认的恢复入口。")
                return self._submit(key, b, data)
            elif action == "events":
                if b["owner"] != key or b["phase"] != "owned":
                    raise Rejected("当前没有实验占用。")
                return self.adapters[b["project"]].events(data.get("after", 0))
            elif action == "result":
                r = self.db.execute("SELECT state,result,error FROM jobs WHERE id=? AND token=?", (data.get("id"), key)).fetchone()
                if not r:
                    raise Rejected("任务不存在。")
                return {"state": r["state"], "result": json.loads(r["result"]) if r["result"] else None, "error": r["error"]}
            elif action == "cancel":
                self.db.execute("UPDATE jobs SET state='cancelled' WHERE token=? AND state='queued'", (key,))
                # A running command is stopped through the same verified cleanup path.
                if b["owner"] == key:
                    self._end_locked()
            elif action == "end":
                self.db.execute("UPDATE jobs SET state='cancelled' WHERE token=? AND state='queued'", (key,))
                if b["owner"] == key:
                    self._end_locked()
            elif action == "recover":
                previous = self.db.execute('SELECT seen FROM people WHERE token=?', (b['owner'],)).fetchone()
                if b["phase"] != "recovery" or (b["owner"] and b["owner"] != key and previous['seen'] >= self.clock() - self.GRACE):
                    raise Rejected("当前状态不允许恢复，或需由当前使用人恢复。")
                if data.get("confirmed") is not True:
                    raise Rejected("请明确确认重新初始化并恢复。")
                return self._submit(key, b, {**data, "operation": "recover", "switch": True})
            else:
                raise Rejected("不支持的操作。")
            self.wake.set()
            return self.status(token)

    def _submit(self, key, board, data):
        project = data.get("project")
        if project not in self.adapters:
            raise Rejected("工程未配置。")
        recovery = data.get("operation") == "recover"
        if not recovery and board["owner"] == key and board["project"] != project:
            raise Rejected("请先结束当前工程的使用，再切换工程。")
        if recovery and board["phase"] != "recovery":
            raise Rejected("当前无需恢复。")
        if not recovery and board["phase"] in ("recovery", "recovering", "closing"):
            raise Rejected("板卡正在清理或待恢复，任务尚未提交。")
        if self.db.execute("SELECT 1 FROM jobs WHERE token=? AND state IN ('queued','running')", (key,)).fetchone():
            raise Rejected("已有待执行或运行中的任务，请取消后重新提交。")
        if not recovery and board["owner"] not in (None, key) and data.get("enqueue") is not True:
            raise Rejected("有人正在使用；请点击加入队列。")
        package = self.catalog.resolve(data.get("package"))
        if package["project"] != project:
            raise Rejected("固件版本与工程不一致。")
        if data.get("switch") is not True:
            raise Rejected("请确认轮到您时可以加载所选工程版本。")
        payload = {"project": project, "operation": data.get("operation"),
                   "parameters": data.get("parameters", {}), "package": package}
        # Validate before acquiring hardware or inserting a task. JSON round-trip freezes inputs.
        self.adapters[project].validate(payload)
        serialized = json.dumps(payload, allow_nan=False)
        job = uuid.uuid4().hex
        self.db.execute("INSERT INTO jobs(id,token,payload,state) VALUES(?,?,?,'queued')", (job, key, serialized))
        if recovery:
            self.db.execute("UPDATE board SET phase='recovering',owner=?,project=?", (key, project))
        self.wake.set()
        return {"id": job}

    def _end_locked(self):
        self.db.execute("UPDATE board SET phase='closing'")
        self.cancel.set()

    def _expire(self):
        cutoff = self.clock() - self.GRACE
        self.db.execute("UPDATE jobs SET state='cancelled',error='客户端断线超时' WHERE state='queued' AND token IN (SELECT token FROM people WHERE seen<?)", (cutoff,))
        b = self._board()
        if b["owner"] and b["phase"] not in ("recovery", "closing"):
            p = self.db.execute("SELECT seen FROM people WHERE token=?", (b["owner"],)).fetchone()
            if p["seen"] < cutoff:
                self._end_locked()

    def tick(self):
        """One worker iteration; tests call this deterministically, never concurrently."""
        with self.lock, self.db:
            self._expire()
            b = self._board()
            phase, project = b["phase"], b["project"]
            if phase == "closing":
                job = None
            elif phase in ("ready", "owned", "recovering"):
                job = self.db.execute("SELECT * FROM jobs WHERE state='queued' AND (? IS NULL OR token=?) ORDER BY seq LIMIT 1", (b["owner"], b["owner"])).fetchone()
                if not job:
                    return
                payload = json.loads(job["payload"])
                project = payload["project"]
                new_owner = b['owner'] != job['token']
                self.cancel.clear()
                self.db.execute("UPDATE jobs SET state='running' WHERE id=?", (job["id"],))
                self.db.execute("UPDATE board SET owner=?,project=?,phase='owned'", (job["token"], project))
            else:
                return
        adapter = self.adapters.get(project)
        try:
            if phase == "closing":
                if adapter is None or adapter.cleanup() is not True:
                    raise RuntimeError("停止输出或连接清理尚未确认")
                with self.lock, self.db:
                    self.db.execute("UPDATE board SET owner=NULL,phase='ready',error=NULL")
                return
            fresh = self.catalog.resolve(payload["package"]["key"])
            if fresh != payload["package"]:
                raise RuntimeError("排队期间固件包已变化")
            if new_owner and hasattr(adapter, 'begin_experiment'):
                adapter.begin_experiment()
            if self.cached.get('verified_project') != project and hasattr(adapter, 'package'):
                adapter.package = None
            if payload["operation"] == "recover":
                result = adapter.recover(fresh, self.cancel)
            else:
                result = adapter.execute(payload, self.cancel)
            evidence = adapter.verify()
            if evidence.get("verified_project") != project or not evidence.get("responsive"):
                raise RuntimeError("板卡工程身份或响应未确认")
            with self.lock, self.db:
                self.cached = evidence
                cancelled = self.cancel.is_set()
                self.db.execute("UPDATE jobs SET state=?,result=? WHERE id=?",
                                ("cancelled" if cancelled else "done", json.dumps(result, allow_nan=False), job["id"]))
                # Recovery leaves ownership with the requesting user.
                self.db.execute("UPDATE board SET error=NULL")
        except Exception as exc:
            # Cleanup is attempted for failures as well, but never auto-replays queued work.
            cleaned = False
            try:
                cleaned = adapter is not None and adapter.cleanup() is True
            except Exception:
                pass
            with self.lock, self.db:
                # Expected interruption during End/timeout is not a hardware fault
                # once the same stop/readback/resource-release checks have passed.
                ended = self.cancel.is_set() and self._board()['phase'] == 'closing'
                if job and ended and cleaned:
                    self.cached = {"responsive": False, "verified_project": None}
                    self.db.execute("UPDATE jobs SET state='cancelled',error=? WHERE id=?", (str(exc), job['id']))
                    self.db.execute("UPDATE board SET owner=NULL,phase='ready',error=NULL")
                    return
                self.cached = {"responsive": False, "verified_project": None}
                self.db.execute("UPDATE board SET phase='recovery',error=?", (str(exc),))
                if job:
                    self.db.execute("UPDATE jobs SET state='failed',error=? WHERE id=?", (str(exc), job["id"]))

    def start(self):
        def run():
            while not self.stopping.is_set():
                self.tick()
                self.wake.wait(.1)
                self.wake.clear()
        # Separate watchdog: long operations must not delay heartbeat expiry/cancellation.
        def watch():
            while not self.stopping.wait(.25):
                with self.lock, self.db:
                    self._expire()
        self.thread = threading.Thread(target=run, daemon=True)
        self.watchdog = threading.Thread(target=watch, daemon=True)
        self.thread.start()
        self.watchdog.start()

    def close(self):
        self.stopping.set()
        self.cancel.set()
        self.wake.set()
        if self.thread:
            self.thread.join(10)
            self.watchdog.join(2)
            if self.thread.is_alive():
                raise RuntimeError("硬件任务尚未退出；保留待恢复状态")
        with self.lock, self.db:
            self.db.execute("UPDATE board SET phase='recovery',error='服务已停止'")
        self.db.close()
