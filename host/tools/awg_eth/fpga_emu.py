"""Loopback-only FPGA protocol and v2 register emulator."""

from __future__ import annotations

import argparse
import binascii
import random
import socket
import struct
import sys
import threading
from pathlib import Path
from typing import Callable

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from awg_eth import protocol
    from awg_eth.awg import (
        ABI, CAP_MAX_WORDS, REG_ABI, REG_ADC_FS_KSPS, REG_BASE, REG_BUILD_ID,
        REG_CAP_CTRL, REG_CAP_RD_CH, REG_CAP_RD_DATA, REG_CAP_RD_PTR, REG_CAP_SAMPLES,
        REG_CAP_STATUS, REG_CAP_TX_WORD, REG_COMMAND, REG_DAC_FS_KSPS, REG_FAULTS,
        REG_ID, REG_MAX_WORDS, REG_STATUS, REG_TX_CRC, REG_TX_LENGTH, REG_TX_MASK,
        REG_TX_WR_CH, REG_TX_WR_DATA, REG_TX_WR_PTR, TX_MAX_WORDS,
    )
else:
    from . import protocol
    from .awg import (
    ABI, CAP_MAX_WORDS, REG_ABI, REG_ADC_FS_KSPS, REG_BASE, REG_BUILD_ID,
    REG_CAP_CTRL, REG_CAP_RD_CH, REG_CAP_RD_DATA, REG_CAP_RD_PTR, REG_CAP_SAMPLES,
    REG_CAP_STATUS, REG_CAP_TX_WORD, REG_COMMAND, REG_DAC_FS_KSPS, REG_FAULTS,
    REG_ID, REG_MAX_WORDS, REG_STATUS, REG_TX_CRC, REG_TX_LENGTH, REG_TX_MASK,
    REG_TX_WR_CH, REG_TX_WR_DATA, REG_TX_WR_PTR, TX_MAX_WORDS,
    )

_HEADER = struct.Struct("<HBBIIHHHHI")


