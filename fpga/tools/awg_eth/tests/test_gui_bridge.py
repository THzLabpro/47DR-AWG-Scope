import json
import threading
import time

from awg_eth.fpga_emu import FpgaEmulator
from awg_eth.gui_bridge import GuiBridge, read_fields, write_fields


def _wait(path, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return read_fields(path)
        time.sleep(0.01)
    raise TimeoutError(f"waiting for {path}")


def test_file_ipc_connect_status_and_disconnect(tmp_path):
    with FpgaEmulator().start() as emulator:
        session = tmp_path / "session"
        session.mkdir()
        write_fields(session / "config.txt", {
            "fpga_ip": "127.0.0.1", "port": emulator.port,
            "words_per_packet": 64,
        })
        (session / "heartbeat").write_text("alive", encoding="ascii")
        bridge = GuiBridge(session)
        thread = threading.Thread(target=bridge.main, daemon=True)
        thread.start()
        hello = _wait(session / "hello.res")
        assert hello["ok"] == "1"
        assert hello["info_awg_id"] == str(0x41574531)
        assert hello["abi"] == str(0x00030001)

        write_fields(session / "00000001.req", {"action": "status"})
        status = _wait(session / "00000001.res")
        assert status["ok"] == "1" and status["ps_ready"] == "1"

        write_fields(session / "00000002.req", {"action": "disconnect"})
        reply = _wait(session / "00000002.res")
        assert reply["ok"] == "1" and reply["disconnected"] == "1"
        thread.join(3)
        assert not thread.is_alive()


def test_ipc_fields_preserve_utf8_and_reject_malformed(tmp_path):
    from awg_eth.gui_bridge import read_fields

    path = tmp_path / "fields.txt"
    write_fields(path, {"message": "中文 [data] $x;{}"})
    assert read_fields(path)["message"] == "中文 [data] $x;{}"
    path.write_text("bad line\n", encoding="ascii")
    try:
        read_fields(path)
    except ValueError:
        pass
    else:
        raise AssertionError("malformed field was accepted")
