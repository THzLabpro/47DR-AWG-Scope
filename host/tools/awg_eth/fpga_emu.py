"""Loopback-only FPGA protocol and v2 register emulator."""

from __future__ import annotations

import argparse
import binascii
import random
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from typing import Callable

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from awg_eth import protocol
    from awg_eth import bulk
    from awg_eth.awg import (
        ABI, ABI_V2, ABI_V21, REG_TX_MODE, CAP_BANK_WORDS, CAP_MAX_WORDS, REG_ABI, REG_ADC_FS_KSPS, REG_BASE, REG_BUILD_ID,
        REG_CAP_CTRL, REG_CAP_RD_CH, REG_CAP_RD_DATA, REG_CAP_RD_PTR, REG_CAP_SAMPLES,
        REG_CAP_BANK_WORDS, REG_CAP_LEN, REG_CAP_MODE, REG_CAP_STATUS, REG_CAP_TX_WORD,
        REG_COMMAND, REG_DAC_FS_KSPS, REG_FAULTS,
        REG_ID, REG_MAX_WORDS, REG_STATUS, REG_TX_CRC, REG_TX_LENGTH, REG_TX_MASK,
        REG_TX_WR_CH, REG_TX_WR_DATA, REG_TX_WR_PTR, TX_MAX_WORDS,
    )
else:
    from . import protocol
    from . import bulk
    from .awg import (
    ABI, ABI_V2, ABI_V21, REG_TX_MODE, CAP_BANK_WORDS, CAP_MAX_WORDS, REG_ABI, REG_ADC_FS_KSPS, REG_BASE, REG_BUILD_ID,
    REG_CAP_CTRL, REG_CAP_RD_CH, REG_CAP_RD_DATA, REG_CAP_RD_PTR, REG_CAP_SAMPLES,
    REG_CAP_BANK_WORDS, REG_CAP_LEN, REG_CAP_MODE, REG_CAP_STATUS, REG_CAP_TX_WORD,
    REG_COMMAND, REG_DAC_FS_KSPS, REG_FAULTS,
    REG_ID, REG_MAX_WORDS, REG_STATUS, REG_TX_CRC, REG_TX_LENGTH, REG_TX_MASK,
    REG_TX_WR_CH, REG_TX_WR_DATA, REG_TX_WR_PTR, TX_MAX_WORDS,
    )

_HEADER = struct.Struct("<HBBIIHHHHI")


