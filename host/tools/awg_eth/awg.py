"""High-level v2 AWG and raw ADC operations."""

from __future__ import annotations

import binascii
import csv
import json
from pathlib import Path
import struct
import time
from typing import Callable, Iterable, Sequence

import numpy as np

from . import bulk as bulk_protocol
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
REG_CAP_LEN = REG_BASE + 0x58
REG_CAP_MODE = REG_BASE + 0x5C
REG_CAP_BANK_WORDS = REG_BASE + 0x60
REG_TX_MODE = REG_BASE + 0x64

DAC_FS_HZ = 9_800_000_000
ADC_FS_HZ = 5_000_000_000
ABI = 0x00030001
ABI_V2 = 0x00040000
ABI_V21 = 0x00050000          # V2.1: TX pooling (TX_MODE), STATUS[9] start_rejected (doc/04)
TX_MAX_WORDS = 4096           # per TX bank
TX_POOL_MAX_SAMPLES = 8 * TX_MAX_WORDS * 32     # one pooled TX slot (1,048,576 samples)
CAP_MAX_WORDS = 2730
CAP_BANK_WORDS = 10240
TX_MAX_SAMPLES = TX_MAX_WORDS * 32
CAP_MAX_SAMPLES = CAP_MAX_WORDS * 24
PROGRESS = Callable[[str, str, int, int], None]
BULK_RXR_WINDOW = 64  # outstanding RXR requests (V2.1 board, native: median ~8.3 Gb/s vs ~6.9 at 32; step2 report)
CAPTURE_MARGIN_SAMPLES = 1200  # start-trigger latency (~480 samples on the board) plus slack


def pool_slots(n_channels: int) -> int:
    """Smallest power of two >= n_channels (1..8): the pooling mode for that many channels."""
    if not 1 <= n_channels <= 8:
        raise ValueError("n_channels must be 1..8")
    slots = 1
    while slots < n_channels:
        slots <<= 1
    return slots


