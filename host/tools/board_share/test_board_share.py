"""Offline acceptance: only loopback HTTP/TCP and fake process launchers."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
from pathlib import Path
import secrets
import socket
import threading
import time
from unittest.mock import Mock

import pytest
from .client import Lease, from_environment, request
from .server import Server
from .state import Store, Conflict


@pytest.fixture
def store(tmp_path):
    return Store(tmp_path / "state.sqlite3")


def join(store, token, name="甲", project="47DR"):
    return store.act("join", token, dict(name=name, project=project, note="离线测试", minutes=1))


def take(store, token, project="47DR"):
    join(store, token, project=project)
    return store.act("claim", token, {})


def test_fifo_and_session_ownership_survive_restart(store):
    a, b, c = [secrets.token_hex(32) for _ in range(3)]
    take(store, a)
    join(store, b, "乙", "RF-UDP")
    join(store, c, "丙")
    with pytest.raises(Conflict):
        store.act("claim", b, {})
    with pytest.raises(Conflict):
        store.act("release", b, {"confirmed": True})
    store = Store(store.path)
    assert store.status(a)["owner"]["name"] == "甲"
    assert [e["name"] for e in store.status()["queue"]] == ["乙", "丙"]
    store.act("release", a, {"confirmed": True})
    with pytest.raises(Conflict):
        store.act("claim", c, {})
    assert store.act("claim", b, {})["owner"]["project"] == "RF-UDP"


def test_no_timeout_release_and_idempotent_join(store):
    a = secrets.token_hex(32)
    take(store, a)
    with store.transaction() as db:
        db.execute("UPDATE entries SET expected=0")
    assert join(store, a)["owner"]
    assert store.status()["owner"]["expected"] == 0
    assert len(store.status()["queue"]) == 0
    assert store.act("extend", a, {"minutes": 10})["owner"]["expected"] > time.time()


def test_operation_excludes_release_and_wrong_project(store):
    a = secrets.token_hex(32)
    take(store, a)
    with pytest.raises(Conflict):
        store.act("begin", a, dict(project="RF-UDP", label="测试", operation_id="wrong"))
    op = dict(project="47DR", label="测试", operation_id="first")
    store.act("begin", a, op)
    with pytest.raises(Conflict):
        store.act("release", a, {"confirmed": True})
    with pytest.raises(Conflict):
        store.act("begin", a, op)
    assert Store(store.path).status()["operation"]["id"] == "first"
    with pytest.raises(Conflict):
        store.act("recover", a, {"operation_id": "stale", "confirmed": True})
    store.act("end", a, {"operation_id": "first"})
    assert store.status()["owner"]  # operation completion is NOT experiment completion
    store.act("begin", a, {**op, "operation_id": "second"})
    with pytest.raises(Conflict):
        store.act("end", a, {"operation_id": "first"})
    store.act("recover", a, {"operation_id": "second", "confirmed": True})
    assert store.status()["operation"] is None


def test_atomic_competing_operations(store):
    a = secrets.token_hex(32)
    take(store, a)
    def begin(i):
        try:
            store.act("begin", a, dict(project="47DR", label="测试", operation_id=str(i)))
            return True
        except Conflict:
            return False
    with ThreadPoolExecutor(max_workers=8) as pool:
        assert sum(pool.map(begin, range(12))) == 1


def test_public_state_and_database_do_not_store_plain_ticket(store):
    a, b = secrets.token_hex(32), secrets.token_hex(32)
    take(store, a)
    join(store, b)
    snapshot = json.dumps(store.status(a))
    assert a not in snapshot and b not in snapshot and '"ticket"' not in snapshot
    assert a.encode() not in store.path.read_bytes()


@contextmanager
def sharing(tmp_path):
    with Server(("127.0.0.1", 0), tmp_path / "service.sqlite3") as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
        thread.start()
        try:
            yield server, f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            thread.join(3)


def test_http_lease_and_unavailable_service_fail_closed(tmp_path, monkeypatch):
    a = secrets.token_hex(32)
    with sharing(tmp_path) as (server, url):
        take(server.store, a)
        path = tmp_path / "ticket.json"
        path.write_text(json.dumps(dict(url=url, ticket=a)))
        monkeypatch.setenv("BOARD_SHARE_TICKET_FILE", str(path))
        monkeypatch.setenv("BOARD_SHARE_URL", url)
        lease = from_environment("47DR", "测试")
        assert request(url, a, "status")["operation"]
        with pytest.raises(RuntimeError):
            request(url, a, "release", {"confirmed": True})
        lease.close()
        assert request(url, a, "status")["owner"]
    with pytest.raises(RuntimeError, match="无法确认"):
        from_environment("47DR", "测试")


def test_foreign_browser_origin_rejected(tmp_path):
    from urllib.request import Request, urlopen
    from urllib.error import HTTPError
    with sharing(tmp_path) as (_, url):
        req = Request(url+"/api/join", data=b"{}", headers={"Origin": "http://other.invalid", "Content-Type": "application/json"})
        with pytest.raises(HTTPError) as exc:
            urlopen(req)
        assert exc.value.code == 403


def test_guarded_command_does_not_launch_without_ownership(tmp_path, monkeypatch):
    from . import __main__ as cli
    with sharing(tmp_path) as (_, url):
        ticket_file = tmp_path / "ticket.json"
        ticket_file.write_text(json.dumps(dict(url=url, ticket=secrets.token_hex(32))))
        launch = Mock()
        monkeypatch.setattr(cli.subprocess, "call", launch)
        monkeypatch.setattr("sys.argv", ["board_share", "run", "--ticket-file", str(ticket_file), "--project", "RF-UDP", "--", "fake-tool"])
        with pytest.raises(RuntimeError, match="只有当前使用人"):
            cli.main()
        launch.assert_not_called()


def test_guarded_command_keeps_experiment_claim(tmp_path, monkeypatch):
    from . import __main__ as cli
    with sharing(tmp_path) as (server, url):
        a = secrets.token_hex(32)
        take(server.store, a, "RF-UDP")
        ticket_file = tmp_path / "ticket.json"
        ticket_file.write_text(json.dumps(dict(url=url, ticket=a)))
        def launch(*_args, **_kwargs):
            assert server.store.status()["operation"]
            with pytest.raises(Conflict):
                server.store.act("release", a, {"confirmed": True})
            return 7
        monkeypatch.setattr(cli.subprocess, "call", launch)
        monkeypatch.setattr("sys.argv", ["board_share", "run", "--ticket-file", str(ticket_file), "--project", "RF-UDP", "--", "fake-tool"])
        assert cli.main() == 7
        assert server.store.status()["owner"]
        assert server.store.status()["operation"] is None


def test_47dr_service_rejects_before_any_board_access(tmp_path, monkeypatch):
    from awg_eth import remote
    a, b = secrets.token_hex(32), secrets.token_hex(32)
    probe = Mock(side_effect=RuntimeError("FAKE BOARD"))
    monkeypatch.setattr(remote, "open_device", probe)
    with sharing(tmp_path) as (panel, url):
        take(panel.store, a)
        with remote.RemoteServer(("127.0.0.1", 0), fpga_ip="127.0.0.1", board_share_url=url) as server:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
            thread.start()
            try:
                for token in (None, b):
                    with pytest.raises(RuntimeError):
                        remote.RemoteClient("127.0.0.1", server.server_address[1], board_ticket=token)
                    deadline = time.monotonic()+2
                    while server.owner.locked() and time.monotonic()<deadline:
                        time.sleep(.005)
                probe.assert_not_called()
                with pytest.raises(RuntimeError, match="FAKE BOARD"):
                    remote.RemoteClient("127.0.0.1", server.server_address[1], board_ticket=a)
                deadline = time.monotonic()+2
                while panel.store.status()["operation"] and time.monotonic()<deadline:
                    time.sleep(.005)
                assert panel.store.status()["operation"] is None
                assert panel.store.status()["owner"]
                assert probe.call_count == 1
            finally:
                server.shutdown()
                thread.join(3)


def test_programmer_rejects_before_qprocess_start(tmp_path, monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtWidgets import QApplication
    from awg_gui.programmer import BoardProgrammer
    app = QApplication.instance() or QApplication([])
    with sharing(tmp_path) as (_, url):
        path = tmp_path / "ticket.json"
        path.write_text(json.dumps(dict(url=url, ticket=secrets.token_hex(32))))
        monkeypatch.setenv("BOARD_SHARE_TICKET_FILE", str(path))
        monkeypatch.setenv("BOARD_SHARE_URL", url)
        script = tmp_path / "fake.tcl"
        script.write_text("# no hardware")
        programmer = BoardProgrammer()
        with pytest.raises(RuntimeError, match="只有当前使用人"):
            programmer.start("NEVER_LAUNCH_XSCT", tmp_path, script=script)
        assert programmer.proc is None
        assert app is not None


def test_fake_programmer_releases_operation_but_not_experiment(tmp_path, monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtWidgets import QApplication
    from awg_gui.programmer import BoardProgrammer
    from awg_gui.tests.test_program_menu import _fake_xsct, _wait
    app = QApplication.instance() or QApplication([])
    with sharing(tmp_path) as (server, url):
        a = secrets.token_hex(32)
        take(server.store, a)
        path = tmp_path / "ticket.json"
        path.write_text(json.dumps(dict(url=url, ticket=a)))
        monkeypatch.setenv("BOARD_SHARE_TICKET_FILE", str(path))
        monkeypatch.setenv("BOARD_SHARE_URL", url)
        script = tmp_path / "fake.tcl"
        script.write_text("# no hardware")
        programmer = BoardProgrammer()
        results = []
        programmer.finished.connect(lambda ok, msg: results.append(ok))
        programmer.start(str(_fake_xsct(tmp_path, 0)), tmp_path, script=script)
        assert server.store.status()["operation"]
        assert _wait(app, lambda: results)
        assert results == [True]
        assert server.store.status()["owner"] and server.store.status()["operation"] is None
        results.clear()
        programmer.start("NONEXISTENT_FAKE_XSCT", tmp_path, script=script)
        assert _wait(app, lambda: results)
        assert results == [False]
        assert server.store.status()["operation"] is None


def test_direct_worker_checks_claim_before_network(tmp_path, monkeypatch):
    from awg_gui import worker
    with sharing(tmp_path) as (_, url):
        path = tmp_path / "ticket.json"
        path.write_text(json.dumps(dict(url=url, ticket=secrets.token_hex(32))))
        monkeypatch.setenv("BOARD_SHARE_TICKET_FILE", str(path))
        monkeypatch.setenv("BOARD_SHARE_URL", url)
        probe = Mock()
        monkeypatch.setattr(worker, "open_device", probe)
        device = worker.DeviceWorker()
        with pytest.raises(RuntimeError):
            device._open("127.0.0.1", 9100, 2048)
        probe.assert_not_called()


def test_enabled_remote_service_with_emulator(tmp_path):
    from awg_eth import remote
    from awg_eth.fpga_emu import FpgaEmulator
    a = secrets.token_hex(32)
    with sharing(tmp_path) as (panel, url), FpgaEmulator(abi=3, build_id=0xD4B02026) as emu:
        take(panel.store, a)
        with remote.RemoteServer(("127.0.0.1", 0), fpga_ip="127.0.0.1", fpga_port=emu.port, board_share_url=url) as server:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
            thread.start()
            try:
                with remote.RemoteClient("127.0.0.1", server.server_address[1], board_ticket=a) as peer:
                    assert peer.request("status")["status"]["ps_ready"]
                    assert panel.store.status()["operation"]
                    with pytest.raises(Conflict):
                        panel.store.act("release", a, {"confirmed": True})
                assert panel.store.status()["operation"] is None
                assert panel.store.status()["owner"]
            finally:
                server.shutdown()
                thread.join(3)


def test_shared_client_cannot_silently_use_unguarded_service(monkeypatch):
    from awg_eth import remote
    probe = Mock()
    monkeypatch.setattr(remote, "open_device", probe)
    with remote.RemoteServer(("127.0.0.1", 0), fpga_ip="127.0.0.1") as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
        thread.start()
        try:
            with pytest.raises(RuntimeError, match="尚未启用"):
                remote.RemoteClient("127.0.0.1", server.server_address[1], board_ticket=secrets.token_hex(32))
            probe.assert_not_called()
        finally:
            server.shutdown()
            thread.join(3)