class FpgaEmulator:
    def __init__(self, host: str = "127.0.0.1", port: int = 0, *, abi: int = 2,
                 bank_words: int = 10240, drop_rate: float = 0.0,
                 duplicate_rate: float = 0.0, seed: int = 47, build_id: int = 1,
                 loopback: bool = False, loopback_delay_samples: int = 0,
                 reorder_rate: float = 0.0,
                 event_callback: Callable[[str], None] | None = None):
        if abi not in (1, 2, 3) or bank_words < 1:
            raise ValueError("abi must be 1, 2 or 3 and bank_words must be positive")
        if not 0 <= drop_rate < 1 or not 0 <= duplicate_rate < 1 or not 0 <= reorder_rate < 1:
            raise ValueError("drop_rate/duplicate_rate/reorder_rate must be in [0,1)")
        self.host = host
        self.port = port
        # abi 3 = V2.1 (TX pooling, STATUS[9]); it keeps every V2 behaviour, so abi_mode stays 2.
        self.v21 = abi == 3
        self.abi_mode = 2 if abi == 3 else abi
        self.bank_words = bank_words
        self.drop_rate = drop_rate
        self.duplicate_rate = duplicate_rate
        self.reorder_rate = reorder_rate
        self.random = random.Random(seed)
        self.build_id = build_id
        self.loopback = loopback
        self.loopback_delay_samples = loopback_delay_samples
        self.event_callback = event_callback
        self.ready = threading.Event()
        self.stopped = threading.Event()
        self._thread: threading.Thread | None = None
        self._socket: socket.socket | None = None
        self._bulk_socket: socket.socket | None = None
        self._bulk_thread: threading.Thread | None = None
        self.bulk_port = 0
        self._lock = threading.RLock()
        self._tx_channel = 0
        self._tx_words: dict[int, list[int]] = {channel: [] for channel in range(8)}
        self._cap_channel = 0
        self._cap_pair_ptr = 0
        self._capture: dict[int, list[int]] = {channel: [] for channel in range(8)}
        self._capture_slots: dict[int, list[int]] = {slot: [] for slot in range(8)}
        self._cap_mode = 0xFAC68803
        self._cap_len = CAP_MAX_WORDS if abi == 1 else bank_words
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
        self._tx_mode = 0xFAC68803
        self._start_rejected = False
        self._started = False
        self._tx_crc = 0
        self._regs: dict[int, int] = {}
        self._last_write_seq: int | None = None
        self._last_write_reply: bytes | None = None
        self._bulk_seen: dict[int, set[int]] = {channel: set() for channel in range(8)}
        self._bulk_tx_written = [0] * 8
        self._bulk_reorder_hold: tuple[bytes, tuple[str, int]] | None = None
        self.bulk_counters = {
            "rx_ok": 0, "rx_bad_req": 0, "rx_busy": 0, "rx_dropped": 0,
            "txw_packets": 0, "txw_words": 0, "rxr_packets": 0, "rxr_words": 0,
            "tx_replies": 0,
        }
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
        self._configure_socket(self._socket)
        self._socket.bind((self.host, self.port))
        self.port = self._socket.getsockname()[1]
        if self.abi_mode == 2:
            self._bulk_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._configure_socket(self._bulk_socket)
            try:
                self._bulk_socket.bind((self.host, 9101 if self.port == 9100 else self.port + 1))
            except OSError:
                self._bulk_socket.bind((self.host, 0))
            self.bulk_port = self._bulk_socket.getsockname()[1]
        self.stopped.clear()
        self._thread = threading.Thread(target=self.serve_forever, name="fpga-emu", daemon=True)
        self._thread.start()
        if self._bulk_socket is not None:
            self._bulk_thread = threading.Thread(target=self.serve_bulk_forever, name="fpga-emu-bulk", daemon=True)
            self._bulk_thread.start()
        if not self.ready.wait(2.0):
            self.close()
            raise TimeoutError("emulator did not become ready")
        return self

    @staticmethod
    def _configure_socket(sock: socket.socket) -> None:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 * 1024 * 1024)
        connreset = getattr(socket, "SIO_UDP_CONNRESET", None)
        if connreset is not None and hasattr(sock, "ioctl"):
            try:
                sock.ioctl(connreset, False)
            except OSError:
                pass

    def close(self) -> None:
        self.stopped.set()
        if self._socket:
            try:
                self._socket.close()
            except OSError:
                pass
        if self._bulk_socket:
            try:
                self._bulk_socket.close()
            except OSError:
                pass
        if self._thread and self._thread is not threading.current_thread():
            self._thread.join(2.0)
        if self._bulk_thread and self._bulk_thread is not threading.current_thread():
            self._bulk_thread.join(2.0)
        self._socket = None
        self._bulk_socket = None

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
                continue
            except OSError:
                break
            self._handle_datagram(data, peer)

    def serve_bulk_forever(self) -> None:
        assert self._bulk_socket is not None
        while not self.stopped.is_set():
            try:
                data, peer = self._bulk_socket.recvfrom(65535)
            except ConnectionResetError:
                continue
            except OSError:
                break
            self._handle_bulk_datagram(data, peer)

    def _bulk_response(self, request: bulk.BulkPacket, *, status: int = 0,
                       count: int = 0, data: tuple[int, ...] = ()) -> bytes:
        return bulk.encode_packet(bulk.BulkPacket(
            request.opcode | 0x80, request.seq, request.addr, count, request.flags,
            status, 0, data,
        ), request=False)

    def _bulk_send_raw(self, reply: bytes, peer: tuple[str, int]) -> None:
        assert self._bulk_socket is not None
        try:
            self._bulk_socket.sendto(reply, peer)
        except (ConnectionResetError, OSError):
            if not self.stopped.is_set():
                return

    def _bulk_send(self, reply: bytes, peer: tuple[str, int]) -> None:
        if self.random.random() < self.drop_rate:
            self.bulk_counters["rx_dropped"] += 1
            return
        if self.reorder_rate and self.random.random() < self.reorder_rate:
            held = self._bulk_reorder_hold
            if held is None:
                self._bulk_reorder_hold = (reply, peer)
                return
            self._bulk_reorder_hold = None
            self._bulk_send_raw(reply, peer)
            self._bulk_send_raw(*held)
        else:
            self._bulk_send_raw(reply, peer)
        if self.random.random() < self.duplicate_rate:
            self._bulk_send_raw(reply, peer)

    def _bulk_bad_request(self, raw: bytes) -> bytes | None:
        if len(raw) < protocol.HEADER_SIZE:
            self.bulk_counters["rx_dropped"] += 1
            return None
        magic, version, opcode, seq, addr, count, flags, _status, _err, _reserved = _HEADER.unpack_from(raw)
        if magic != protocol.MAGIC or version != protocol.VERSION:
            self.bulk_counters["rx_dropped"] += 1
            return None
        self.bulk_counters["rx_bad_req"] += 1
        return bulk.encode_packet(bulk.BulkPacket(
            opcode | 0x80, seq, addr, 0, flags & bulk.FLAG_ACK, bulk.STATUS_BAD_REQ, 0, (),
        ), request=False)

    def _bulk_slot_count(self) -> int:
        return 1 << (self._cap_mode & 3)

    def _bulk_slot_words(self) -> int:
        return (8 // self._bulk_slot_count()) * self.bank_words

    def _tx_slots(self) -> int:
        return 1 << (self._tx_mode & 3) if self.v21 else 8

    def _tx_slot_pairs(self) -> int:
        """Per-slot TX capacity in sample pairs (V2.1: 8/N banks of 65536 pairs)."""
        return (8 // self._tx_slots()) * TX_MAX_WORDS * 16

    def _dac_slot(self, dac_channel: int) -> int | None:
        """Slot feeding a DAC channel (lowest slot wins), None if silent."""
        if not self.v21:
            return dac_channel
        for slot in range(self._tx_slots()):
            if ((self._tx_mode >> (8 + 3 * slot)) & 7) == dac_channel:
                return slot
        return None

    def _handle_bulk_datagram(self, raw: bytes, peer: tuple[str, int]) -> None:
        self._handle_bulk_once(raw, peer)
        if self.random.random() < self.duplicate_rate:
            self._handle_bulk_once(raw, peer)

    def _handle_bulk_once(self, raw: bytes, peer: tuple[str, int]) -> None:
        try:
            request = bulk.decode_packet(raw, response=False)
        except ValueError:
            reply = self._bulk_bad_request(raw)
            if reply is not None:
                self.bulk_counters["tx_replies"] += 1
                self._bulk_send(reply, peer)
            return
        if self.abi_mode != 2:
            return
        base = request.opcode
        channel_or_slot = (request.addr >> 28) & 0x7
        offset = request.addr & 0x0FFFFFFF
        invalid_top = bool(request.addr & 0x80000000)
        status = bulk.STATUS_OK
        response: bytes | None = None
        with self._lock:
            if base == bulk.OP_TXW:
                valid = (
                    not invalid_top and request.flags in (0, bulk.FLAG_ACK)
                    and 0 <= channel_or_slot < 8 and offset % 16 == 0
                    and 16 <= request.count <= 2048 and request.count % 16 == 0
                    and offset + request.count <= (524288 if self.v21 else 65536)
                    and len(request.data) == request.count
                )
                if not valid:
                    status = bulk.STATUS_BAD_REQ
                elif self._running:
                    status = bulk.STATUS_BUSY
                else:
                    words = self._tx_words[channel_or_slot]
                    needed = offset + request.count
                    # awg_tx drops lines outside the slot region (or slots >= N) but the packet still counts.
                    if channel_or_slot < self._tx_slots() and needed <= self._tx_slot_pairs():
                        if len(words) < needed:
                            words.extend([0] * (needed - len(words)))
                        words[offset:needed] = [int(value) & 0xFFFCFFFC for value in request.data]
                        self._bulk_tx_written[channel_or_slot] = max(self._bulk_tx_written[channel_or_slot], needed)
                    self.bulk_counters["rx_ok"] += 1
                    self.bulk_counters["txw_packets"] += 1
                    self.bulk_counters["txw_words"] = min(self.bulk_counters["txw_words"] + request.count, 0xFFFFFFFF)
                    if request.flags & bulk.FLAG_ACK:
                        # Same as awg_bulk.sv: the global saturating TXW word counter (STAT[9]), incl. this packet.
                        response = self._bulk_response(
                            request, count=1, data=(self.bulk_counters["txw_words"],)
                        )
            elif base == bulk.OP_RXR:
                valid = (
                    not invalid_top and request.flags == 0 and 0 <= channel_or_slot < 8
                    and offset % 12 == 0 and 12 <= request.count <= 2040
                    and request.count % 12 == 0
                    and channel_or_slot < self._bulk_slot_count()
                    and offset + request.count <= self._bulk_slot_words() * 12
                )
                if not valid:
                    status = bulk.STATUS_BAD_REQ
                elif self._cap_busy or self._cap_armed:
                    status = bulk.STATUS_BUSY
                else:
                    data = tuple(self._capture_slots[channel_or_slot][offset:offset + request.count])
                    if len(data) != request.count:
                        status = bulk.STATUS_BAD_REQ
                    else:
                        self.bulk_counters["rx_ok"] += 1
                        self.bulk_counters["rxr_packets"] += 1
                        self.bulk_counters["rxr_words"] += request.count
                        response = self._bulk_response(request, count=request.count, data=data)
            elif base == bulk.OP_STAT:
                if invalid_top or request.addr or request.count or request.flags:
                    status = bulk.STATUS_BAD_REQ
                else:
                    s = self.bulk_counters
                    values = (
                        0x424C4B31, 1, 2048, self.build_id,
                        s["rx_ok"], s["rx_bad_req"], s["rx_busy"], s["rx_dropped"],
                        s["txw_packets"], s["txw_words"], s["rxr_packets"], s["rxr_words"],
                        s["tx_replies"], 0, 0, 0,
                    )
                    self.bulk_counters["rx_ok"] += 1
                    response = self._bulk_response(request, count=16, data=values)
            else:
                status = bulk.STATUS_BAD_REQ
            if status == bulk.STATUS_BUSY:
                self.bulk_counters["rx_busy"] += 1
            elif status == bulk.STATUS_BAD_REQ:
                self.bulk_counters["rx_bad_req"] += 1
            if response is None and status != bulk.STATUS_OK:
                response = self._bulk_response(request, status=status)
            if response is not None:
                self.bulk_counters["tx_replies"] += 1
        if response is not None:
            self._bulk_send(response, peer)

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
        except (ConnectionResetError, OSError):
            if self.stopped.is_set():
                return

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
            | (int(self._start_rejected) << 9)
            | (int(self._started) << 10)
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
            REG_ABI: ABI_V21 if self.v21 else (ABI_V2 if self.abi_mode == 2 else ABI),
            REG_MAX_WORDS: ((self.bank_words if self.abi_mode == 2 else CAP_MAX_WORDS) << 16) | TX_MAX_WORDS,
            REG_CAP_STATUS: self._cap_status(),
            REG_CAP_SAMPLES: self._cap_samples,
            REG_TX_WR_PTR: len(self._tx_words[self._tx_channel]) * 2,
            REG_TX_CRC: self._tx_crc,
            REG_CAP_TX_WORD: self._cap_tx_word,
            REG_BUILD_ID: self.build_id,
            REG_TX_LENGTH: self._tx_length,
            REG_TX_MASK: self._tx_mask,
        }
        if self.v21:
            fixed[REG_TX_MODE] = self._tx_mode
        if self.abi_mode == 2:
            fixed.update({
                REG_CAP_LEN: self._cap_len,
                REG_CAP_MODE: self._cap_mode,
                REG_CAP_BANK_WORDS: self.bank_words,
            })
        if address in fixed:
            return True, fixed[address] & 0xFFFFFFFF
        if address == REG_CAP_RD_PTR:
            return True, self._cap_pair_ptr
        if address == REG_CAP_RD_DATA:
            limit = self._bulk_slot_words() * 12 if self.abi_mode == 2 else CAP_MAX_WORDS * 12
            if self._cap_pair_ptr >= limit:
                return False, 0                   # D3C hardware: pointer past the buffer -> SLVERR
            pairs = self._capture_slots[self._cap_channel] if self.abi_mode == 2 else self._capture[self._cap_channel]
            value = pairs[self._cap_pair_ptr] if self._cap_pair_ptr < len(pairs) else 0
            self._cap_pair_ptr += 1
            return True, value
        if address in (REG_CAP_LEN, REG_CAP_MODE, REG_CAP_BANK_WORDS) and self.abi_mode != 2:
            return False, 0
        if address in self._regs:
            return True, self._regs[address]
        return False, 0

    def _write_register(self, address: int, value: int) -> bool:
        value &= 0xFFFFFFFF
        if address in (REG_TX_LENGTH, REG_TX_MASK, REG_TX_WR_CH, REG_TX_WR_DATA, REG_TX_MODE) and self._running:
            return False
        if address == REG_TX_MODE and self.v21:
            if value & 0xFC:
                return False
            if (value & 3) != (self._tx_mode & 3):          # pooling change voids every slot (awg_tx)
                self._tx_words = {channel: [] for channel in range(8)}
                self._bulk_tx_written = [0] * 8
            self._tx_mode = value
            return True
        if address == REG_COMMAND:
            return self._command(value)
        if address == REG_TX_LENGTH:
            if not 1 <= value <= self._tx_slot_pairs() // 16 or self._running:
                return False
            self._tx_length = value
            return True
        if address == REG_TX_MASK:
            if self._running:
                return False
            self._tx_mask = value & 0xFF
            return True
        if address == REG_TX_WR_CH:
            if value >= self._tx_slots() or self._running:
                return False
            self._tx_channel = value
            if self.abi_mode == 1:
                self._tx_words[value] = []
            else:
                self._bulk_tx_written[value] = 0
            return True
        if address == REG_TX_WR_DATA:
            words = self._tx_words[self._tx_channel]
            if len(words) >= self._tx_slot_pairs():
                return False
            words.append(value & 0xFFFCFFFC)
            return True
        if address == REG_CAP_CTRL:
            # Same as awg_control_v2.sv: [27:16] (12 bits) also writes CAP_LEN; 0 and reserved bits -> SLVERR.
            words = (value >> 16) & 0xFFF
            limit = self._bulk_slot_words() if self.abi_mode == 2 else CAP_MAX_WORDS
            if self._cap_busy or self._cap_armed or (value & 0xF000FFFE) or not 1 <= words <= limit:
                return False                     # hardware: SLVERR while a capture is armed/running
            self._cap_trig_mode = value & 1
            self._cap_words = words
            self._cap_len = words
            return True
        if address == REG_CAP_LEN and self.abi_mode == 2:
            if self._cap_busy or self._cap_armed or not 1 <= value <= self._bulk_slot_words():
                return False
            self._cap_len = value
            self._cap_words = value
            return True
        if address == REG_CAP_MODE and self.abi_mode == 2:
            if self._cap_busy or self._cap_armed or (value & 0xFC):
                return False
            slots_count = 1 << (value & 3)
            if slots_count not in (1, 2, 4, 8):
                return False
            for slot in range(slots_count):
                if ((value >> (8 + slot * 3)) & 7) >= 8:
                    return False
            self._cap_mode = value
            if self._cap_len > self._bulk_slot_words():
                self._cap_len = self._bulk_slot_words()
            self._cap_words = self._cap_len
            return True
        if address == REG_CAP_RD_CH:
            if value >= (self._bulk_slot_count() if self.abi_mode == 2 else 8):
                return False
            self._cap_channel = value
            self._cap_pair_ptr = 0
            return True
        if address == REG_CAP_RD_PTR:
            self._cap_pair_ptr = value
            return True
        if address in (REG_CAP_RD_DATA, REG_TX_WR_PTR, REG_TX_CRC, REG_CAP_STATUS,
                       REG_CAP_SAMPLES, REG_CAP_TX_WORD, REG_ID, REG_STATUS, REG_DAC_FS_KSPS,
                       REG_ADC_FS_KSPS, REG_FAULTS, REG_ABI, REG_MAX_WORDS, REG_BUILD_ID,
                       REG_CAP_LEN, REG_CAP_MODE, REG_CAP_BANK_WORDS):
            return False
        if REG_BASE <= address <= REG_BASE + 0x64 and address % 4 == 0:
            return False
        self._regs[address] = value
        return True

    def _command(self, value: int) -> bool:
        self._command_result = 0
        if value == 1:
            self._running = False
            self._started = False
            return True
        if value == 4:
            self._faults = 0
            return True
        if value == 2:
            if not self._ps_ready or self._running or not self._tx_mask or self._faults:
                self._command_result = 1
                return False
            required_pairs = self._tx_length * 16
            if self.v21:
                # V2.1: awg_control accepts; awg_tx refuses short data and reports STATUS[9].
                slot_mask = self._tx_mask & ((1 << self._tx_slots()) - 1)
                if (not slot_mask or self._tx_length > self._tx_slot_pairs() // 16 or
                        any(slot_mask & (1 << s) and len(self._tx_words[s]) < required_pairs for s in range(8))):
                    self._start_rejected = True
                    self._started = False
                    return True
                self._start_rejected = False
                self._started = True
            elif any(self._tx_mask & (1 << ch) and len(self._tx_words[ch]) < required_pairs for ch in range(8)):
                self._command_result = 1
                return False
            self._running = True
            if self._cap_armed and self._cap_trig_mode:
                self._complete_capture()
            return True
        if value == 8:
            limit = self._bulk_slot_words() if self.abi_mode == 2 else CAP_MAX_WORDS
            if self._cap_busy or not 1 <= self._cap_words <= limit:
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
        if self.abi_mode == 2:
            slots_count = self._bulk_slot_count()
            for slot in range(8):
                self._capture_slots[slot] = []
            for slot in range(slots_count):
                channel = (self._cap_mode >> (8 + 3 * slot)) & 7
                self._capture_slots[slot] = self._generate_capture(channel, self._cap_samples, pair_count)
            self._cap_busy = False
            self._cap_done = True
            return
        for channel in range(8):
            self._capture[channel] = self._generate_capture(channel, self._cap_samples, pair_count)
        self._cap_busy = False
        self._cap_done = True

    def _generate_capture(self, channel: int, sample_count: int, pair_count: int) -> list[int]:
        samples: list[int] = []
        tx_samples: list[int] = []
        slot = self._dac_slot(channel)
        if self.loopback and slot is not None and self._tx_words[slot]:
            pairs = self._tx_words[slot][:self._tx_length * 16] if self.v21 else self._tx_words[slot]
            for pair in pairs:
                tx_samples.extend(self._decode_pair(pair))
        for index in range(sample_count):
            if self.loopback and tx_samples:
                source = (index - self.loopback_delay_samples) % len(tx_samples)
                value = tx_samples[source] & 0xFFFC
            else:
                raw = (index * 17 + channel * 101) & 0x3FFF
                signed = raw - 0x4000 if raw & 0x2000 else raw
                value = signed << 2
            samples.append(value)
        packed = []
        for offset in range(0, sample_count, 2):
            packed.append((samples[offset] & 0xFFFF) | ((samples[offset + 1] & 0xFFFF) << 16))
        return packed[:pair_count]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9100)
    parser.add_argument("--abi", type=int, choices=(1, 2, 3), default=3)
    parser.add_argument("--bank-words", type=int, default=CAP_BANK_WORDS)
    parser.add_argument("--drop-rate", type=float, default=0.0)
    parser.add_argument("--duplicate-rate", type=float, default=0.0)
    parser.add_argument("--reorder-rate", type=float, default=0.0)
    parser.add_argument("--seed", type=int, default=47)
    parser.add_argument("--loopback", action="store_true")
    parser.add_argument("--loopback-delay-samples", type=int, default=0)
    args = parser.parse_args()

    def report(message: str) -> None:
        print(message, flush=True)

    emulator = FpgaEmulator(
        args.host, args.port, abi=args.abi, bank_words=args.bank_words,
        drop_rate=args.drop_rate, duplicate_rate=args.duplicate_rate, reorder_rate=args.reorder_rate,
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
