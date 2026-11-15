"""V2.1 raw remote transport; all sockets are loopback, no hardware."""
from contextlib import contextmanager
import threading
import numpy as np
import pytest
from awg_eth.fpga_emu import FpgaEmulator
from awg_eth.remote import RemoteAwg, RemoteClient, RemoteServer, encode_arrays, decode_arrays


@contextmanager
def service(emu):
    with RemoteServer(("127.0.0.1", 0), fpga_ip="127.0.0.1", fpga_port=emu.port) as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .02}, daemon=True)
        thread.start()
        try:
            yield server, server.server_address[1]
        finally:
            server.shutdown()
            thread.join(5)


def words(n, channel=0):
    return ((np.arange(n // 2, dtype=np.uint32) * 0x40004 + channel * 0x100010) & 0xFFFCFFFC)


def test_remote_exclusive_and_preserve_playback():
    with FpgaEmulator(abi=3, build_id=0xD4B02026, loopback=True) as emu, service(emu) as (server, port):
        data = {2: words(96, 2), 7: words(96, 7)}
        with RemoteClient("127.0.0.1", port) as peer:
            with pytest.raises(RuntimeError, match="busy"):
                RemoteClient("127.0.0.1", port)
            peer.request("load_words", channels=encode_arrays(data), samples=96, mask=132, verify=True)
            assert peer.request("start")["status"]["running"]
        assert not server.owner.locked() and emu._running
        with RemoteClient("127.0.0.1", port) as peer:
            with pytest.raises(RuntimeError, match="stop playback manually"):
                peer.request("load_words", channels=encode_arrays(data), samples=96, mask=132)
            peer.request("stop")
            peer.request("load_words", channels=encode_arrays(data), samples=96, mask=132)
            peer.request("start")
            result = peer.request("capture_raw", trigger="manual", samples=65544, mask=132)
            raw = decode_arrays(result["channels"])
            for ch in data:
                np.testing.assert_array_equal(raw[ch], np.resize(data[ch], 65544 // 2))
        assert emu._running


def test_full_capacity_remote_roundtrip():
    with FpgaEmulator(abi=3, build_id=0xD4B02026, loopback=True) as emu, service(emu) as (server, port):
        awg = RemoteAwg("127.0.0.1", port)
        assert not server.owner.locked()
        data = words(1048576, 5)
        try:
            awg.load_words({5: data}, 1048576, 32, verify=True)
            assert server.owner.locked()
            awg.start()
            awg.release()
            assert not server.owner.locked() and emu._running
            count, _, raw = awg.capture_raw("manual", 32, samples=1966080)
            assert count == 1966080
            np.testing.assert_array_equal(raw[5], np.resize(data, count // 2))
            awg.release()
            assert awg.status()["running"] and not server.owner.locked()
        finally:
            awg.close()


def test_invalid_download_and_errors_release_proxy():
    with FpgaEmulator(abi=3, build_id=0xD4B02026) as emu, service(emu) as (server, port):
        awg = RemoteAwg("127.0.0.1", port)
        with pytest.raises(RuntimeError, match="mask"):
            awg.load_words({1: words(32)}, 32, 1)
        assert awg.peer is None and not server.owner.locked()
        with RemoteClient("127.0.0.1", port) as peer:
            with pytest.raises(RuntimeError, match="capacity"):
                peer.request("load_words", channels=encode_arrays({0: words(32)}), samples=33, mask=1)
            assert not emu._running


def test_wrong_firmware_refused():
    with FpgaEmulator(abi=3, build_id=1) as emu, service(emu) as (_, port):
        with pytest.raises(RuntimeError, match="firmware mismatch"):
            RemoteClient("127.0.0.1", port)