def capture_samples_for_tx(tx_samples: int, limit: int) -> int:
    """ADC samples covering twice the TX loop duration (doc/04 §4), multiple of 24, capped at limit."""
    need = 2 * tx_samples * ADC_FS_HZ / DAC_FS_HZ + CAPTURE_MARGIN_SAMPLES
    need = int(-(-need // 24) * 24)
    return max(24, min(limit - limit % 24, need))


def crc32_tx_words(words: Iterable[int]) -> int:
    """CRC-32/IEEE over paired int16 samples after the hardware's 14-bit mask."""
    if isinstance(words, np.ndarray):                  # fast path: one vectorized mask, no Python ints
        if words.dtype != np.uint32:
            words = (words.astype(np.int64) & 0xFFFFFFFF).astype(np.uint32)
        masked = np.bitwise_and(words, np.uint32(0xFFFCFFFC), dtype="<u4")
        return binascii.crc32(masked) & 0xFFFFFFFF
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
    if not 32 <= samples <= TX_POOL_MAX_SAMPLES or samples % 32:
        raise ValueError(f"samples must be 32..{TX_POOL_MAX_SAMPLES} and divisible by 32")
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
        self.bulk: bulk_protocol.BulkClient | None = None
        self._abi_value = ABI
        self._cap_bank_words = CAP_BANK_WORDS
        self._bulk_stat: dict[str, int] | None = None
        self.last_write_seconds = 0.0
        self.last_read_seconds = 0.0
        self.pipeline_fallbacks = 0
        self.fallback_log: list[tuple] = []
        self._detect_bulk()

    def _detect_bulk(self) -> None:
        """Probe the V2 ABI and keep one 9101 socket for this AWG connection."""
        try:
            abi = int(self.client.read32(REG_ABI))
        except Exception:
            return
        self._abi_value = abi
        if abi < ABI_V2:
            return
        bulk_port = 9101 if self.client.port == 9100 else self.client.port + 1
        candidate = bulk_protocol.BulkClient(
            self.client.fpga_ip, port=bulk_port, timeout=self.client.timeout,
            retries=self.client.retries, window=BULK_RXR_WINDOW,
        )
        try:
            self._bulk_stat = candidate.stat()
        except Exception:
            candidate.close()
            return
        self.bulk = candidate
        if int(self._bulk_stat.get("build_id", 0)) == 0xD4A02026:
            # E6 on the D4A0 bitstream: START is rejected after bulk TXW (R1), and more than one RXR
            # in flight hangs 9100/9101 (R2). Write TX over 9100 and keep one RXR outstanding there.
            self._bulk_tx_ok = False
            candidate.window = 1
        else:
            self._bulk_tx_ok = True
        try:
            self._cap_bank_words = int(self.client.read32(REG_MAX_WORDS) >> 16) or CAP_BANK_WORDS
        except Exception:
            self._cap_bank_words = CAP_BANK_WORDS

    def close(self) -> None:
        if self.bulk is not None:
            self.bulk.close()
            self.bulk = None

    def _progress(self, phase: str, channel: str, done: int, total: int) -> None:
        if self.progress_callback:
            self.progress_callback(phase, channel, done, total)

    def status(self) -> dict[str, int]:
        if self._abi_value >= ABI_V2:
            return self._status_block()
        state = self.client.read32(REG_STATUS)
        max_words = self.client.read32(REG_MAX_WORDS)
        abi = self.client.read32(REG_ABI)
        self._abi_value = abi
        result = {
            "running": state & 1,
            "busy": (state >> 1) & 1,
            "ps_ready": (state >> 2) & 1,
            "fault": (state >> 3) & 1,
            "command_result": (state >> 4) & 3,
            "cap_busy": (state >> 6) & 1,
            "cap_done": (state >> 7) & 1,
            "crc_busy": (state >> 8) & 1,
            "start_rejected": (state >> 9) & 1,
            "started": (state >> 10) & 1,
            "fault_channels": self.client.read32(REG_FAULTS),
            "length_beats": self.client.read32(REG_TX_LENGTH),
            "channel_mask": self.client.read32(REG_TX_MASK),
            "abi": abi,
            "tx_max_words": max_words & 0xFFFF,
            "cap_max_words": max_words >> 16,
            "cap_status": self.client.read32(REG_CAP_STATUS),
        }
        if abi >= ABI_V2:
            try:
                result.update({
                    "cap_len": self.client.read32(REG_CAP_LEN),
                    "cap_mode": self.client.read32(REG_CAP_MODE),
                    "cap_bank_words": self.client.read32(REG_CAP_BANK_WORDS),
                    "bulk_available": int(self.bulk is not None),
                })
                if abi >= ABI_V21:
                    result["tx_mode"] = self.client.read32(REG_TX_MODE)
                self._cap_bank_words = result["cap_bank_words"] or CAP_BANK_WORDS
            except AwgEthError:
                result["bulk_available"] = int(self.bulk is not None)
        else:
            result["bulk_available"] = 0
        return result

    def _status_block(self) -> dict[str, int]:
        """status() in three round trips: STATUS, then 0x0C..0x28 and 0x58..0x64 as block reads. Every
        address in those blocks is readable without side effects (awg_control_v2 returns SLVERR for the
        unmapped 0x08 COMMAND and 0x38 TX_WR_DATA, so STATUS is read on its own)."""
        state = self.client.read32(REG_STATUS)
        r = self.client.read_block(REG_TX_LENGTH, (REG_CAP_STATUS - REG_TX_LENGTH) // 4 + 1)
        last = REG_TX_MODE if self._abi_value >= ABI_V21 else REG_CAP_BANK_WORDS     # TX_MODE is V2.1 only
        tail = self.client.read_block(REG_CAP_LEN, (last - REG_CAP_LEN) // 4 + 1)

        def at(reg):
            return r[(reg - REG_TX_LENGTH) // 4]
        abi, max_words = at(REG_ABI), at(REG_MAX_WORDS)
        self._abi_value = abi
        result = self._decode_status(state)
        result.update({
            "fault_channels": at(REG_FAULTS), "length_beats": at(REG_TX_LENGTH), "channel_mask": at(REG_TX_MASK),
            "abi": abi, "tx_max_words": max_words & 0xFFFF, "cap_max_words": max_words >> 16,
            "cap_status": at(REG_CAP_STATUS),
            "cap_len": tail[0], "cap_mode": tail[1], "cap_bank_words": tail[2],
            "bulk_available": int(self.bulk is not None),
        })
        if abi >= ABI_V21:
            result["tx_mode"] = tail[3]
        self._cap_bank_words = result["cap_bank_words"] or CAP_BANK_WORDS
        return result

    def max_capture_samples(self, n_channels: int) -> int:
        """Return the capture limit for the current bitstream and selected channel count."""
        if not 1 <= n_channels <= 8:
            raise ValueError("n_channels must be 1..8")
        if self.bulk is None or self._abi_value < ABI_V2:
            return 65520
        slots = 1
        while slots < n_channels:
            slots <<= 1
        return (8 // slots) * self._cap_bank_words * 24

    def max_tx_samples(self, n_channels: int) -> int:
        """TX waveform limit per channel for this bitstream when n_channels DAC channels play."""
        slots = pool_slots(n_channels)
        if self._abi_value >= ABI_V21:
            return (8 // slots) * TX_MAX_SAMPLES
        return TX_MAX_SAMPLES

    def tx_limit_for_capture(self, n_tx: int, n_rx: int) -> int:
        """Largest TX length (multiple of 32) whose loop still fits twice in an n_rx-channel capture."""
        rx_limit = self.max_capture_samples(n_rx) - CAPTURE_MARGIN_SAMPLES
        by_rx = int(rx_limit * DAC_FS_HZ / ADC_FS_HZ / 2) // 32 * 32
        return max(32, min(self.max_tx_samples(n_tx), by_rx))

    @staticmethod
    def _decode_status(state: int) -> dict[str, int]:
        return {"running": state & 1, "busy": (state >> 1) & 1, "ps_ready": (state >> 2) & 1,
                "fault": (state >> 3) & 1, "command_result": (state >> 4) & 3, "cap_busy": (state >> 6) & 1,
                "cap_done": (state >> 7) & 1, "crc_busy": (state >> 8) & 1,
                "start_rejected": (state >> 9) & 1, "started": (state >> 10) & 1}

    def command(self, value: int, timeout: float = 5.0) -> dict[str, int]:
        """Issue COMMAND and wait until it completes. Polls only the STATUS register (one read each)."""
        self._command_issue(value)
        return self._command_wait(value, timeout)

    def _command_issue(self, value: int) -> None:
        before = self._decode_status(self.client.read32(REG_STATUS))
        if before["busy"]:
            raise AwgEthError("Previous RF command is still busy")
        if not before["ps_ready"]:
            raise AwgEthError("PS not ready: initialize the matching RF firmware first")
        self.client.write32(REG_COMMAND, value)

    def _command_wait(self, value: int, timeout: float = 5.0) -> dict[str, int]:
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
        current = self.command(2)
        if self._abi_value >= ABI_V21 and current.get("start_rejected"):
            # V2.1: awg_control accepts START; awg_tx refuses short/void data and reports STATUS[9].
            raise AwgEthError("TX refused START: a selected slot has less data than TX_LENGTH "
                              "(reload after changing the channel count)")
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
        pair_count = samples // 2
        for channel, words in channels.items():
            if not 0 <= channel < 8 or len(words) != pair_count:
                raise ValueError(f"CH{channel} must hold {pair_count} packed sample pairs")
        pooled = self._abi_value >= ABI_V21
        if pooled:
            # V2.1 TX pooling: the enabled DAC channels become slots 0..n-1 of the smallest mode that
            # fits them; slot s plays on DAC channel enabled[s] (doc/04 §3).
            enabled = [ch for ch in sorted(channels) if channel_mask & (1 << ch)]
            if not enabled:
                raise ValueError("channel_mask selects no loaded channel")
            limit = self.max_tx_samples(len(enabled))
        else:
            enabled = sorted(channels)
            limit = TX_MAX_SAMPLES
        if not 32 <= samples <= limit or samples % 32:
            raise ValueError(f"samples must be 32..{limit} and divisible by 32 for {len(enabled)} channel(s)")
        use_bulk = self.bulk is not None and self._abi_value >= ABI_V2 and getattr(self, "_bulk_tx_ok", True)
        if use_bulk and self.bulk.native_sequences:
            return self._load_native(channels, samples, channel_mask, enabled, pooled, verify, cancel)
        self.command(1)                                   # stop
        self.command(4)                                   # clear
        self.client.write32(REG_TX_MASK, 0)
        if pooled:
            slots = pool_slots(len(enabled))
            mode = slots.bit_length() - 1
            for slot in range(8):
                dac = enabled[slot] if slot < len(enabled) else (slot if slot >= slots else enabled[0])
                mode |= dac << (8 + 3 * slot)
            self.client.write32(REG_TX_MODE, mode)
            targets = list(enumerate(enabled))           # (slot, DAC channel)
        else:
            targets = [(channel, channel) for channel in enabled]
        self.client.write32(REG_TX_LENGTH, samples // 32)
        self.pipeline_fallbacks = 0
        self.fallback_log = []
        self.last_write_seconds = 0.0
        for slot, channel in targets:
            source = channels[channel]
            if isinstance(source, np.ndarray) and source.dtype == np.uint32:
                words = source
            else:
                words = (np.asarray(source, dtype=np.int64) & 0xFFFFFFFF).astype(np.uint32)
            if not use_bulk:
                words = tuple(words.tolist())         # 9100 path works on Python ints
            for attempt in range(3):
                t0 = time.perf_counter()
                if use_bulk:
                    self.client.write32(REG_TX_WR_CH, slot)
                    self.bulk.write_tx(
                        slot, words,
                        cancel=cancel,
                        on_progress=lambda done, total: self._progress("write", f"CH{channel}", done * 2, samples),
                    )
                else:
                    # attempt 0: pipelined; later attempts (after a lost packet or CRC mismatch): one packet at a time
                    self._write_channel(slot, words, samples, pipelined=attempt == 0, cancel=cancel)
                self.last_write_seconds += time.perf_counter() - t0      # data writes only
                if not verify:
                    break
                self._command_issue(16)                   # the FPGA CRC runs while the host computes its own
                expected = crc32_tx_words(words)
                self._command_wait(16)
                actual = self.client.read32(REG_TX_CRC)
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
        if pooled:
            self.client.write32(REG_TX_MASK, (1 << len(targets)) - 1)
        else:
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
                    slots: Sequence[int] | None = None,
                    cancel: Callable[[], bool] | None = None) -> tuple[int, int, dict[int, list[int]]]:
        """Arm, trigger and read back. Returns (captured samples, cap_tx_word, {channel: packed pairs})."""
        if trigger not in {"manual", "start"}:
            raise ValueError("trigger must be 'manual' or 'start'")
        if not 1 <= channel_mask <= 0xFF:
            raise ValueError("channel_mask must be 1..255")
        enabled = [ch for ch in range(8) if channel_mask & (1 << ch)]
        limit = self.max_capture_samples(len(enabled))
        if not 24 <= samples <= limit or samples % 24:
            raise ValueError(f"capture samples must be 24..{limit} and divisible by 24")
        use_bulk = self.bulk is not None and self._abi_value >= ABI_V2
        if self.client.read32(REG_CAP_STATUS) & 5:
            # CAP_MODE must not be written while a previous capture is armed,
            # including when the subsequent sequence uses the native DLL.
            self.client.write32(REG_COMMAND, 32)
        if not (use_bulk and self.bulk.native_sequences):
            if self.client.read32(REG_CAP_STATUS) & 5:
                # A capture left armed (e.g. an earlier start-triggered capture that timed out or was
                # cancelled) makes CAP_CTRL return SLVERR. Cancel it first.
                self.client.write32(REG_COMMAND, 32)
            if trigger == "start" and self.client.read32(REG_STATUS) & 1:
                self.command(1)                                   # stop
        t_start = time.perf_counter()
        selected: list[int] = []
        slot_for_channel: dict[int, int] = {}
        if use_bulk:
            slots_count = 1
            while slots_count < len(enabled):
                slots_count <<= 1
            if slots is not None:
                selected = [int(ch) for ch in slots]
                if len(selected) < slots_count:
                    selected.extend([selected[0] if selected else enabled[0]] * (slots_count - len(selected)))
                selected = selected[:slots_count]
            else:
                selected = enabled[:slots_count]
                selected.extend([enabled[0]] * (slots_count - len(selected)))
            if any(ch < 0 or ch > 7 for ch in selected):
                raise ValueError("capture slots must contain channel numbers 0..7")
            if any(channel not in selected for channel in enabled):
                raise ValueError("capture slots must include every selected ADC channel")
            mode = (slots_count.bit_length() - 1)
            for slot, channel in enumerate(selected):
                mode |= channel << (8 + 3 * slot)
            self.client.write32(REG_CAP_MODE, mode)
            for channel in enabled:
                slot_for_channel.setdefault(channel, selected.index(channel))
        cap_words = samples // 24
        cap_ctrl = (1 if trigger == "start" else 0)
        if use_bulk and self.bulk.native_sequences:
            return self._capture_native(trigger, enabled, selected, slot_for_channel, mode, cap_ctrl, cap_words,
                                        limit, cancel)
        if use_bulk:
            # CAP_CTRL[27:16] also writes CAP_LEN (V1 compatible, 12 bits, 0 is rejected with SLVERR),
            # so write CAP_CTRL first with a legal short length, then the full 17-bit CAP_LEN.
            self.client.write32(REG_CAP_CTRL, cap_ctrl | (min(cap_words, 0xFFF) << 16))
            self.client.write32(REG_CAP_LEN, cap_words)
        else:
            self.client.write32(REG_CAP_CTRL, cap_ctrl | (cap_words << 16))
        try:
            self.command(8)
            if trigger == "start":
                current = self.command(2)
                if self._abi_value >= ABI_V21 and current.get("start_rejected"):
                    raise AwgEthError("TX refused START: a selected slot has less data than TX_LENGTH "
                                      "(reload after changing the channel count)")
            self.wait_capture_done()
        except BaseException:
            try:
                self.abort_capture()             # never leave the capture armed behind an error
            except Exception:  # noqa: BLE001 — keep the original error
                pass
            raise
        captured = self.client.read32(REG_CAP_SAMPLES)
        if captured != samples or not 24 <= captured <= limit or captured % 24:
            raise AwgEthError(f"invalid captured sample count: {captured}", address=REG_CAP_SAMPLES)
        cap_tx_word = self.client.read32(REG_CAP_TX_WORD)
        pair_count = captured // 2
        result: dict[int, list[int] | np.ndarray] = {}
        t0 = time.perf_counter()
        if use_bulk:
            for channel in enabled:
                result[channel] = self.bulk.read_rx(
                    slot_for_channel[channel], 0, pair_count, cancel=cancel,
                    on_progress=lambda done, total, ch=channel: self._progress(
                        "capture", f"CH{ch}", min(done * 2, captured), captured),
                )
        else:
            for channel in enabled:
                result[channel] = self._read_channel(channel, pair_count, captured, cancel)
        self.last_read_seconds = time.perf_counter() - t0     # data readback only (no arm/trigger/wait)
        self.last_capture_timing = {"control_s": t0 - t_start, "read_s": self.last_read_seconds,
                                    "reg_ops": -1, "native": False}
        return captured, cap_tx_word, result

    # ---- native whole sequences (native/awg_bulk.dll awg_capture / awg_load) ---------------------
    def _raise_sequence_error(self, rc: int, res, ctl, blk, opcode: int) -> None:
        if rc == bulk_protocol.RC_CMD:
            step, detail, cmd = res.failed_step, res.detail, res.command
            if step == bulk_protocol.SEQ_BUSY:
                raise AwgEthError("Previous RF command is still busy")
            if step == bulk_protocol.SEQ_NOT_READY:
                raise AwgEthError("PS not ready: initialize the matching RF firmware first")
            if step == bulk_protocol.SEQ_REJECTED:
                raise AwgEthError(f"RF command rejected: result={(detail >> 4) & 3}")
            if step == bulk_protocol.SEQ_CMD_TIMEOUT:
                raise TimeoutError(f"RF command {cmd} timed out: {self._decode_status(detail)}")
            if step == bulk_protocol.SEQ_START_REJECTED:
                raise AwgEthError("TX refused START: a selected slot has less data than TX_LENGTH "
                                  "(reload after changing the channel count)")
            if step == bulk_protocol.SEQ_CAP_TIMEOUT:
                raise TimeoutError(f"ADC capture timed out: cap_status={detail}, samples={cmd}")
            if step == bulk_protocol.SEQ_BAD_COUNT:
                raise AwgEthError(f"invalid captured sample count: {detail}", address=REG_CAP_SAMPLES)
            raise AwgEthError(f"native sequence failed: step={step} detail=0x{detail:08X}")
        if ctl.error_status or (rc == bulk_protocol._RC_TIMEOUT and ctl.error_offset):
            address = int(ctl.error_offset) & 0xFFFFFFFF
            if rc == bulk_protocol._RC_STATUS:
                raise AwgEthError(f"FPGA request failed: status={ctl.error_status}, err_index=0, "
                                  f"address=0x{address:08X}", status=ctl.error_status, err_index=0, address=address)
            raise TimeoutError(f"FPGA timeout after {self.client.retries} retries: address=0x{address:08X}")
        if rc == bulk_protocol._RC_SOCKET and ctl.wsa_error:
            raise OSError(ctl.wsa_error, f"9100 socket error (WSA {ctl.wsa_error})")
        self.bulk.raise_data_error(rc, blk, opcode)

    def _capture_native(self, trigger, enabled, selected, slot_for_channel, mode, cap_ctrl, cap_words, limit,
                        cancel):
        args = bulk_protocol.NativeCapArgs(
            base=REG_BASE, trigger_start=int(trigger == "start"),
            check_start_rejected=int(self._abi_value >= ABI_V21), write_mode_len=1,
            cap_mode=mode, cap_ctrl=cap_ctrl | (min(cap_words, 0xFFF) << 16), cap_len=cap_words,
            limit=limit, n_read=len(enabled), window=self.bulk.window, cmd_timeout_s=5.0, cap_timeout_s=10.0)
        for i, channel in enumerate(enabled):
            args.read_slot[i] = slot_for_channel[channel]
        buffers = [np.empty(limit // 2, dtype="<u4") for _ in enabled]

        def progress(index, done, total):
            self._progress("capture", f"CH{enabled[index]}", min(done * 2, total * 2), total * 2)
        rc, res, ctl, blk = self.bulk.run_sequence("capture", self.client, args, buffers, cancel=cancel,
                                                   on_progress=progress if self.progress_callback else None)
        if rc:
            self._raise_sequence_error(rc, res, ctl, blk, bulk_protocol.OP_RXR)
        if res.captured != cap_words * 24:
            raise AwgEthError(f"capture sample count mismatch: {res.captured}", address=REG_CAP_SAMPLES)
        pairs = res.captured // 2
        self.last_read_seconds = res.t_data
        self.last_capture_timing = {"control_s": res.t_control, "read_s": res.t_data,
                                    "reg_ops": int(res.reg_ops), "native": True}
        return res.captured, res.cap_tx_word, {ch: buffers[i][:pairs] for i, ch in enumerate(enabled)}

    def _load_native(self, channels, samples, channel_mask, enabled, pooled, verify, cancel):
        if pooled:
            slots = pool_slots(len(enabled))
            mode = slots.bit_length() - 1
            for slot in range(8):
                dac = enabled[slot] if slot < len(enabled) else (slot if slot >= slots else enabled[0])
                mode |= dac << (8 + 3 * slot)
            targets = list(enumerate(enabled))
            final_mask = (1 << len(targets)) - 1
        else:
            mode = 0
            targets = [(channel, channel) for channel in enabled]
            final_mask = channel_mask & 0xFF
        buffers = []
        args = bulk_protocol.NativeLoadArgs(
            base=REG_BASE, pooled=int(pooled), tx_mode=mode, length_beats=samples // 32, final_mask=final_mask,
            n_slots=len(targets), nwords=samples // 2, verify=int(verify), words_per_packet=2048,
            batch_packets=2, batches_in_flight=4, cmd_timeout_s=5.0)
        for i, (slot, channel) in enumerate(targets):
            source = channels[channel]
            if isinstance(source, np.ndarray) and source.dtype == np.uint32 and source.flags.c_contiguous:
                words = source
            else:
                words = np.ascontiguousarray((np.asarray(source, dtype=np.int64) & 0xFFFFFFFF).astype(np.uint32))
            buffers.append(words)
            args.slot[i] = slot
            if verify:
                args.crc_expected[i] = crc32_tx_words(words)

        def progress(index, done, total):
            self._progress("write", f"CH{targets[index][1]}", done * 2, samples)
        rc, res, ctl, blk = self.bulk.run_sequence("load", self.client, args, buffers, cancel=cancel,
                                                   on_progress=progress if self.progress_callback else None)
        self.last_write_seconds = res.t_data
        self.pipeline_fallbacks = int(res.crc_retries)
        self.fallback_log = []
        self.last_load_timing = {"control_s": res.t_control, "write_s": res.t_data,
                                 "reg_ops": int(res.reg_ops), "native": True}
        if rc == bulk_protocol.RC_CMD and res.failed_step == bulk_protocol.SEQ_CRC:
            index = res.command
            raise AwgEthError(f"CRC mismatch CH{targets[index][1]}: expected 0x{args.crc_expected[index]:08X}, "
                              f"got 0x{res.detail:08X}", address=REG_TX_CRC)
        if rc:
            self._raise_sequence_error(rc, res, ctl, blk, bulk_protocol.OP_TXW)
        if verify:
            for _, channel in targets:
                self._progress("verify", f"CH{channel}", samples, samples)
        return self.status()

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
        limit = self.max_capture_samples(channel_mask.bit_count())
        if not 24 <= samples <= limit or samples % 24:
            raise ValueError(f"capture samples must be 24..{limit} and divisible by 24")
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
