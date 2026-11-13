import struct

import pytest

from awg_eth import protocol


def test_request_and_response_codecs_cover_read_write_semantics():
    read = protocol.encode_request(protocol.OP_READ, 9, 0x90200000, 3)
    assert len(read) == protocol.HEADER_SIZE
    assert protocol.decode_packet(read, response=False).count == 3

    write = protocol.encode_request(protocol.OP_WRITE, 10, 0x1000, 2, protocol.FLAG_NOINC, [4, 5])
    decoded_write = protocol.decode_packet(write, response=False)
    assert decoded_write.data == (4, 5)
    assert decoded_write.flags == protocol.FLAG_NOINC

    read_reply = protocol.Packet(protocol.OP_READ | 0x80, 9, 0x90200000, 2, data=(7, 8))
    assert protocol.decode_packet(protocol.encode_packet(read_reply, request=False), response=True).data == (7, 8)
    write_reply = protocol.Packet(protocol.OP_WRITE | 0x80, 10, 0x1000, 1, status=protocol.STATUS_AXI_ERR, err_index=1)
    assert protocol.decode_packet(protocol.encode_packet(write_reply, request=False), response=True).count == 1


@pytest.mark.parametrize("raw", [b"", b"\x00" * 23, struct.pack("<H", 0x1234) + b"\x00" * 22])
def test_codec_rejects_short_or_bad_headers(raw):
    with pytest.raises(protocol.ProtocolError):
        protocol.decode_packet(raw)


def test_codec_rejects_wrong_body_length():
    request = protocol.encode_request(protocol.OP_WRITE, 1, 0x1000, 2, data=(1, 2))
    with pytest.raises(protocol.ProtocolError):
        protocol.decode_packet(request[:-1], response=False)
