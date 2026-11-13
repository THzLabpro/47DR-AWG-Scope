import json
import threading
import time
import pytest

from awg_eth.awg import REG_ABI, REG_DAC_FS_KSPS, REG_CAP_SAMPLES, REG_COMMAND
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
    with FpgaEmulator(build_id=0xD3C02026).start() as emulator:
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


class RecordedEmulator(FpgaEmulator):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.writes = []
        self.overrides = {}

    def _write_register(self, address, value):
        self.writes.append((address, value))
        return super()._write_register(address, value)

    def _read_register(self, address):
        if address in self.overrides:
            return True, self.overrides[address]
        return super()._read_register(address)


def _bridge(tmp_path, emulator):
    session = tmp_path / "session"
    session.mkdir()
    write_fields(session / "config.txt", {
        "fpga_ip": "127.0.0.1", "port": emulator.port, "words_per_packet": 256,
    })
    bridge = GuiBridge(session)
    return bridge


@pytest.mark.parametrize("mismatch", ["build", "abi", "rate"])
def test_wrong_firmware_is_rejected_without_writes(tmp_path, mismatch):
    with RecordedEmulator(build_id=1 if mismatch == "build" else 0xD3C02026) as emulator:
        if mismatch == "abi":
            emulator.overrides[REG_ABI] = 1
        if mismatch == "rate":
            emulator.overrides[REG_DAC_FS_KSPS] = 9_000_000
        bridge = _bridge(tmp_path, emulator)
        with pytest.raises(ValueError, match="firmware mismatch"):
            bridge.connect()
        assert bridge.client is None and bridge.awg is None
        assert emulator.writes == []


@pytest.mark.parametrize("verify", [False, True])
def test_ipc_run_respects_crc_samples_channels_and_progress(tmp_path, verify):
    from test_awg import _write_waveform
    expected = _write_waveform(tmp_path / "wave", samples=96, mask=0x84)
    with RecordedEmulator(build_id=0xD3C02026, loopback=True) as emulator:
        bridge = _bridge(tmp_path, emulator)
        (bridge.session / "heartbeat").touch()
        thread = threading.Thread(target=bridge.main, daemon=True)
        thread.start()
        assert _wait(bridge.session / "hello.res")["ok"] == "1"
        out = tmp_path / "capture.csv"
        write_fields(bridge.session / "00000001.req", {
            "action": "run", "directory": tmp_path / "wave", "capture": out,
            "verify": int(verify), "samples": 24, "mask": 0x84, "trigger": "start",
        })
        response = _wait(bridge.session / "00000001.res")
        assert response["ok"] == "1", response
        metadata = json.loads(out.with_suffix(".json").read_text())
        assert metadata["samples"] == 24 and metadata["channel_mask"] == 0x84
        rows = [[int(x) for x in line.split(",")] for line in out.read_text().splitlines()]
        for col, channel in enumerate([2, 7]):
            raw = []
            for word in expected[channel]:
                raw += [(word & 0xFFFF), (word >> 16)]
            signed = [x - 65536 if x & 32768 else x for x in raw]
            assert [row[col] for row in rows] == signed[:24]
        crc_commands = sum(addr == REG_COMMAND and value == 16 for addr, value in emulator.writes)
        assert crc_commands == (2 if verify else 0)
        progress = read_fields(bridge.session / "progress.txt")
        assert progress["request"] == "00000001"
        assert progress["channel"] == "7" and progress["done"] == "24"
        write_fields(bridge.session / "00000002.req", {"action": "disconnect"})
        assert _wait(bridge.session / "00000002.res")["ok"] == "1"
        thread.join(3)
        assert not thread.is_alive()
        assert emulator._running  # disconnect must not stop playback


def test_wrong_capture_count_is_not_exported(tmp_path):
    with RecordedEmulator(build_id=0xD3C02026) as emulator:
        bridge = _bridge(tmp_path, emulator)
        bridge.connect()
        emulator.overrides[REG_CAP_SAMPLES] = 48
        out = tmp_path / "bad.csv"
        try:
            with pytest.raises(RuntimeError, match="sample count mismatch"):
                bridge.dispatch({"action": "capture", "capture": str(out), "samples": "24"})
            assert not out.exists()
        finally:
            bridge.client.close()


def test_invalid_run_is_rejected_before_download(tmp_path):
    with RecordedEmulator(build_id=0xD3C02026) as emulator:
        bridge = _bridge(tmp_path, emulator)
        bridge.connect()
        try:
            with pytest.raises(ValueError, match="capture samples"):
                bridge.dispatch({"action": "run", "directory": "missing", "samples": "25"})
            assert emulator.writes == []
        finally:
            bridge.client.close()


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


def test_atomic_ipc_retries_windows_reader_lock(tmp_path, monkeypatch):
    import os
    original = os.replace
    attempts = []

    def locked_then_released(source, target):
        attempts.append(target)
        if len(attempts) < 3:
            raise PermissionError("Windows reader holds progress.txt")
        original(source, target)

    monkeypatch.setattr("awg_eth.gui_bridge.os.replace", locked_then_released)
    path = tmp_path / "progress.txt"
    write_fields(path, {"done": 24})
    assert read_fields(path)["done"] == "24" and len(attempts) == 3


def test_progress_file_failure_does_not_abort_transfer(tmp_path, monkeypatch):
    def locked(*args):
        raise PermissionError("progress file locked")

    bridge = GuiBridge(tmp_path)
    monkeypatch.setattr("awg_eth.gui_bridge.write_fields", locked)
    bridge.progress("write", "CH7", 24, 24)
