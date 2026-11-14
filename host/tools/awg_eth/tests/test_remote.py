import json
import threading

import pytest

from awg_eth.fpga_emu import FpgaEmulator
from awg_eth.remote import RemoteClient, RemoteServer
from test_awg import _write_waveform


def test_remote_session_end_to_end_and_exclusive(tmp_path):
    folder = tmp_path / "wave"
    _write_waveform(folder, samples=96, mask=5)
    with FpgaEmulator(build_id=0xD3C02026, loopback=True).start() as emu:
        with RemoteServer(("127.0.0.1", 0), fpga_ip="127.0.0.1", fpga_port=emu.port) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            port = server.server_address[1]
            try:
                with RemoteClient("127.0.0.1", port) as client:
                    with pytest.raises(RuntimeError, match="busy"):
                        RemoteClient("127.0.0.1", port)
                    capture = tmp_path / "capture.csv"
                    result = client.request("run", waveform=folder, capture=capture, samples=24,
                                            mask=5, trigger="start", verify=1)
                    assert result["ok"] == 1
                    assert len(capture.read_text().splitlines()) == 24
                    assert json.loads(capture.with_suffix(".json").read_text())["channel_mask"] == 5
                    with pytest.raises(FileExistsError):
                        client.request("capture", capture=capture, samples=24)
                    assert client.request("status")["running"] == 1
                with RemoteClient("127.0.0.1", port) as other:
                    assert other.request("stop")["ok"] == 1
            finally:
                server.shutdown()
                thread.join()


def test_wrong_firmware_refused(tmp_path):
    with FpgaEmulator(build_id=1).start() as emu:
        with RemoteServer(("127.0.0.1", 0), fpga_ip="127.0.0.1", fpga_port=emu.port) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with pytest.raises(RuntimeError, match="firmware mismatch"):
                    RemoteClient("127.0.0.1", server.server_address[1])
            finally:
                server.shutdown()
                thread.join()
