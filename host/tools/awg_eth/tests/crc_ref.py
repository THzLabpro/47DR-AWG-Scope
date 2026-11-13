"""Independent test reference for the frozen TX CRC byte stream."""

import binascii
import struct


def crc32(words):
    stream = bytearray()
    for word in words:
        word = int(word) & 0xFFFFFFFF
        sample_0 = word & 0xFFFF
        sample_1 = (word >> 16) & 0xFFFF
        stream.extend(struct.pack("<HH", sample_0 & 0xFFFC, sample_1 & 0xFFFC))
    return binascii.crc32(stream) & 0xFFFFFFFF
