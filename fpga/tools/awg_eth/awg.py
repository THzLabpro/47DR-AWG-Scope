"""High-level v2 AWG and raw ADC operations."""

from __future__ import annotations

import binascii
import csv
import json
from pathlib import Path
import struct
import time
from typing import Callable, Iterable, Sequence

from .client import AwgEthClient, AwgEthError, PipelineAbort

REG_BASE = 0x90200000
REG_ID = REG_BASE + 0x00
REG_STATUS = REG_BASE + 0x04
REG_COMMAND = REG_BASE + 0x08
REG_TX_LENGTH = REG_BASE + 0x0C
REG_TX_MASK = REG_BASE + 0x10
REG_DAC_FS_KSPS = REG_BASE + 0x14
REG_ADC_FS_KSPS = REG_BASE + 0x18
REG_FAULTS = REG_BASE + 0x1C
REG_ABI = REG_BASE + 0x20
REG_MAX_WORDS = REG_BASE + 0x24
REG_CAP_STATUS = REG_BASE + 0x28
REG_CAP_SAMPLES = REG_BASE + 0x2C
REG_TX_WR_CH = REG_BASE + 0x30
REG_TX_WR_PTR = REG_BASE + 0x34
REG_TX_WR_DATA = REG_BASE + 0x38
REG_TX_CRC = REG_BASE + 0x3C
REG_CAP_RD_CH = REG_BASE + 0x40
REG_CAP_RD_PTR = REG_BASE + 0x44
REG_CAP_RD_DATA = REG_BASE + 0x48
REG_CAP_CTRL = REG_BASE + 0x4C
REG_CAP_TX_WORD = REG_BASE + 0x50
REG_BUILD_ID = REG_BASE + 0x54

DAC_FS_HZ = 9_800_000_000
ADC_FS_HZ = 5_000_000_000
ABI = 0x00030001
TX_MAX_WORDS = 4096
CAP_MAX_WORDS = 2730
TX_MAX_SAMPLES = TX_MAX_WORDS * 32
CAP_MAX_SAMPLES = CAP_MAX_WORDS * 24
PROGRESS = Callable[[str, str, int, int], None]


def crc32_tx_words(words: Iterable[int]) -> int:
    """CRC-32/IEEE over paired int16 samples after the hardware's 14-bit mask."""
    values = [int(word) & 0xFFFFFFFF for word in words] if not isinstance(words, (tuple, list)) else words
    if not values:
        return binascii.crc32(b"") & 0xFFFFFFFF
    n = len(values)
    raw = struct.pack(f"<{n}I", *values)
    # Apply the 14-bit mask (0xFFFCFFFC per word) to the whole buffer as one big integer: ~1 ms for
    # 64 K words versus ~10 ms for a per-word loop.
    masked = int.from_bytes(raw, "little") & int.from_bytes(b"\xfc\xff\xfc\xff" * n, "little")
    return binascii.crc32(masked.to_bytes(4 * n, "little")) & 0xFFFFFFFF


def _parse_waveform(directory: Path) -> tuple[dict[str, int], dict[int, tuple[int, ...]]]:
    meta: dict[str, int] = {}
    for line in (directory / "waveform.meta").read_text(encoding="ascii").splitlines():
        parts = line.split()
        if len(parts) != 2 or not parts[1].isdigit():
            raise ValueError(f"Invalid waveform.meta line: {line!r}")
        key = parts[0]
        if key in meta:
            raise ValueError(f"Duplicate waveform metadata key: {key}")
        meta[key] = int(parts[1])
    required = ("samples", "fs_hz", "nco_hz", "channel_mask", "sample_format")
    missing = [key for key in required if key not in meta]
    if missing:
        raise ValueError(f"Missing waveform metadata: {', '.join(missing)}")
    samples = meta["samples"]
    mask = meta["channel_mask"]
    if not 32 <= samples <= TX_MAX_SAMPLES or samples % 32:
        raise ValueError(f"samples must be 32..{TX_MAX_SAMPLES} and divisible by 32")
    if not 1 <= mask <= 0xFF:
        raise ValueError("channel_mask must be 1..255")
    if meta["fs_hz"] != DAC_FS_HZ or meta["nco_hz"] != 0 or meta["sample_format"] != 1:
        raise ValueError("waveform must use 9.8 GS/s, zero NCO, real int16 sample_format=1")

    channels: dict[int, tuple[int, ...]] = {}
    for channel in range(8):
        if not mask & (1 << channel):
            continue
        path = directory / f"ch{channel}.hex"
        lines = path.read_text(encoding="ascii").splitlines()
        if len(lines) != samples // 2:
            raise ValueError(f"CH{channel} must contain {samples // 2} packed sample pairs")
        words: list[int] = []
        for row, line in enumerate(lines, start=1):
            token = line.strip()
            if len(token) != 8:
                raise ValueError(f"CH{channel} line {row}: expected 8 hex digits")
            try:
                words.append(int(token, 16))
            except ValueError as exc:
                raise ValueError(f"CH{channel} line {row}: invalid hex word") from exc
        channels[channel] = tuple(words)
    return meta, channels


