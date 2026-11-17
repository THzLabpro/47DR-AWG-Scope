"""Durable FIFO ownership and operation exclusion, using SQLite transactions."""
import hashlib
import re
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path


class Conflict(ValueError):
    pass


def ticket_hash(ticket):
    if not isinstance(ticket, str) or not re.fullmatch(r"[0-9a-f]{64}", ticket):
        raise Conflict("请先在共用面板登记，并选择自己的领用文件。")
    return hashlib.sha256(ticket.encode("ascii")).hexdigest()


def field(data, key, limit=80):
    value = data.get(key)
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > limit:
        raise Conflict(f"{key} 不能为空，且不能超过 {limit} 个字符。")
    return value.strip()


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.transaction() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS entries (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    ticket TEXT UNIQUE NOT NULL, id TEXT UNIQUE NOT NULL,
                    name TEXT NOT NULL, project TEXT NOT NULL, note TEXT NOT NULL,
                    minutes INTEGER NOT NULL, joined REAL NOT NULL,
                    started REAL, expected REAL);
                CREATE UNIQUE INDEX IF NOT EXISTS one_owner
                    ON entries ((1)) WHERE started IS NOT NULL;
                CREATE TABLE IF NOT EXISTS operation (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    id TEXT NOT NULL, ticket TEXT NOT NULL,
                    label TEXT NOT NULL, started REAL NOT NULL);
            """)

    @contextmanager
    def transaction(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def snapshot(db, key=None):
        rows = [dict(row) for row in db.execute("SELECT * FROM entries ORDER BY seq")]
        owner = None
        queue = []
        mine = None
        for row in rows:
            own = row.pop("ticket") == key
            row.pop("seq")
            if own:
                mine = row["id"]
            if row["started"] is not None:
                owner = row
            else:
                queue.append(row)
        op = db.execute("SELECT id,label,started FROM operation").fetchone()
        return dict(owner=owner, queue=queue, mine=mine,
                    operation=dict(op) if op else None, now=time.time(),
                    hardware_verified=False)

    def status(self, ticket=None):
        key = ticket_hash(ticket) if ticket else None
        with self.transaction() as db:
            return self.snapshot(db, key)

    def act(self, action, ticket, data):
        key = ticket_hash(ticket)
        with self.transaction() as db:
            me = db.execute("SELECT * FROM entries WHERE ticket=?", (key,)).fetchone()
            owner = db.execute("SELECT * FROM entries WHERE started IS NOT NULL").fetchone()
            op = db.execute("SELECT * FROM operation").fetchone()
            if action == "join":
                if me is None:
                    minutes = data.get("minutes", 60)
                    if type(minutes) is not int or not 1 <= minutes <= 10080:
                        raise Conflict("预计用时需为 1 至 10080 分钟。")
                    db.execute("INSERT INTO entries(ticket,id,name,project,note,minutes,joined) VALUES(?,?,?,?,?,?,?)",
                               (key, uuid.uuid4().hex, field(data, "name", 40),
                                field(data, "project"), field(data, "note", 160), minutes, time.time()))
            elif action == "claim":
                if me is None:
                    raise Conflict("请先加入队列。")
                if not (owner and owner["ticket"] == key):
                    if owner or op:
                        raise Conflict("板卡仍被占用，请等待当前使用人交接。")
                    first = db.execute("SELECT ticket FROM entries ORDER BY seq LIMIT 1").fetchone()
                    if first["ticket"] != key:
                        raise Conflict("请按队列顺序领用。")
                    now = time.time()
                    db.execute("UPDATE entries SET started=?,expected=? WHERE ticket=?",
                               (now, now + me["minutes"] * 60, key))
            elif action == "cancel":
                if me and me["started"] is not None:
                    raise Conflict("已领用，请结束实验后交接。")
                db.execute("DELETE FROM entries WHERE ticket=?", (key,))
            elif action in ("release", "extend", "begin", "end", "recover"):
                if owner is None or owner["ticket"] != key:
                    raise Conflict("只有当前使用人可以执行此操作。")
                if action == "release":
                    if op:
                        raise Conflict("还有下载或测试操作未结束，不能交接。")
                    if data.get("confirmed") is not True:
                        raise Conflict("请确认实验结束、板卡可以交接。")
                    db.execute("DELETE FROM entries WHERE ticket=?", (key,))
                elif action == "extend":
                    minutes = data.get("minutes")
                    if type(minutes) is not int or not 1 <= minutes <= 10080:
                        raise Conflict("预计剩余时间需为 1 至 10080 分钟。")
                    db.execute("UPDATE entries SET expected=? WHERE ticket=?", (time.time()+minutes*60, key))
                elif action == "begin":
                    if field(data, "project") != owner["project"]:
                        raise Conflict("登记工程与操作入口不一致，请核对工程后重新领用。")
                    if op:
                        raise Conflict("已有下载或测试操作正在占用，请等待它结束。")
                    operation_id = field(data, "operation_id")
                    db.execute("INSERT INTO operation VALUES(1,?,?,?,?)",
                               (operation_id, key, field(data, "label"), time.time()))
                else:
                    if action == "recover" and data.get("confirmed") is not True:
                        raise Conflict("请先确认原操作进程已经结束。")
                    if op and data.get("operation_id") != op["id"]:
                        raise Conflict("操作记录已变化，请刷新后核对。")
                    db.execute("DELETE FROM operation WHERE ticket=? AND id=?",
                               (key, data.get("operation_id")))
            else:
                raise Conflict("不支持的操作。")
            return self.snapshot(db, key)
