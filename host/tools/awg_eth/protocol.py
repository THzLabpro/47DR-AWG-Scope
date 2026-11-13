"""Pure codec for the frozen UDP protocol in doc/00_ETH_PLAN.md §4.2."""

from __future__ import annotations

from dataclasses import dataclass
import struct
from typing import Iterable

MAGIC = 0xA7E1
VERSION = 1
HEADER_SIZE = 24
MAX_WORDS = 2048
FLAG_NOINC = 1

OP_READ = 1
OP_WRITE = 2
OP_INFO = 3
OP_PING = 4
STATUS_OK = 0
STATUS_AXI_ERR = 1
STATUS_BAD_REQ = 2
STATUS_AXI_TIMEOUT = 3
STATUS_BUSY = 4

_HEADER = struct.Struct("<HBBIIHHHHI")


class ProtocolError(ValueError):
    """A datagram violates the wire format."""


@dataclass(frozen=True)
class Packet:
    opcode: int
    seq: int
    addr: int
    count: int
    flags: int = 0
    status: int = STATUS_OK
    err_index: int = 0
    data: tuple[int, ...] = ()


def encode_packet(packet: Packet, *, request: bool) -> bytes:
    if not 0 <= packet.opcode <= 0xFF or not 0 <= packet.seq <= 0xFFFFFFFF:
        raise ProtocolError("opcode or sequence out of range")
    if not 0 <= packet.addr <= 0xFFFFFFFF:
        raise ProtocolError("address out of range")
    if not 0 <= packet.count <= 0xFFFF or not 0 <= packet.flags <= 0xFFFF:
        raise ProtocolError("count or flags out of range")
    if not 0 <= packet.status <= 0xFFFF or not 0 <= packet.err_index <= 0xFFFF:
        raise ProtocolError("status or err_index out of range")
    payload = struct.pack(f"<{len(packet.data)}I", *packet.data) if packet.data else b""
    base_opcode = packet.opcode & 0x7F
    if request:
        if packet.status or packet.err_index:
            raise ProtocolError("request status and err_index must be zero")
        if base_opcode == OP_WRITE:
            if len(packet.data) != packet.count:
                raise ProtocolError("WRITE count does not match data length")
        elif packet.data:
            raise ProtocolError("only WRITE requests carry data")
        if base_opcode in (OP_INFO, OP_PING) and packet.count != 0:
            raise ProtocolError("INFO/PING requests must have count zero")
    elif base_opcode in (OP_READ, OP_INFO) and len(packet.data) != packet.count:
        raise ProtocolError("response count does not match data length")
    elif base_opcode in (OP_WRITE, OP_PING) and packet.data:
        raise ProtocolError("WRITE/PING responses do not carry data")
    header = _HEADER.pack(
        MAGIC,
        VERSION,
        packet.opcode,
        packet.seq,
        packet.addr,
        packet.count,
        packet.flags,
        packet.status,
        packet.err_index,
        0,
    )
    return header + payload


def encode_request(opcode: int, seq: int, addr: int = 0, count: int = 0,
                   flags: int = 0, data: Iterable[int] = ()) -> bytes:
    return encode_packet(Packet(opcode, seq, addr, count, flags, data=tuple(data)), request=True)


def decode_packet(datagram: bytes, *, response: bool | None = None) -> Packet:
    if len(datagram) < HEADER_SIZE:
        raise ProtocolError("packet shorter than 24-byte header")
    magic, version, opcode, seq, addr, count, flags, status, err_index, reserved = _HEADER.unpack_from(datagram)
    if magic != MAGIC or version != VERSION:
        raise ProtocolError("invalid magic or protocol version")
    if reserved != 0 or flags & ~FLAG_NOINC:
        raise ProtocolError("reserved fields must be zero")
    if response is True and not opcode & 0x80:
        raise ProtocolError("expected response opcode")
    if response is False and opcode & 0x80:
        raise ProtocolError("expected request opcode")
    body = datagram[HEADER_SIZE:]
    base_opcode = opcode & 0x7F
    if response is False and base_opcode == OP_WRITE:
        if len(body) != count * 4:
            raise ProtocolError("WRITE request length does not match count")
    elif response is False:
        if body:
            raise ProtocolError("only WRITE requests carry data")
        if base_opcode in (OP_INFO, OP_PING) and count != 0:
            raise ProtocolError("INFO/PING requests must have count zero")
    elif response is True and base_opcode in (OP_READ, OP_INFO):
        if len(body) % 4 or len(body) != count * 4:
            raise ProtocolError("data length does not match count")
    elif body:
        raise ProtocolError("WRITE/PING responses do not carry data")
    if response is False and (status != STATUS_OK or err_index != 0):
        raise ProtocolError("request status and err_index must be zero")
    data = struct.unpack_from(f"<{len(body) // 4}I", body) if body else ()
    return Packet(opcode, seq, addr, count, flags, status, err_index, data)
