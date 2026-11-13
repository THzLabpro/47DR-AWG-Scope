"""UDP client with bounded windows and same-sequence retransmission."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import random
import select
import socket
import sys
import time
from typing import Iterable

from . import protocol

CONTROL_SERIAL_ADDRESSES = {0x90200008, 0x9020000C, 0x90200010}


class _PinnedThread:
    """Pin the calling thread to its current CPU while pipelining (Windows only).

    E6 on the board: with several datagrams in flight, Windows sent adjacent NOINC packets out of
    order whenever the thread migrated between cores (different XL710 TX queues): 26/80 channel
    writes had two adjacent packets swapped. Pinned: 0/80. NOINC ports are order-sensitive.
    """

    def __enter__(self):
        self._old = None
        if sys.platform != "win32":
            return self
        try:
            k32 = ctypes.windll.kernel32
            k32.GetCurrentThread.restype = ctypes.c_void_p
            k32.SetThreadAffinityMask.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
            k32.SetThreadAffinityMask.restype = ctypes.c_size_t
            cpu = k32.GetCurrentProcessorNumber()
            self._k32 = k32
            self._old = k32.SetThreadAffinityMask(k32.GetCurrentThread(), 1 << cpu) or None
        except (AttributeError, OSError):
            self._old = None
        return self

    def __exit__(self, *_exc):
        if self._old:
            self._k32.SetThreadAffinityMask(self._k32.GetCurrentThread(), self._old)


class PipelineAbort(RuntimeError):
    """A pipelined NOINC transfer lost a packet; `results` holds the replies received (None = missing)."""

    def __init__(self, results):
        super().__init__("pipelined transfer lost a packet")
        self.results = results


class AwgEthError(RuntimeError):
    def __init__(self, message: str, *, status: int | None = None,
                 err_index: int | None = None, address: int | None = None):
        super().__init__(message)
        self.status = status
        self.err_index = err_index
        self.address = address


@dataclass
class _Pending:
    seq: int
    packet: bytes
    opcode: int
    addr: int
    count: int
    sent_at: float
    retries_done: int = 0


class AwgEthClient:
    def __init__(self, fpga_ip: str, port: int = 9100, local_ip: str | None = None,
                 words_per_packet: int = 256, window: int = 8,
                 timeout: float = 0.05, retries: int = 5):
        if not 1 <= words_per_packet <= protocol.MAX_WORDS:
            raise ValueError(f"words_per_packet must be 1..{protocol.MAX_WORDS}")
        if window < 1 or timeout <= 0 or retries < 0:
            raise ValueError("window/timeout/retries are invalid")
        self.fpga_ip = fpga_ip
        self.port = port
        self.words_per_packet = words_per_packet
        self.window = window
        self.timeout = timeout
        self.retries = retries
        self._seq = random.SystemRandom().randrange(1 << 32)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 * 1024 * 1024)
        bind_ip = local_ip or "0.0.0.0"
        self.socket.bind((bind_ip, 0))
        self._peer = (fpga_ip, port)

    def close(self) -> None:
        self.socket.close()

    def __enter__(self) -> "AwgEthClient":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def _next_seq(self) -> int:
        self._seq = (self._seq + 1) & 0xFFFFFFFF
        return self._seq

    def _exchange_many(self, items: list[tuple[int, int, int, tuple[int, ...], int]],
                       *, window: int | None = None, abort_on_timeout: bool = False,
                       on_reply=None, cancel=None) -> list[protocol.Packet]:
        results: list[protocol.Packet | None] = [None] * len(items)
        pending: dict[int, tuple[int, _Pending]] = {}
        next_item = 0
        max_window = window or self.window
        while next_item < len(items) or pending:
            if cancel is not None and cancel():
                raise AwgEthError("transfer cancelled")
            while next_item < len(items) and len(pending) < max_window:
                opcode, addr, count, data, flags = items[next_item]
                seq = self._next_seq()
                body = protocol.encode_request(opcode, seq, addr, count, flags, data)
                state = _Pending(seq, body, opcode, addr, count, time.monotonic())
                self.socket.sendto(body, self._peer)
                pending[seq] = (next_item, state)
                next_item += 1

            now = time.monotonic()
            deadline = min(state.sent_at + self.timeout for _, state in pending.values())
            readable, _, _ = select.select([self.socket], [], [], max(0.0, deadline - now))
            if readable:
                raw, peer = self.socket.recvfrom(65535)
                if peer[0] != self._peer[0] or peer[1] != self._peer[1]:
                    continue
                try:
                    reply = protocol.decode_packet(raw, response=True)
                except protocol.ProtocolError:
                    continue
                match = pending.pop(reply.seq, None)
                if match is None:
                    continue
                index, state = match
                if reply.opcode != (state.opcode | 0x80):
                    pending[reply.seq] = match
                    continue
                if reply.status != protocol.STATUS_OK:
                    bad_addr = state.addr
                    if not reply.flags & protocol.FLAG_NOINC and not (
                        state.opcode == protocol.OP_WRITE and state.addr in CONTROL_SERIAL_ADDRESSES
                    ):
                        bad_addr = (state.addr + reply.err_index * 4) & 0xFFFFFFFF
                    raise AwgEthError(
                        f"FPGA request failed: status={reply.status}, err_index={reply.err_index}, address=0x{bad_addr:08X}",
                        status=reply.status,
                        err_index=reply.err_index,
                        address=bad_addr,
                    )
                results[index] = reply
                if on_reply is not None:
                    on_reply(index, reply)

            now = time.monotonic()
            for seq, (index, state) in list(pending.items()):
                if now - state.sent_at < self.timeout:
                    continue
                if abort_on_timeout:
                    raise PipelineAbort(results)
                if state.retries_done >= self.retries:
                    raise TimeoutError(
                        f"FPGA timeout after {self.retries} retries: opcode={state.opcode} address=0x{state.addr:08X} seq={seq}"
                    )
                self.socket.sendto(state.packet, self._peer)
                state.sent_at = now
                state.retries_done += 1
                pending[seq] = (index, state)
        return [reply for reply in results if reply is not None]

    def _limit_window(self, opcode: int, address: int, requested: int) -> int:
        if opcode == protocol.OP_WRITE and address in CONTROL_SERIAL_ADDRESSES:
            return 1
        return requested

    def read32(self, address: int) -> int:
        return self.read_block(address, 1)[0]

    def write32(self, address: int, value: int) -> None:
        self.write_block(address, [value])

    def read_block(self, address: int, count: int, *, noinc: bool = False) -> list[int]:
        if address & 3 or count < 0:
            raise ValueError("address must be 4-byte aligned and count non-negative")
        if count == 0:
            return []
        flags = protocol.FLAG_NOINC if noinc else 0
        items = []
        chunks = []
        for offset in range(0, count, self.words_per_packet):
            chunk_count = min(self.words_per_packet, count - offset)
            addr = address if noinc else address + offset * 4
            items.append((protocol.OP_READ, addr, chunk_count, (), flags))
            chunks.append(chunk_count)
        read_window = 1 if noinc else self._limit_window(protocol.OP_READ, address, self.window)
        replies = self._exchange_many(items, window=read_window)
        values: list[int] = []
        for reply, expected in zip(replies, chunks):
            if reply.count != expected:
                raise AwgEthError(f"short READ response: expected {expected}, got {reply.count}", address=address)
            values.extend(reply.data)
        return values

    def write_block(self, address: int, words: Iterable[int], *, noinc: bool = False) -> None:
        if address & 3:
            raise ValueError("address must be 4-byte aligned")
        values = tuple(int(word) & 0xFFFFFFFF for word in words)
        if not values:
            return
        flags = protocol.FLAG_NOINC if noinc else 0
        items = []
        for offset in range(0, len(values), self.words_per_packet):
            data = values[offset:offset + self.words_per_packet]
            addr = address if noinc else address + offset * 4
            items.append((protocol.OP_WRITE, addr, len(data), data, flags))
        write_window = 1 if noinc else self._limit_window(protocol.OP_WRITE, address, self.window)
        if not noinc and any(address + offset * 4 in CONTROL_SERIAL_ADDRESSES for offset in range(len(values))):
            write_window = 1
        self._exchange_many(items, window=write_window)

    # ---- pipelined NOINC data-port transfers -------------------------------------------------
    # NOINC ports (TX_WR_DATA FIFO, CAP_RD_DATA auto-increment) are not idempotent, so a
    # retransmission could reorder data. These keep several packets in flight but never
    # retransmit: on any timeout they raise PipelineAbort and the caller recovers explicitly.
    # Measured on the board (E6, reports/E6_GUI/pipeline_sweep.json): the bridge RX FIFO is 128 bit wide
    # but filled 8 bytes per beat, so it holds ~16 KB of write payload; more in flight is dropped
    # (rx_dropped). Writes peak at ~41 MB/s with 512-word packets x 8; we keep 12 KB in flight for margin.
    # Read requests are tiny and replies are never dropped; 2048 x 6 reads at ~30 MB/s.
    WRITE_INFLIGHT_BYTES = 12288
    WRITE_CHUNK_WORDS = 512
    READ_WINDOW = 6

    def stream_window(self, chunk_words: int | None = None) -> int:
        """Write packets in flight for chunk_words-sized packets."""
        chunk = chunk_words or self.write_chunk_words()
        return max(1, min(16, self.WRITE_INFLIGHT_BYTES // (4 * chunk)))

    def write_chunk_words(self) -> int:
        return min(self.words_per_packet, self.WRITE_CHUNK_WORDS)

    def write_stream(self, address: int, words, *, window: int | None = None,
                     on_progress=None, cancel=None) -> None:
        values = tuple(words)
        n = self.write_chunk_words() if window is None else self.words_per_packet
        items = [(protocol.OP_WRITE, address, len(values[o:o + n]), values[o:o + n], protocol.FLAG_NOINC)
                 for o in range(0, len(values), n)]
        done = [0]

        def progress(index, reply):
            done[0] += reply.count if reply.count else items[index][2]
            if on_progress:
                on_progress(done[0], len(values))
        with _PinnedThread():
            self._exchange_many(items, window=window or self.stream_window(n), abort_on_timeout=True,
                                on_reply=progress, cancel=cancel)

    def read_stream(self, address: int, count: int, *, window: int | None = None,
                    on_progress=None, cancel=None) -> list[int]:
        n = self.words_per_packet
        chunks = [min(n, count - o) for o in range(0, count, n)]
        items = [(protocol.OP_READ, address, c, (), protocol.FLAG_NOINC) for c in chunks]
        done = [0]

        def progress(index, reply):
            done[0] += reply.count
            if on_progress:
                on_progress(done[0], count)
        with _PinnedThread():
            replies = self._exchange_many(items, window=window or self.READ_WINDOW, abort_on_timeout=True,
                                          on_reply=progress, cancel=cancel)
        values: list[int] = []
        for reply, expected in zip(replies, chunks):
            if reply.count != expected:
                raise AwgEthError(f"short READ response: expected {expected}, got {reply.count}", address=address)
            values.extend(reply.data)
        return values

    def drain(self, quiet: float | None = None) -> int:
        """Discard late replies until the socket is quiet (after a PipelineAbort)."""
        quiet = self.timeout if quiet is None else quiet
        dropped = 0
        while True:
            readable, _, _ = select.select([self.socket], [], [], quiet)
            if not readable:
                return dropped
            try:
                self.socket.recvfrom(65535)
            except OSError:
                return dropped
            dropped += 1

    def ping(self) -> None:
        reply = self._exchange_many([(protocol.OP_PING, 0, 0, (), 0)], window=1)[0]
        if reply.count != 0:
            raise AwgEthError("PING response must have count zero")

    def info(self) -> dict[str, int]:
        reply = self._exchange_many([(protocol.OP_INFO, 0, 0, (), 0)], window=1)[0]
        if reply.count != 16:
            raise AwgEthError(f"INFO returned {reply.count} words, expected 16")
        return {
            "awg_id": reply.data[0], "protocol_version": reply.data[1], "max_words": reply.data[2],
            "build_id": reply.data[3], "rx_ok": reply.data[4], "rx_bad_req": reply.data[5],
            "rx_dropped": reply.data[6], "tx_replies": reply.data[7], "dup_writes": reply.data[8],
            "axi_errors": reply.data[9], "axi_timeouts": reply.data[10], "axi_words": reply.data[11],
        }
