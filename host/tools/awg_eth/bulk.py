"""V2 UDP 9101 bulk client and wire codec.

The bulk protocol deliberately lives beside the frozen 9100 codec: it keeps the
same 24-byte little-endian header but has its own opcodes and ACK flag.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import os
from pathlib import Path
import select
import socket
import struct
import sys
import time
from typing import Callable

import numpy as np

from .client import _PinnedThread
from . import protocol

OP_TXW = 0x10
OP_RXR = 0x11
OP_STAT = 0x12
FLAG_ACK = 1 << 1

STATUS_OK = protocol.STATUS_OK
STATUS_BAD_REQ = protocol.STATUS_BAD_REQ
STATUS_BUSY = protocol.STATUS_BUSY

_HEADER = struct.Struct("<HBBIIHHHHI")


class _NativeCtx(ctypes.Structure):
    """Mirror of awg_ctx in native/awg_bulk.c."""
    _fields_ = [("sock", ctypes.c_uint64), ("peer_ip", ctypes.c_uint32), ("peer_port", ctypes.c_uint32),
                ("timeout_s", ctypes.c_double), ("retries", ctypes.c_int32), ("seq", ctypes.c_uint32),
                ("resent", ctypes.c_int64), ("packets", ctypes.c_int64), ("error_status", ctypes.c_int32),
                ("error_seq", ctypes.c_uint32), ("error_offset", ctypes.c_int64), ("wsa_error", ctypes.c_int32),
                ("seconds", ctypes.c_double)]


class NativeSeqResult(ctypes.Structure):
    """Mirror of awg_seq_result (awg_capture / awg_load)."""
    _fields_ = [("failed_step", ctypes.c_int32), ("detail", ctypes.c_uint32), ("command", ctypes.c_uint32),
                ("status_word", ctypes.c_uint32), ("captured", ctypes.c_uint32), ("cap_tx_word", ctypes.c_uint32),
                ("reg_ops", ctypes.c_int64), ("crc_retries", ctypes.c_int64), ("t_control", ctypes.c_double),
                ("t_data", ctypes.c_double), ("crc_actual", ctypes.c_uint32 * 8)]


class NativeCapArgs(ctypes.Structure):
    """Mirror of awg_cap_args."""
    _fields_ = [("base", ctypes.c_uint32), ("trigger_start", ctypes.c_int32),
                ("check_start_rejected", ctypes.c_int32), ("write_mode_len", ctypes.c_int32),
                ("cap_mode", ctypes.c_uint32), ("cap_ctrl", ctypes.c_uint32), ("cap_len", ctypes.c_uint32),
                ("limit", ctypes.c_uint32), ("n_read", ctypes.c_int32), ("read_slot", ctypes.c_int32 * 8),
                ("window", ctypes.c_int32), ("cmd_timeout_s", ctypes.c_double), ("cap_timeout_s", ctypes.c_double)]


class NativeLoadArgs(ctypes.Structure):
    """Mirror of awg_load_args."""
    _fields_ = [("base", ctypes.c_uint32), ("pooled", ctypes.c_int32), ("tx_mode", ctypes.c_uint32),
                ("length_beats", ctypes.c_uint32), ("final_mask", ctypes.c_uint32), ("n_slots", ctypes.c_int32),
                ("slot", ctypes.c_int32 * 8), ("crc_expected", ctypes.c_uint32 * 8), ("nwords", ctypes.c_int64),
                ("verify", ctypes.c_int32), ("words_per_packet", ctypes.c_int32), ("batch_packets", ctypes.c_int32),
                ("batches_in_flight", ctypes.c_int32), ("cmd_timeout_s", ctypes.c_double)]


_NATIVE_CB = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int64, ctypes.c_int64)
_NATIVE_CB3 = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int32, ctypes.c_int64, ctypes.c_int64)
_RC_OK, _RC_TIMEOUT, _RC_STATUS, _RC_CANCELLED, _RC_SHORT, _RC_ARGS, _RC_SOCKET = 0, 1, 2, 3, 4, 5, -1
RC_CMD = 6
SEQ_BUSY, SEQ_NOT_READY, SEQ_REJECTED, SEQ_CMD_TIMEOUT, SEQ_START_REJECTED, SEQ_CAP_TIMEOUT, SEQ_BAD_COUNT, \
    SEQ_CRC = range(1, 9)
_NATIVE_MAX_WINDOW = 256


def _load_native():
    """Load native/awg_bulk.dll (V2-C transfer loops). AWG_BULK_NATIVE=0 forces the Python path."""
    if sys.platform != "win32" or os.environ.get("AWG_BULK_NATIVE", "1") == "0":
        return None
    path = Path(__file__).resolve().with_name("native") / "awg_bulk.dll"
    try:
        lib = ctypes.CDLL(str(path))
        abi = lib.awg_bulk_abi()
    except (OSError, AttributeError):
        return None
    if abi < 1:
        return None
    lib.has_sequences = abi >= 2
    ctx_p = ctypes.POINTER(_NativeCtx)
    u32_p = ctypes.POINTER(ctypes.c_uint32)
    lib.awg_txw.argtypes = [ctx_p, ctypes.c_int32, u32_p, ctypes.c_int64, ctypes.c_int32, ctypes.c_int32,
                            ctypes.c_int32, _NATIVE_CB]
    lib.awg_rxr.argtypes = [ctx_p, ctypes.c_int32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32, u32_p,
                            _NATIVE_CB]
    lib.awg_stat.argtypes = [ctx_p, u32_p]
    for fn in (lib.awg_txw, lib.awg_rxr, lib.awg_stat):
        fn.restype = ctypes.c_int
    if lib.has_sequences:
        res_p = ctypes.POINTER(NativeSeqResult)
        lib.awg_capture.argtypes = [ctx_p, ctx_p, ctypes.POINTER(NativeCapArgs), ctypes.POINTER(u32_p),
                                    _NATIVE_CB3, res_p]
        lib.awg_load.argtypes = [ctx_p, ctx_p, ctypes.POINTER(NativeLoadArgs), ctypes.POINTER(u32_p),
                                 _NATIVE_CB3, res_p]
        lib.awg_capture.restype = lib.awg_load.restype = ctypes.c_int
    return lib


_NATIVE = _load_native()


class BulkError(RuntimeError):
    """A valid bulk reply reported a protocol or transport failure."""

    def __init__(self, message: str, *, status: int | None = None, seq: int | None = None):
        super().__init__(message)
        self.status = status
        self.seq = seq


class BulkBadRequest(BulkError):
    """The FPGA rejected a bulk request as malformed or out of range."""


class BulkBusy(BulkError):
    """The FPGA data path is busy and cannot accept the request."""


@dataclass(frozen=True)
class BulkPacket:
    opcode: int
    seq: int
    addr: int
    count: int
    flags: int = 0
    status: int = STATUS_OK
    err_index: int = 0
    data: tuple[int, ...] = ()


def encode_packet(packet: BulkPacket, *, request: bool) -> bytes:
    """Encode a 9101 packet. Payload words are always little-endian uint32."""
    if not 0 <= packet.opcode <= 0xFF or not 0 <= packet.seq <= 0xFFFFFFFF:
        raise ValueError("bulk opcode/sequence out of range")
    if not 0 <= packet.addr <= 0xFFFFFFFF or not 0 <= packet.count <= 0xFFFF:
        raise ValueError("bulk address/count out of range")
    if packet.flags & ~FLAG_ACK:
        raise ValueError("bulk reserved flags must be zero")
    if request:
        if packet.opcode & 0x80 or packet.status or packet.err_index:
            raise ValueError("invalid bulk request header")
        if packet.opcode == OP_TXW and len(packet.data) != packet.count:
            raise ValueError("TXW payload length does not match count")
        if packet.opcode != OP_TXW and packet.data:
            raise ValueError("only TXW carries request data")
    else:
        if not packet.opcode & 0x80:
            raise ValueError("bulk response opcode must have bit 7 set")
        if packet.opcode & 0x7F in (OP_RXR, OP_STAT) and len(packet.data) != packet.count:
            raise ValueError("bulk response payload length does not match count")
        if packet.opcode & 0x7F == OP_TXW and packet.data and len(packet.data) != packet.count:
            raise ValueError("TXW response payload length does not match count")
    payload = np.asarray(packet.data, dtype="<u4").tobytes() if packet.data else b""
    return _HEADER.pack(protocol.MAGIC, protocol.VERSION, packet.opcode, packet.seq,
                        packet.addr, packet.count, packet.flags, packet.status,
                        packet.err_index, 0) + payload


def decode_packet(datagram: bytes, *, response: bool | None = None) -> BulkPacket:
    if len(datagram) < protocol.HEADER_SIZE:
        raise ValueError("bulk packet shorter than 24-byte header")
    magic, version, opcode, seq, addr, count, flags, status, err_index, reserved = _HEADER.unpack_from(datagram)
    if magic != protocol.MAGIC or version != protocol.VERSION or reserved != 0:
        raise ValueError("invalid bulk magic/version/reserved")
    if flags & ~FLAG_ACK:
        raise ValueError("bulk reserved flags must be zero")
    if response is True and not opcode & 0x80:
        raise ValueError("expected bulk response")
    if response is False and opcode & 0x80:
        raise ValueError("expected bulk request")
    body = datagram[protocol.HEADER_SIZE:]
    base = opcode & 0x7F
    if response is False:
        if status or err_index:
            raise ValueError("request status/err_index must be zero")
        if base == OP_TXW:
            if len(body) != count * 4:
                raise ValueError("TXW length mismatch")
        elif base == OP_RXR:
            if body:
                raise ValueError("RXR request must not carry data")
        elif body or count:
            raise ValueError("STAT request must not carry data")
    else:
        if len(body) % 4 or len(body) != count * 4:
            raise ValueError("bulk response length mismatch")
    words = tuple(np.frombuffer(body, dtype="<u4").tolist()) if body else ()
    return BulkPacket(opcode, seq, addr, count, flags, status, err_index, words)


class BulkClient:
    """UDP 9101 client with batch recovery and out-of-order RXR placement."""

    def __init__(self, fpga_ip: str, port: int = 9101, *, timeout: float = 0.05,
                 retries: int = 5, window: int = 8, local_ip: str | None = None,
                 native: bool | None = None):
        """native: None = use native/awg_bulk.dll when it loads, True = require it, False = Python only."""
        if timeout <= 0 or retries < 0 or window < 1:
            raise ValueError("invalid timeout/retries/window")
        if native and _NATIVE is None:
            raise RuntimeError("native bulk DLL (awg_eth/native/awg_bulk.dll) is not available")
        self._native = _NATIVE if native is not False else None
        self.fpga_ip = fpga_ip
        self.port = port
        self.timeout = timeout
        self.retries = retries
        self.window = window
        self._seq = 1
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 * 1024 * 1024)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32 * 1024 * 1024)
        self.socket.bind((local_ip or "0.0.0.0", 0))
        self.socket.setblocking(False)
        self._peer = (fpga_ip, port)
        self._peer_ip_raw = int.from_bytes(socket.inet_aton(socket.gethostbyname(fpga_ip)), "little")
        self._recv_buf = bytearray(65535)
        self._recv_view = memoryview(self._recv_buf)
        self.last_rxr_resent = 0

    @property
    def native(self) -> bool:
        """True when TXW/RXR run in native/awg_bulk.dll."""
        return self._native is not None

    @property
    def native_sequences(self) -> bool:
        """True when whole capture/download sequences (9100 registers + bulk) can run natively."""
        return self._native is not None and getattr(self._native, "has_sequences", False)

    @staticmethod
    def _control_ctx(control) -> _NativeCtx:
        """Native context for an AwgEthClient (9100) socket; the call restores its blocking mode."""
        ip = int.from_bytes(socket.inet_aton(socket.gethostbyname(control.fpga_ip)), "little")
        return _NativeCtx(sock=control.socket.fileno(), peer_ip=ip, peer_port=control.port,
                          timeout_s=control.timeout, retries=control.retries, seq=control._seq)

    @staticmethod
    def _native_callback3(cancel, on_progress):
        errors: list[BaseException] = []
        if cancel is None and on_progress is None:
            return _NATIVE_CB3(), errors

        def fn(index, done, total):
            try:
                if on_progress and done >= 0:            # done < 0: the sequence only checks for cancel
                    on_progress(int(index), int(done), int(total))
                return 1 if cancel and cancel() else 0
            except BaseException as exc:             # noqa: BLE001 - re-raised after the native call
                errors.append(exc)
                return 1
        return _NATIVE_CB3(fn), errors

    def run_sequence(self, kind: str, control, args, buffers: list[np.ndarray], *, cancel=None, on_progress=None):
        """Run awg_capture (kind="capture") or awg_load ("load") natively.

        Returns (rc, NativeSeqResult, control ctx, bulk ctx). Python callback exceptions are re-raised
        here; mapping rc/failed_step to exceptions is left to awg.Awg (it owns the register names)."""
        ctl = self._control_ctx(control)
        blk = self._native_ctx()
        result = NativeSeqResult()
        u32_p = ctypes.POINTER(ctypes.c_uint32)
        pointers = (u32_p * len(buffers))(*[b.ctypes.data_as(u32_p) for b in buffers])
        cb, errors = self._native_callback3(cancel, on_progress)
        fn = self._native.awg_capture if kind == "capture" else self._native.awg_load
        with _PinnedThread():
            rc = fn(ctl, blk, ctypes.byref(args), pointers, cb, ctypes.byref(result))
        control._seq = ctl.seq
        self._seq = blk.seq
        if errors:
            raise errors[0]
        return rc, result, ctl, blk

    def raise_data_error(self, rc: int, blk: _NativeCtx, opcode: int) -> None:
        """Raise the bulk (TXW/RXR) exception for a failed native data step."""
        self._native_result(rc, blk, opcode, [], expected=2040)

    def _native_ctx(self) -> _NativeCtx:
        return _NativeCtx(sock=self.socket.fileno(), peer_ip=self._peer_ip_raw, peer_port=self.port,
                          timeout_s=self.timeout, retries=self.retries, seq=self._seq)

    @staticmethod
    def _native_callback(cancel, on_progress):
        """(ctypes callback, list collecting a Python exception raised inside it)."""
        errors: list[BaseException] = []
        if cancel is None and on_progress is None:
            return _NATIVE_CB(), errors              # NULL callback

        def fn(done, total):
            try:
                if on_progress:
                    on_progress(int(done), int(total))
                return 1 if cancel and cancel() else 0
            except BaseException as exc:             # noqa: BLE001 - re-raised after the native call
                errors.append(exc)
                return 1
        return _NATIVE_CB(fn), errors

    def _native_result(self, rc: int, ctx: _NativeCtx, opcode: int, errors: list, expected: int = 0) -> None:
        self._seq = ctx.seq
        if errors:
            raise errors[0]
        name = "TXW" if opcode == OP_TXW else "RXR"
        if rc == _RC_OK:
            return
        if rc == _RC_TIMEOUT:
            where = "batch timeout at word" if opcode == OP_TXW else "timeout at pair offset"
            raise TimeoutError(f"bulk {name} {where} {ctx.error_offset}")
        if rc == _RC_STATUS:
            self._status_error(opcode, ctx.error_seq, ctx.error_status)
        if rc == _RC_CANCELLED:
            raise BulkError(f"bulk {name} cancelled")
        if rc == _RC_SHORT:
            raise BulkError(f"short {name} response: expected {expected}, got {ctx.error_offset}")
        if rc == _RC_ARGS:
            raise ValueError(f"native bulk {name} rejected its arguments")
        raise OSError(ctx.wsa_error, f"native bulk {name} socket error (WSA {ctx.wsa_error})")

    def close(self) -> None:
        self.socket.close()

    def __enter__(self) -> "BulkClient":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def _next_seq(self) -> int:
        self._seq = (self._seq + 1) & 0xFFFFFFFF
        return self._seq

    def _send(self, packet) -> None:
        while True:
            try:
                self.socket.sendto(packet, self._peer)
                return
            except BlockingIOError:                  # send buffer full: wait until writable
                select.select([], [self.socket], [], self.timeout)

    def _recv_raw(self, deadline: float) -> int:
        """Receive one datagram from the FPGA into self._recv_buf; returns its length, 0 on timeout."""
        while True:
            try:
                n, peer = self.socket.recvfrom_into(self._recv_buf)
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return 0
                readable, _, _ = select.select([self.socket], [], [], remaining)
                if not readable:
                    return 0
                continue
            except ConnectionResetError:              # Windows: ICMP port unreachable from an old send
                continue
            if peer[0] == self._peer[0] and peer[1] == self._peer[1] and n >= protocol.HEADER_SIZE:
                return n

    def _recv(self, deadline: float) -> BulkPacket | None:
        n = self._recv_raw(deadline)
        if not n:
            return None
        try:
            return decode_packet(bytes(self._recv_buf[:n]), response=True)
        except ValueError:
            return None

    def _reply_header(self, n: int):
        """Parse a reply header in place (no payload copy). None if it is not a valid bulk reply."""
        magic, version, opcode, seq, addr, count, flags, status, err_index, reserved = \
            _HEADER.unpack_from(self._recv_buf)
        if (magic != protocol.MAGIC or version != protocol.VERSION or reserved != 0 or not opcode & 0x80
                or n != protocol.HEADER_SIZE + 4 * count):
            return None
        return opcode, seq, count, status

    @staticmethod
    def _raise_status(reply: BulkPacket) -> None:
        if reply.status == STATUS_BAD_REQ:
            raise BulkBadRequest(f"bulk BAD_REQ (seq={reply.seq})", status=reply.status, seq=reply.seq)
        if reply.status == STATUS_BUSY:
            raise BulkBusy(f"bulk BUSY (seq={reply.seq})", status=reply.status, seq=reply.seq)
        if reply.status != STATUS_OK:
            raise BulkError(f"bulk status={reply.status} (seq={reply.seq})", status=reply.status, seq=reply.seq)

    def _one(self, opcode: int, addr: int, count: int, *, flags: int = 0,
             data: np.ndarray | None = None) -> BulkPacket:
        seq = self._next_seq()
        values = tuple(np.asarray(data, dtype="<u4").tolist()) if data is not None else ()
        packet = encode_packet(BulkPacket(opcode, seq, addr, count, flags, data=values), request=True)
        for attempt in range(self.retries + 1):
            self._send(packet)
            deadline = time.monotonic() + self.timeout
            while True:
                reply = self._recv(deadline)
                if reply is None:
                    break
                if reply.seq != seq or reply.opcode != (opcode | 0x80):
                    continue
                self._raise_status(reply)
                return reply
        raise TimeoutError(f"bulk timeout opcode=0x{opcode:02X} addr=0x{addr:08X}")

    def stat(self) -> dict[str, int]:
        reply = self._one(OP_STAT, 0, 0)
        if reply.count != 16:
            raise BulkError(f"STAT returned {reply.count} words, expected 16")
        names = ("magic", "version", "max_words", "build_id", "rx_ok", "rx_bad_req",
                 "rx_busy", "rx_dropped", "txw_packets", "txw_words", "rxr_packets",
                 "rxr_words", "tx_replies", "reserved13", "reserved14", "reserved15")
        return dict(zip(names, (int(v) for v in reply.data)))

    def _status_error(self, opcode: int, seq: int, status: int) -> None:
        self._raise_status(BulkPacket(opcode, seq, 0, 0, status=status))

    def write_tx(self, channel: int, words: np.ndarray, *, batch_packets: int = 2,
                 words_per_packet: int = 2048, batches_in_flight: int = 4,
                 cancel: Callable[[], bool] | None = None,
                 on_progress: Callable[[int, int], None] | None = None) -> dict[str, float | int]:
        """Write one slot with TXW. Packets are built zero-copy and batches are pipelined: up to
        batches_in_flight batches (each ending with an ACK) are outstanding. The ACK carries the FPGA's
        global accepted-word counter (STAT[9] txw_words, saturating at 2^32-1, doc/03 §4): a batch is
        complete when the counter equals the baseline plus every word sent through that batch. On a
        mismatch or timeout the counter is resynchronized with STAT and sending restarts at that batch.

        Keep batch_packets x batches_in_flight <= 8 full packets (~66 KB in flight): on the V2.1 board 12
        or more packets in flight overflow the FPGA Ethernet RX path (losses are not counted in STAT) and
        every loss costs one timeout (E7_V21 bench, 2026-11-13). 2 x 4 measured 6.8-10.8 Gb/s native and
        4.9-5.8 Gb/s in Python, with no loss (reports/E7_V21/step2_native.md)."""
        values = np.ascontiguousarray(words, dtype="<u4")
        if not 0 <= channel < 8 or values.ndim != 1:
            raise ValueError("channel/words are invalid")
        if not 16 <= len(values) <= 524288 or len(values) % 16:      # V2.1 pooled slot: 8 banks x 65536 pairs
            raise ValueError("TXW words must be 16..524288 and divisible by 16")
        if not 16 <= words_per_packet <= 2048 or words_per_packet % 16:
            raise ValueError("words_per_packet must be a multiple of 16 in 16..2048")
        if batch_packets < 1 or batches_in_flight < 1:
            raise ValueError("batch_packets/batches_in_flight must be positive")
        if self._native is not None and batches_in_flight <= _NATIVE_MAX_WINDOW:
            ctx = self._native_ctx()
            cb, errors = self._native_callback(cancel, on_progress)
            with _PinnedThread():
                rc = self._native.awg_txw(ctx, channel, values.ctypes.data_as(ctypes.POINTER(ctypes.c_uint32)),
                                          len(values), words_per_packet, batch_packets, batches_in_flight, cb)
            self._native_result(rc, ctx, OP_TXW, errors)
            return {"packets": -(-len(values) // words_per_packet), "resent_batches": int(ctx.resent),
                    "seconds": float(ctx.seconds), "native": True}
        t0 = time.perf_counter()
        payload = memoryview(values.tobytes())
        offsets = list(range(0, len(values), words_per_packet))
        batches = [offsets[i:i + batch_packets] for i in range(0, len(offsets), batch_packets)]

        def batch_words(index: int) -> int:
            return sum(min(words_per_packet, len(values) - off) for off in batches[index])

        resent = 0
        failures = [0] * len(batches)
        counter = self.stat()["txw_words"]
        inflight: list[tuple[int, int, int]] = []      # (batch index, ack seq, expected counter)
        acks: dict[int, int] = {}
        next_batch = 0
        done_batches = 0
        with _PinnedThread():
            while done_batches < len(batches):
                if cancel and cancel():
                    raise BulkError("bulk TXW cancelled")
                while next_batch < len(batches) and len(inflight) < batches_in_flight:
                    base = inflight[-1][2] if inflight else counter
                    expected = min(base + batch_words(next_batch), 0xFFFFFFFF)  # saturated: CRC decides
                    batch = batches[next_batch]
                    ack_seq = 0
                    for index, off in enumerate(batch):
                        n = min(words_per_packet, len(values) - off)
                        last = index == len(batch) - 1
                        seq = self._next_seq()
                        if last:
                            ack_seq = seq
                        header = _HEADER.pack(protocol.MAGIC, protocol.VERSION, OP_TXW, seq,
                                              (channel << 28) | off, n, FLAG_ACK if last else 0, 0, 0, 0)
                        self._send(header + payload[off * 4:(off + n) * 4])
                    inflight.append((next_batch, ack_seq, expected))
                    next_batch += 1
                head_index, head_seq, head_expected = inflight[0]
                deadline = time.monotonic() + self.timeout
                while head_seq not in acks:
                    n = self._recv_raw(deadline)
                    if not n:
                        break
                    hdr = self._reply_header(n)
                    if hdr is None or hdr[0] != (OP_TXW | 0x80):
                        continue
                    _, seq, count, status = hdr
                    if status != STATUS_OK:
                        self._status_error(OP_TXW, seq, status)
                    if count == 1:
                        acks[seq] = struct.unpack_from("<I", self._recv_buf, protocol.HEADER_SIZE)[0]
                acked = acks.pop(head_seq, None)
                if acked == head_expected:
                    counter = acked
                    inflight.pop(0)
                    done_batches += 1
                    if on_progress:
                        last_off = batches[head_index][-1]
                        on_progress(min(last_off + words_per_packet, len(values)), len(values))
                    continue
                # A packet of this batch (or its ACK) was lost: resynchronize, resend from this batch.
                failures[head_index] += 1
                resent += 1
                if failures[head_index] > self.retries:
                    raise TimeoutError(f"bulk TXW batch timeout at word {batches[head_index][0]}")
                acks.clear()
                inflight.clear()
                counter = self.stat()["txw_words"]
                next_batch = head_index
        return {"packets": len(offsets), "resent_batches": resent,
                "seconds": time.perf_counter() - t0}

    def read_rx(self, slot: int, pair_offset: int, pair_count: int, *, window: int | None = None,
                cancel: Callable[[], bool] | None = None,
                on_progress: Callable[[int, int], None] | None = None) -> np.ndarray:
        """Read a slot with RXR using a sliding window of outstanding requests; replies are copied
        straight from the receive buffer into the result (no per-word Python objects)."""
        if not 0 <= slot < 8 or pair_offset < 0 or pair_count < 1:
            raise ValueError("slot/offset/count are invalid")
        if pair_offset % 12 or pair_count % 12 or pair_count > 0xFFFFFFF:
            raise ValueError("RXR offset/count must be multiples of 12")
        max_window = window or self.window
        if max_window < 1:
            raise ValueError("window must be positive")
        if self._native is not None:
            output = np.empty(pair_count, dtype="<u4")
            ctx = self._native_ctx()
            cb, errors = self._native_callback(cancel, on_progress)
            with _PinnedThread():
                rc = self._native.awg_rxr(ctx, slot, pair_offset, pair_count,
                                          min(max_window, _NATIVE_MAX_WINDOW),
                                          output.ctypes.data_as(ctypes.POINTER(ctypes.c_uint32)), cb)
            self._native_result(rc, ctx, OP_RXR, errors, expected=2040)
            self.last_rxr_resent = int(ctx.resent)
            return output
        chunk_words = 2040
        chunks = [(pair_offset + offset, min(chunk_words, pair_count - offset))
                  for offset in range(0, pair_count, chunk_words)]
        output = bytearray(pair_count * 4)
        out_view = memoryview(output)
        pending: dict[int, list] = {}                  # seq -> [offset, count, packet, retries, deadline]
        next_item = 0
        completed = 0
        with _PinnedThread():
            while next_item < len(chunks) or pending:
                if cancel and cancel():
                    raise BulkError("bulk RXR cancelled")
                now = time.monotonic()
                while next_item < len(chunks) and len(pending) < max_window:
                    offset, count = chunks[next_item]
                    seq = self._next_seq()
                    packet = _HEADER.pack(protocol.MAGIC, protocol.VERSION, OP_RXR, seq,
                                          (slot << 28) | offset, count, 0, 0, 0, 0)
                    self._send(packet)
                    pending[seq] = [offset, count, packet, 0, now + self.timeout]
                    next_item += 1
                deadline = min(item[4] for item in pending.values())
                n = self._recv_raw(deadline)
                if n:
                    hdr = self._reply_header(n)
                    if hdr is None or hdr[0] != (OP_RXR | 0x80):
                        continue
                    _, seq, count, status = hdr
                    item = pending.pop(seq, None)
                    if item is None:
                        continue                         # duplicate or late reply to a resent request
                    if status != STATUS_OK:
                        self._status_error(OP_RXR, seq, status)
                    offset, expected = item[0], item[1]
                    if count != expected:
                        raise BulkError(f"short RXR response: expected {expected}, got {count}")
                    start = (offset - pair_offset) * 4
                    out_view[start:start + expected * 4] = self._recv_view[
                        protocol.HEADER_SIZE:protocol.HEADER_SIZE + expected * 4]
                    completed += expected
                    if on_progress:
                        on_progress(completed, pair_count)
                    continue
                now = time.monotonic()
                for seq, item in list(pending.items()):
                    if now < item[4]:
                        continue
                    if item[3] >= self.retries:
                        raise TimeoutError(f"bulk RXR timeout at pair offset {item[0]}")
                    self._send(item[2])
                    item[3] += 1
                    item[4] = now + self.timeout
        return np.frombuffer(output, dtype="<u4").copy()