class FpgaEmulator:
    def __init__(self, host: str = "127.0.0.1", port: int = 0, *, drop_rate: float = 0.0,
                 duplicate_rate: float = 0.0, seed: int = 47, build_id: int = 1,
                 loopback: bool = False, loopback_delay_samples: int = 0,
                 event_callback: Callable[[str], None] | None = None):
        if not 0 <= drop_rate < 1 or not 0 <= duplicate_rate < 1:
            raise ValueError("drop_rate and duplicate_rate must be in [0,1)")
        self.host = host
        self.port = port
        self.drop_rate = drop_rate
        self.duplicate_rate = duplicate_rate
        self.random = random.Random(seed)
        self.build_id = build_id
        self.loopback = loopback
        self.loopback_delay_samples = loopback_delay_samples
        self.event_callback = event_callback
        self.ready = threading.Event()
        self.stopped = threading.Event()
        self._thread: threading.Thread | None = None
        self._socket: socket.socket | None = None
        self._lock = threading.RLock()
        self._tx_channel = 0
        self._tx_words: dict[int, list[int]] = {channel: [] for channel in range(8)}
        self._cap_channel = 0
        self._cap_pair_ptr = 0
        self._capture: dict[int, list[int]] = {channel: [] for channel in range(8)}
        self._cap_samples = 0
        self._cap_words = 0
        self._cap_trig_mode = 0
        self._cap_armed = False
        self._cap_busy = False
        self._cap_done = False
        self._cap_tx_word = 0
        self._running = False
        self._ps_ready = True
        self._faults = 0
        self._command_result = 0
        self._command_busy = False
        self._crc_busy = False
        self._tx_length = 1
        self._tx_mask = 0
        self._tx_crc = 0
        self._regs: dict[int, int] = {}
        self._last_write_seq: int | None = None
        self._last_write_reply: bytes | None = None
        self.counters = {
            "rx_ok": 0, "rx_bad_req": 0, "rx_dropped": 0, "tx_replies": 0,
            "dup_writes": 0, "axi_errors": 0, "axi_timeouts": 0, "axi_words": 0,
        }

    @property
    def address(self) -> tuple[str, int]:
        if not self._socket:
            raise RuntimeError("emulator is not started")
        return self._socket.getsockname()

    def start(self) -> "FpgaEmulator":
        if self._thread and self._thread.is_alive():
            return self
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        if hasattr(socket, "SIO_UDP_CONNRESET"):
            # Windows: a reply sent to an already-closed client port comes back as ICMP "port unreachable",
            # and the NEXT recvfrom then raises ConnectionResetError. Turn that behaviour off.
            self._socket.ioctl(socket.SIO_UDP_CONNRESET, False)
        self._socket.bind((self.host, self.port))
        self.port = self._socket.getsockname()[1]
        self.stopped.clear()
        self._thread = threading.Thread(target=self.serve_forever, name="fpga-emu", daemon=True)
        self._thread.start()
        if not self.ready.wait(2.0):
            self.close()
            raise TimeoutError("emulator did not become ready")
        return self

    def close(self) -> None:
        self.stopped.set()
        if self._socket:
            try:
                self._socket.close()
            except OSError:
                pass
        if self._thread and self._thread is not threading.current_thread():
            self._thread.join(2.0)
        self._socket = None

    def __enter__(self) -> "FpgaEmulator":
        return self.start()

    def __exit__(self, *_exc) -> None:
        self.close()

    def serve_forever(self) -> None:
        assert self._socket is not None
        self.ready.set()
        if self.event_callback:
            self.event_callback(f"LISTEN {self.host}:{self.port}")
        while not self.stopped.is_set():
            try:
                data, peer = self._socket.recvfrom(65535)
            except ConnectionResetError:
                continue                      # late/duplicate reply to a closed client socket (Windows)
            except OSError:
                break
            self._handle_datagram(data, peer)

    def _response(self, request: protocol.Packet, *, status: int = 0, count: int = 0,
                  err_index: int = 0, data: tuple[int, ...] = ()) -> bytes:
        return protocol.encode_packet(protocol.Packet(
            request.opcode | 0x80, request.seq, request.addr, count, request.flags,
            status, err_index, data,
        ), request=False)

    def _send(self, reply: bytes, peer: tuple[str, int]) -> None:
        if self.random.random() < self.drop_rate:
            self.counters["rx_dropped"] += 1
            return
        assert self._socket is not None
        try:
            self._socket.sendto(reply, peer)
            if self.random.random() < self.duplicate_rate:
                self._socket.sendto(reply, peer)
        except OSError:
            if not self.stopped.is_set():
                raise

    def _bad_req_response(self, raw: bytes) -> bytes | None:
        if len(raw) < protocol.HEADER_SIZE:
            self.counters["rx_dropped"] += 1
            return None
        magic, version, opcode, seq, addr, count, flags, _status, _err, _reserved = _HEADER.unpack_from(raw)
        if magic != protocol.MAGIC or version != protocol.VERSION:
            self.counters["rx_dropped"] += 1
            return None
        self.counters["rx_bad_req"] += 1
        request = protocol.Packet(opcode, seq, addr, count, flags)
        return self._response(request, status=protocol.STATUS_BAD_REQ)

    def _handle_datagram(self, raw: bytes, peer: tuple[str, int]) -> None:
        self._handle_once(raw, peer)
        if self.random.random() < self.duplicate_rate:
            self._handle_once(raw, peer)

    def _handle_once(self, raw: bytes, peer: tuple[str, int]) -> None:
        try:
            request = protocol.decode_packet(raw, response=False)
        except protocol.ProtocolError:
            reply = self._bad_req_response(raw)
            if reply:
                self._send(reply, peer)
            return
        if request.opcode not in (protocol.OP_READ, protocol.OP_WRITE, protocol.OP_INFO, protocol.OP_PING):
            self.counters["rx_bad_req"] += 1
            self._send(self._response(request, status=protocol.STATUS_BAD_REQ), peer)
            return
        if request.addr & 3 or request.flags & ~protocol.FLAG_NOINC:
            self.counters["rx_bad_req"] += 1
            self._send(self._response(request, status=protocol.STATUS_BAD_REQ), peer)
            return
        if request.opcode in (protocol.OP_READ, protocol.OP_WRITE):
            if not 1 <= request.count <= protocol.MAX_WORDS:
                self.counters["rx_bad_req"] += 1
                self._send(self._response(request, status=protocol.STATUS_BAD_REQ), peer)
                return
        elif request.count != 0 or request.data or request.flags:
            self.counters["rx_bad_req"] += 1
            self._send(self._response(request, status=protocol.STATUS_BAD_REQ), peer)
            return

        with self._lock:
            self.counters["rx_ok"] += 1
            if request.opcode == protocol.OP_WRITE and request.seq == self._last_write_seq:
                self.counters["dup_writes"] += 1
                assert self._last_write_reply is not None
                self._send(self._last_write_reply, peer)
                return
            reply = self._execute(request)
            if request.opcode == protocol.OP_WRITE:
                self._last_write_seq = request.seq
                self._last_write_reply = reply
            self.counters["tx_replies"] += 1
            self._send(reply, peer)

    def _execute(self, request: protocol.Packet) -> bytes:
        if request.opcode == protocol.OP_INFO:
            stats = self.counters
            values = (0x41574531, protocol.VERSION, protocol.MAX_WORDS, self.build_id,
                      stats["rx_ok"], stats["rx_bad_req"], stats["rx_dropped"], stats["tx_replies"],
                      stats["dup_writes"], stats["axi_errors"], stats["axi_timeouts"], stats["axi_words"], 0, 0, 0, 0)
            return self._response(request, count=16, data=values)
        if request.opcode == protocol.OP_PING:
            return self._response(request)

        done = 0
        response_data: list[int] = []
        for index, value in enumerate(request.data if request.opcode == protocol.OP_WRITE else range(request.count)):
            address = request.addr if request.flags & protocol.FLAG_NOINC else request.addr + index * 4
            if request.opcode == protocol.OP_WRITE:
                ok = self._write_register(address, value)
                if not ok:
                    self.counters["axi_errors"] += 1
                    return self._response(request, status=protocol.STATUS_AXI_ERR, count=done, err_index=index, data=tuple(response_data))
            else:
                ok, result = self._read_register(address)
                if not ok:
                    self.counters["axi_errors"] += 1
                    return self._response(request, status=protocol.STATUS_AXI_ERR, count=done, err_index=index, data=tuple(response_data))
                response_data.append(result)
            done += 1
            self.counters["axi_words"] += 1
        return self._response(request, count=done, data=tuple(response_data))

    def _status(self) -> int:
        return (
            int(self._running)
            | (int(self._command_busy) << 1)
            | (int(self._ps_ready) << 2)
            | (int(bool(self._faults)) << 3)
            | ((self._command_result & 3) << 4)
            | (int(self._cap_busy) << 6)
            | (int(self._cap_done) << 7)
            | (int(self._crc_busy) << 8)
        )

    def _cap_status(self) -> int:
        # doc/01: armed=1 implies busy=1
        return int(self._cap_busy or self._cap_armed) | (int(self._cap_done) << 1) | (int(self._cap_armed) << 2)

    def _read_register(self, address: int) -> tuple[bool, int]:
        fixed = {
            REG_ID: 0x41574732,
            REG_STATUS: self._status(),
            REG_DAC_FS_KSPS: 9_800_000,
            REG_ADC_FS_KSPS: 5_000_000,
            REG_FAULTS: self._faults,
            REG_ABI: ABI,
            REG_MAX_WORDS: (CAP_MAX_WORDS << 16) | TX_MAX_WORDS,
            REG_CAP_STATUS: self._cap_status(),
            REG_CAP_SAMPLES: self._cap_samples,
            REG_TX_WR_PTR: len(self._tx_words[self._tx_channel]) * 2,
            REG_TX_CRC: self._tx_crc,
            REG_CAP_TX_WORD: self._cap_tx_word,
            REG_BUILD_ID: self.build_id,
            REG_TX_LENGTH: self._tx_length,
            REG_TX_MASK: self._tx_mask,
        }
        if address in fixed:
            return True, fixed[address] & 0xFFFFFFFF
        if address == REG_CAP_RD_PTR:
            return True, self._cap_pair_ptr
        if address == REG_CAP_RD_DATA:
            if self._cap_pair_ptr >= CAP_MAX_WORDS * 12:
                return False, 0                   # D3C hardware: pointer past the buffer -> SLVERR
            pairs = self._capture[self._cap_channel]
            value = pairs[self._cap_pair_ptr] if self._cap_pair_ptr < len(pairs) else 0
            self._cap_pair_ptr += 1
            return True, value
        if address in self._regs:
            return True, self._regs[address]
        return False, 0

    def _write_register(self, address: int, value: int) -> bool:
        value &= 0xFFFFFFFF
        if address in (REG_TX_LENGTH, REG_TX_MASK, REG_TX_WR_CH, REG_TX_WR_DATA) and self._running:
            return False
        if address == REG_COMMAND:
            return self._command(value)
        if address == REG_TX_LENGTH:
            if not 1 <= value <= TX_MAX_WORDS or self._running:
                return False
            self._tx_length = value
            return True
        if address == REG_TX_MASK:
            if self._running:
                return False
            self._tx_mask = value & 0xFF
            return True
        if address == REG_TX_WR_CH:
            if value >= 8 or self._running:
                return False
            self._tx_channel = value
            self._tx_words[value] = []
            return True
        if address == REG_TX_WR_DATA:
            words = self._tx_words[self._tx_channel]
            if len(words) >= TX_MAX_WORDS * 16:
                return False
            words.append(value & 0xFFFCFFFC)
            return True
        if address == REG_CAP_CTRL:
            words = (value >> 16) & 0xFFF
            if self._cap_busy or self._cap_armed or not 1 <= words <= CAP_MAX_WORDS:
                return False                     # hardware: SLVERR while a capture is armed/running
            self._cap_trig_mode = value & 1
            self._cap_words = words
            return True
        if address == REG_CAP_RD_CH:
            if value >= 8:
                return False
            self._cap_channel = value
            self._cap_pair_ptr = 0
            return True
        if address == REG_CAP_RD_PTR:
            self._cap_pair_ptr = value
            return True
        if address in (REG_CAP_RD_DATA, REG_TX_WR_PTR, REG_TX_CRC, REG_CAP_STATUS,
                       REG_CAP_SAMPLES, REG_CAP_TX_WORD, REG_ID, REG_STATUS, REG_DAC_FS_KSPS,
                       REG_ADC_FS_KSPS, REG_FAULTS, REG_ABI, REG_MAX_WORDS, REG_BUILD_ID):
            return False
        if REG_BASE <= address <= REG_BASE + 0x54 and address % 4 == 0:
            return False
        self._regs[address] = value
        return True

    def _command(self, value: int) -> bool:
        self._command_result = 0
        if value == 1:
            self._running = False
            return True
        if value == 4:
            self._faults = 0
            return True
        if value == 2:
            if not self._ps_ready or self._running or not self._tx_mask or self._faults:
                self._command_result = 1
                return False
            required_pairs = self._tx_length * 16
            if any(self._tx_mask & (1 << ch) and len(self._tx_words[ch]) < required_pairs for ch in range(8)):
                self._command_result = 1
                return False
            self._running = True
            if self._cap_armed and self._cap_trig_mode:
                self._complete_capture()
            return True
        if value == 8:
            if self._cap_busy or not 1 <= self._cap_words <= CAP_MAX_WORDS:
                self._command_result = 1
                return False
            self._cap_armed = True
            self._cap_done = False
            if self._cap_trig_mode == 0:
                self._complete_capture()
            return True
        if value == 32:
            # Abort capture: back to idle, done cleared; accepted when idle too.
            self._cap_armed = False
            self._cap_busy = False
            self._cap_done = False
            return True
        if value == 16:
            words = self._tx_words[self._tx_channel]
            needed = self._tx_length * 16
            if len(words) < needed:
                self._command_result = 1
                return False
            payload = b"".join(struct.pack("<I", word & 0xFFFCFFFC) for word in words[:needed])
            self._crc_busy = True
            self._tx_crc = binascii.crc32(payload) & 0xFFFFFFFF
            self._crc_busy = False
            return True
        self._command_result = 1
        return False

    @staticmethod
    def _decode_pair(pair: int) -> tuple[int, int]:
        result = []
        for shift in (0, 16):
            value = (pair >> shift) & 0xFFFF
            if value & 0x8000:
                value -= 0x10000
            result.append(value)
        return result[0], result[1]

    def _complete_capture(self) -> None:
        self._cap_busy = True
        self._cap_armed = False
        self._cap_samples = self._cap_words * 24
        self._cap_tx_word = 0
        pair_count = self._cap_samples // 2
        for channel in range(8):
            samples: list[int] = []
            tx_samples: list[int] = []
            if self.loopback and self._tx_words[channel]:
                for pair in self._tx_words[channel]:
                    tx_samples.extend(self._decode_pair(pair))
            for index in range(self._cap_samples):
                if self.loopback and tx_samples:
                    source = (index - self.loopback_delay_samples) % len(tx_samples)
                    value = tx_samples[source] & 0xFFFC
                else:
                    raw = (index * 17 + channel * 101) & 0x3FFF
                    signed = raw - 0x4000 if raw & 0x2000 else raw
                    value = signed << 2
                samples.append(value)
            packed = []
            for offset in range(0, self._cap_samples, 2):
                packed.append((samples[offset] & 0xFFFF) | ((samples[offset + 1] & 0xFFFF) << 16))
            self._capture[channel] = packed[:pair_count]
        self._cap_busy = False
        self._cap_done = True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9100)
    parser.add_argument("--drop-rate", type=float, default=0.0)
    parser.add_argument("--duplicate-rate", type=float, default=0.0)
    parser.add_argument("--seed", type=int, default=47)
    parser.add_argument("--loopback", action="store_true")
    parser.add_argument("--loopback-delay-samples", type=int, default=0)
    args = parser.parse_args()

    def report(message: str) -> None:
        print(message, flush=True)

    emulator = FpgaEmulator(
        args.host, args.port, drop_rate=args.drop_rate, duplicate_rate=args.duplicate_rate,
        seed=args.seed, loopback=args.loopback,
        loopback_delay_samples=args.loopback_delay_samples, event_callback=report,
    ).start()
    try:
        emulator.stopped.wait()
    except KeyboardInterrupt:
        pass
    finally:
        emulator.close()


if __name__ == "__main__":
    main()
