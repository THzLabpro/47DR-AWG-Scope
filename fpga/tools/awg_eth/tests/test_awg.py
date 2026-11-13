import json
from awg_eth.awg import (
    Awg, REG_CAP_SAMPLES, REG_CAP_STATUS, REG_CAP_TX_WORD, crc32_tx_words,
)
from awg_eth.client import AwgEthClient
from awg_eth.fpga_emu import FpgaEmulator
from crc_ref import crc32 as reference_crc32


def _write_waveform(folder, samples=32, mask=0xFF):
    folder.mkdir(parents=True)
    (folder / "waveform.meta").write_text(
        f"samples {samples}\nfs_hz 9800000000\nnco_hz 0\nchannel_mask {mask}\nsample_format 1\n",
        encoding="ascii",
    )
    expected = {}
    for channel in range(8):
        if not mask & (1 << channel):
            continue
        words = []
        with (folder / f"ch{channel}.hex").open("w", encoding="ascii") as stream:
            for index in range(samples // 2):
                low = ((index * 31 + channel * 97) & 0xFFFF) & 0xFFFC
                high = ((index * 71 - channel * 53) & 0xFFFF) & 0xFFFC
                word = low | (high << 16)
                stream.write(f"{word:08X}\n")
                words.append(word)
        expected[channel] = words
    return expected


def test_crc_matches_independent_reference_and_14_bit_mask():
    words = [0x1234567B, 0xFEDCBA98, 0x80018001]
    assert crc32_tx_words(words) == reference_crc32(words)
    assert crc32_tx_words(words) == crc32_tx_words([word & 0xFFFCFFFC for word in words])


def test_load_crc_verify_and_capture_format(tmp_path):
    expected = _write_waveform(tmp_path / "wave", samples=96, mask=0x05)
    with FpgaEmulator().start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port, words_per_packet=16) as client:
            awg = Awg(client)
            state = awg.load(tmp_path / "wave", verify=True)
            assert state["channel_mask"] == 5
            assert state["length_beats"] == 3
            for channel, words in expected.items():
                assert emulator._tx_words[channel] == [word & 0xFFFCFFFC for word in words]

            out = tmp_path / "capture.csv"
            assert awg.capture(out, channel_mask=0x05, samples=48) == str(out)
            rows = [line.split(",") for line in out.read_text(encoding="ascii").splitlines()]
            meta = json.loads(out.with_suffix(".json").read_text(encoding="utf-8"))
            assert len(rows) == 48 and all(len(row) == 2 for row in rows)
            assert meta["format"] == "47dr-raw-adc-v2"
            assert meta["sample_bits"] == 14 and meta["cap_tx_word"] == client.read32(REG_CAP_TX_WORD)
            assert int(rows[0][0]) % 4 == 0 and -32768 <= int(rows[0][0]) <= 32764
            assert client.read32(REG_CAP_SAMPLES) == 48
            assert client.read32(REG_CAP_STATUS) & 2


def test_maximum_8_channel_load_with_loss_and_duplicate_injection(tmp_path):
    folder = tmp_path / "max_wave"
    folder.mkdir()
    samples = 131072
    (folder / "waveform.meta").write_text(
        f"samples {samples}\nfs_hz 9800000000\nnco_hz 0\nchannel_mask 255\nsample_format 1\n",
        encoding="ascii",
    )
    expected_crc = []
    for channel in range(8):
        crc_words = []
        with (folder / f"ch{channel}.hex").open("w", encoding="ascii") as stream:
            for index in range(samples // 2):
                sample_0 = ((index * 17 + channel * 131) & 0xFFFF) & 0xFFFC
                sample_1 = ((index * 43 - channel * 73) & 0xFFFF) & 0xFFFC
                word = sample_0 | (sample_1 << 16)
                stream.write(f"{word:08X}\n")
                crc_words.append(word)
        expected_crc.append(reference_crc32(crc_words))

    with FpgaEmulator(drop_rate=0.1, duplicate_rate=0.1, seed=101).start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port, timeout=0.005, retries=5,
                          words_per_packet=256, window=8) as client:
            awg = Awg(client)
            state = awg.load(folder, verify=True)
            assert state["channel_mask"] == 0xFF
            assert state["length_beats"] == 4096
            assert [len(emulator._tx_words[ch]) for ch in range(8)] == [65536] * 8
            assert emulator.counters["dup_writes"] > 0
            assert emulator.counters["rx_dropped"] > 0
            for channel, crc in enumerate(expected_crc):
                assert reference_crc32(emulator._tx_words[channel]) == crc


def test_capture_recovers_from_stale_armed_capture():
    """A start-triggered capture left armed (e.g. after a GUI timeout) made the next CAP_CTRL write fail."""
    import pytest
    from awg_eth.awg import REG_CAP_CTRL
    from awg_eth.client import AwgEthError
    with FpgaEmulator(loopback=True).start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port, words_per_packet=256) as client:
            awg = Awg(client)
            client.write32(REG_CAP_CTRL, (10 << 16) | 1)
            awg.command(8)
            assert client.read32(REG_CAP_STATUS) == 5            # busy + armed, waiting for start
            with pytest.raises(AwgEthError):
                client.write32(REG_CAP_CTRL, 10 << 16)
            captured, _, raw = awg.capture_raw("manual", 0x01, samples=240)
            assert captured == 240 and len(raw[0]) == 120
            assert awg.last_read_seconds > 0


def test_abort_and_past_end_read_slverr():
    """D3C: COMMAND=32 cancels an armed capture; CAP_RD_DATA past the buffer is an AXI error."""
    import pytest
    from awg_eth.awg import REG_CAP_CTRL, REG_CAP_RD_CH, REG_CAP_RD_DATA, REG_CAP_RD_PTR
    from awg_eth.client import AwgEthError
    with FpgaEmulator().start() as emulator:
        with AwgEthClient("127.0.0.1", port=emulator.port, words_per_packet=16) as client:
            awg = Awg(client)
            client.write32(REG_CAP_CTRL, (10 << 16) | 1)
            awg.command(8)
            assert client.read32(REG_CAP_STATUS) & 4
            awg.abort_capture()
            assert client.read32(REG_CAP_STATUS) == 0
            client.write32(REG_CAP_RD_PTR, 5)
            client.write32(REG_CAP_RD_CH, 1)
            assert client.read32(REG_CAP_RD_PTR) == 0
            client.write32(REG_CAP_RD_PTR, 32759)
            client.read32(REG_CAP_RD_DATA)
            with pytest.raises(AwgEthError):
                client.read32(REG_CAP_RD_DATA)
