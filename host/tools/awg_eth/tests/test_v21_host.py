"""V2.1 host tests against the emulator (abi=3): TX pooling, START refusal, 2x capture rule."""
import numpy as np
import pytest

from awg_eth.awg import (ADC_FS_HZ, BULK_RXR_WINDOW, DAC_FS_HZ, Awg, REG_TX_MODE, capture_samples_for_tx,
                         pool_slots)
from awg_eth.client import AwgEthClient, AwgEthError
from awg_eth.fpga_emu import FpgaEmulator


def _words(channel: int, count: int) -> np.ndarray:
    return ((np.arange(count, dtype=np.uint64) * 4 + channel * 0x10004) & 0xFFFCFFFC).astype(np.uint32)


def test_pool_slots_and_tx_limits():
    assert [pool_slots(n) for n in range(1, 9)] == [1, 2, 4, 4, 8, 8, 8, 8]
    with FpgaEmulator(abi=3, bank_words=64).start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port) as client:
            awg = Awg(client)
            assert [awg.max_tx_samples(n) for n in (1, 2, 3, 4, 5, 8)] == [
                1048576, 524288, 262144, 262144, 131072, 131072]
            assert awg.bulk.window == BULK_RXR_WINDOW        # R2 fixed: several RXR in flight again
            awg.close()


def test_two_times_rule_holds_for_matched_modes():
    # Real bank size: RX capture of the same channel count is >= 2x the TX loop duration.
    for n in (1, 2, 4, 8):
        slots = pool_slots(n)
        tx_s = (8 // slots) * 131072 / DAC_FS_HZ
        rx_s = (8 // slots) * 10240 * 24 / ADC_FS_HZ
        assert rx_s >= 2 * tx_s
    limit = 10240 * 24 * 8
    need = capture_samples_for_tx(1048576, limit)
    assert need % 24 == 0 and need <= limit
    assert need >= 2 * 1048576 * ADC_FS_HZ / DAC_FS_HZ


def test_one_channel_full_length_pooled_loopback():
    with FpgaEmulator(abi=3, bank_words=10240, loopback=True).start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port, words_per_packet=2048) as client:
            awg = Awg(client)
            samples = 1048576
            data = _words(5, samples // 2)
            awg.load_words({5: data}, samples, 1 << 5, verify=True)
            assert client.read32(REG_TX_MODE) & 3 == 0 and (client.read32(REG_TX_MODE) >> 8) & 7 == 5
            st = awg.start()
            assert st["running"] == 1 and st["start_rejected"] == 0
            n = 24 * 4096
            captured, _, raw = awg.capture_raw("manual", 1 << 5, samples=n)
            assert captured == n
            assert np.array_equal(np.asarray(raw[5], dtype="<u4"), data[:n // 2])
            awg.stop()
            awg.close()


def test_three_channels_use_four_slot_mode_and_map_dacs():
    with FpgaEmulator(abi=3, bank_words=64, loopback=True).start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port) as client:
            awg = Awg(client)
            chans = (1, 4, 6)
            samples = 262144
            values = {ch: _words(ch, samples // 2) for ch in chans}
            awg.load_words(values, samples, sum(1 << c for c in chans))
            mode = client.read32(REG_TX_MODE)
            assert mode & 3 == 2
            assert [(mode >> (8 + 3 * s)) & 7 for s in range(3)] == list(chans)
            with pytest.raises(ValueError):
                awg.load_words({c: _words(c, 262176 // 2) for c in chans}, 262176, sum(1 << c for c in chans))
            awg.close()


def test_start_refused_after_mode_change_is_reported():
    with FpgaEmulator(abi=3, bank_words=64).start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port) as client:
            awg = Awg(client)
            awg.load_words({0: _words(0, 64)}, 128, 0x01)
            client.write32(REG_TX_MODE, 0xFAC68801)          # 2 slots: voids slot data
            with pytest.raises(AwgEthError, match="refused START"):
                awg.start()
            assert awg.status()["start_rejected"] == 1
            awg.close()