class Awg:
    def __init__(self, client: AwgEthClient, *, progress_callback: PROGRESS | None = None):
        self.client = client
        self.progress_callback = progress_callback

    def _progress(self, phase: str, channel: str, done: int, total: int) -> None:
        if self.progress_callback:
            self.progress_callback(phase, channel, done, total)

    def status(self) -> dict[str, int]:
        state = self.client.read32(REG_STATUS)
        max_words = self.client.read32(REG_MAX_WORDS)
        return {
            "running": state & 1,
            "busy": (state >> 1) & 1,
            "ps_ready": (state >> 2) & 1,
            "fault": (state >> 3) & 1,
            "command_result": (state >> 4) & 3,
            "cap_busy": (state >> 6) & 1,
            "cap_done": (state >> 7) & 1,
            "crc_busy": (state >> 8) & 1,
            "fault_channels": self.client.read32(REG_FAULTS),
            "length_beats": self.client.read32(REG_TX_LENGTH),
            "channel_mask": self.client.read32(REG_TX_MASK),
            "abi": self.client.read32(REG_ABI),
            "tx_max_words": max_words & 0xFFFF,
            "cap_max_words": max_words >> 16,
            "cap_status": self.client.read32(REG_CAP_STATUS),
        }

    @staticmethod
    def _decode_status(state: int) -> dict[str, int]:
        return {"running": state & 1, "busy": (state >> 1) & 1, "ps_ready": (state >> 2) & 1,
                "fault": (state >> 3) & 1, "command_result": (state >> 4) & 3, "cap_busy": (state >> 6) & 1,
                "cap_done": (state >> 7) & 1, "crc_busy": (state >> 8) & 1}

    def command(self, value: int, timeout: float = 5.0) -> dict[str, int]:
        """Issue COMMAND and wait until it completes. Polls only the STATUS register (one read each)."""
        before = self._decode_status(self.client.read32(REG_STATUS))
        if before["busy"]:
            raise AwgEthError("Previous RF command is still busy")
        if not before["ps_ready"]:
            raise AwgEthError("PS not ready: initialize the matching RF firmware first")
        self.client.write32(REG_COMMAND, value)
        deadline = time.monotonic() + timeout
        polls = 0
        while True:
            current = self._decode_status(self.client.read32(REG_STATUS))
            if not current["busy"] and not (value == 16 and current["crc_busy"]):
                if current["command_result"]:
                    raise AwgEthError(f"RF command rejected: result={current['command_result']}")
                return current
            if time.monotonic() >= deadline:
                raise TimeoutError(f"RF command {value} timed out: {current}")
            polls += 1
            if polls > 50:                       # each read already costs one round trip
                time.sleep(0.001)

    def stop(self) -> dict[str, int]:
        self.command(1)
        return self.status()

    def clear(self) -> dict[str, int]:
        self.command(4)
        return self.status()

    def start(self) -> dict[str, int]:
        self.command(2)
        return self.status()

    def abort_capture(self) -> dict[str, int]:
        """COMMAND=32: cancel an armed or running capture (accepted when idle too)."""
        self.client.write32(REG_COMMAND, 32)
        return self.status()

    def load(self, directory: str | Path, verify: bool = True) -> dict[str, int]:
        folder = Path(directory)
        meta, channels = _parse_waveform(folder)
        return self.load_words(channels, meta["samples"], meta["channel_mask"], verify=verify)

    def load_words(self, channels: dict[int, Sequence[int]], samples: int, channel_mask: int,
                   *, verify: bool = True, cancel: Callable[[], bool] | None = None) -> dict[str, int]:
        """Write packed sample pairs (low int16 first) per channel, CRC-check each, then set TX_MASK."""
        if not 32 <= samples <= TX_MAX_SAMPLES or samples % 32:
            raise ValueError(f"samples must be 32..{TX_MAX_SAMPLES} and divisible by 32")
        pair_count = samples // 2
        for channel, words in channels.items():
            if not 0 <= channel < 8 or len(words) != pair_count:
                raise ValueError(f"CH{channel} must hold {pair_count} packed sample pairs")
        self.stop()
        self.clear()
        self.client.write32(REG_TX_MASK, 0)
        self.client.write32(REG_TX_LENGTH, samples // 32)
        self.pipeline_fallbacks = 0
        self.fallback_log = []
        self.last_write_seconds = 0.0
        for channel, words in channels.items():
            words = tuple(words)
            if min(words) < 0 or max(words) > 0xFFFFFFFF:
                words = tuple(int(w) & 0xFFFFFFFF for w in words)
            for attempt in range(3):
                # attempt 0: pipelined; later attempts (after a lost packet or CRC mismatch): one packet at a time
                t0 = time.perf_counter()
                self._write_channel(channel, words, samples, pipelined=attempt == 0, cancel=cancel)
                self.last_write_seconds += time.perf_counter() - t0      # data writes only
                if not verify:
                    break
                self.command(16)
                actual = self.client.read32(REG_TX_CRC)
                expected = crc32_tx_words(words)
                if actual == expected:
                    self._progress("verify", f"CH{channel}", samples, samples)
                    break
                if attempt == 2:
                    raise AwgEthError(
                        f"CRC mismatch CH{channel}: expected 0x{expected:08X}, got 0x{actual:08X}",
                        address=REG_TX_CRC,
                    )
                self.pipeline_fallbacks += 1
                self.fallback_log.append(("crc", channel, attempt, f"{actual:08X}/{expected:08X}",
                                          self.client.read32(REG_TX_WR_PTR)))
        self.client.write32(REG_TX_MASK, channel_mask & 0xFF)
        return self.status()

    def _write_channel(self, channel: int, words: tuple[int, ...], samples: int, *, pipelined: bool,
                       cancel: Callable[[], bool] | None) -> None:
        def progress(done, total):
            self._progress("write", f"CH{channel}", done * 2, samples)

        self.client.write32(REG_TX_WR_CH, channel)             # selects the channel and rewinds its write pointer
        if pipelined:
            try:
                self.client.write_stream(REG_TX_WR_DATA, words, on_progress=progress, cancel=cancel)
                return
            except PipelineAbort as exc:
                self.pipeline_fallbacks += 1
                getattr(self, "fallback_log", []).append(
                    ("timeout", channel, sum(r is not None for r in exc.results), len(exc.results)))
                self.client.drain()
                self.client.write32(REG_TX_WR_CH, channel)     # rewind and resend the whole channel safely
        n = self.client.words_per_packet
        for offset in range(0, len(words), n):
            if cancel and cancel():
                raise AwgEthError("load cancelled")
            self.client.write_block(REG_TX_WR_DATA, words[offset:offset + n], noinc=True)
            progress(min(offset + n, len(words)), len(words))

    def wait_capture_done(self, timeout: float = 10.0) -> int:
        deadline = time.monotonic() + timeout
        polls = 0
        while True:
            state = self.client.read32(REG_CAP_STATUS)
            if state & 2 and not state & 1:
                return state
            if time.monotonic() >= deadline:
                samples = self.client.read32(REG_CAP_SAMPLES)
                raise TimeoutError(f"ADC capture timed out: cap_status={state}, samples={samples}")
            polls += 1
            if polls > 50:                       # a capture takes ~13 us; only back off when it is waiting
                time.sleep(0.001)

    def capture_raw(self, trigger: str = "manual", channel_mask: int = 0xFF, *,
                    samples: int = CAP_MAX_SAMPLES,
                    cancel: Callable[[], bool] | None = None) -> tuple[int, int, dict[int, list[int]]]:
        """Arm, trigger and read back. Returns (captured samples, cap_tx_word, {channel: packed pairs})."""
        if trigger not in {"manual", "start"}:
            raise ValueError("trigger must be 'manual' or 'start'")
        if not 1 <= channel_mask <= 0xFF:
            raise ValueError("channel_mask must be 1..255")
        if not 24 <= samples <= CAP_MAX_SAMPLES or samples % 24:
            raise ValueError(f"capture samples must be 24..{CAP_MAX_SAMPLES} and divisible by 24")
        if self.client.read32(REG_CAP_STATUS) & 5:
            # A capture left armed (e.g. an earlier start-triggered capture that timed out or was
            # cancelled) makes CAP_CTRL return SLVERR. Cancel it first.
            self.abort_capture()
        if trigger == "start" and self.status()["running"]:
            self.stop()
        self.client.write32(REG_CAP_CTRL, ((samples // 24) << 16) | (1 if trigger == "start" else 0))
        try:
            self.command(8)
            if trigger == "start":
                self.start()
            self.wait_capture_done()
        except BaseException:
            try:
                self.abort_capture()             # never leave the capture armed behind an error
            except Exception:  # noqa: BLE001 — keep the original error
                pass
            raise
        captured = self.client.read32(REG_CAP_SAMPLES)
        if not 24 <= captured <= CAP_MAX_SAMPLES or captured % 24:
            raise AwgEthError(f"invalid captured sample count: {captured}", address=REG_CAP_SAMPLES)
        cap_tx_word = self.client.read32(REG_CAP_TX_WORD)
        pair_count = captured // 2
        result: dict[int, list[int]] = {}
        t0 = time.perf_counter()
        for channel in (ch for ch in range(8) if channel_mask & (1 << ch)):
            result[channel] = self._read_channel(channel, pair_count, captured, cancel)
        self.last_read_seconds = time.perf_counter() - t0     # data readback only (no arm/trigger/wait)
        return captured, cap_tx_word, result

    def _read_channel(self, channel: int, pair_count: int, captured: int,
                      cancel: Callable[[], bool] | None) -> list[int]:
        n = self.client.words_per_packet
        self.client.write32(REG_CAP_RD_CH, channel)
        self.client.write32(REG_CAP_RD_PTR, 0)       # D3C rewinds on CAP_RD_CH; kept for the D3B bitstream
        pairs: list[int] = []

        def progress(done, total):
            self._progress("capture", f"CH{channel}", min((len(pairs) + done) * 2, captured), captured)
        try:
            pairs = self.client.read_stream(REG_CAP_RD_DATA, pair_count, on_progress=progress, cancel=cancel)
            return pairs
        except PipelineAbort as exc:
            # Replies before the first missing one are in order and correct; resume from there safely.
            self.pipeline_fallbacks = getattr(self, "pipeline_fallbacks", 0) + 1
            for reply in exc.results:
                if reply is None:
                    break
                pairs.extend(reply.data)
            self.client.drain()
        while len(pairs) < pair_count:
            if cancel and cancel():
                raise AwgEthError("capture cancelled")
            self.client.write32(REG_CAP_RD_PTR, len(pairs))
            count = min(n, pair_count - len(pairs))
            pairs.extend(self.client.read_block(REG_CAP_RD_DATA, count, noinc=True))
            progress(0, pair_count)
        return pairs

    def capture(self, csv_path: str | Path, trigger: str = "manual", channel_mask: int = 0xFF,
                *, samples: int = CAP_MAX_SAMPLES) -> str:
        if trigger not in {"manual", "start"}:
            raise ValueError("trigger must be 'manual' or 'start'")
        if not 1 <= channel_mask <= 0xFF:
            raise ValueError("channel_mask must be 1..255")
        if not 24 <= samples <= CAP_MAX_SAMPLES or samples % 24:
            raise ValueError(f"capture samples must be 24..{CAP_MAX_SAMPLES} and divisible by 24")
        captured, cap_tx_word, raw = self.capture_raw(trigger, channel_mask, samples=samples)
        target = Path(csv_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        enabled = [channel for channel in range(8) if channel_mask & (1 << channel)]
        values: dict[int, list[int]] = {}
        for channel in enabled:
            pairs = raw[channel]
            samples_ch = []
            for pair in pairs:
                for shift in (0, 16):
                    value = (pair >> shift) & 0xFFFF
                    samples_ch.append(value - 0x10000 if value & 0x8000 else value)
            values[channel] = samples_ch
        with target.open("w", newline="", encoding="ascii") as stream:
            writer = csv.writer(stream, lineterminator="\n")
            for index in range(captured):
                writer.writerow([values[channel][index] for channel in enabled])
        metadata = {
            "format": "47dr-raw-adc-v2",
            "fs_hz": ADC_FS_HZ,
            "channel_mask": channel_mask,
            "samples": captured,
            "sample_bits": 14,
            "signed": True,
            "trigger": trigger,
            "cap_tx_word": cap_tx_word,
        }
        target.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        return str(target)
