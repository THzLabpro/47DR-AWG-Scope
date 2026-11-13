#!/usr/bin/env python3
"""CRC-32 reference for the D1 TX 14-bit waveform format."""

from __future__ import annotations

import argparse


def raw_sample(channel: int, sample_index: int) -> int:
    if sample_index == 0:
        return -32767
    if sample_index == 1:
        return 32767
    if sample_index == 2:
        return -16381
    if sample_index == 3:
        return 16383
    return ((sample_index * 37 + channel * 911) % 30000) - 15000


def quantized_sample(raw: int) -> int:
    # The RTL keeps bits [15:2] and restores the discarded low bits as zero.
    return (((raw & 0xFFFF) >> 2) & 0x3FFF) << 2


def crc32_waveform(channel: int, points: int) -> int:
    crc = 0xFFFFFFFF
    for sample_index in range(points):
        sample = quantized_sample(raw_sample(channel, sample_index))
        for byte in (sample & 0xFF, (sample >> 8) & 0xFF):
            crc ^= byte
            for _ in range(8):
                crc = (crc >> 1) ^ 0xEDB88320 if crc & 1 else crc >> 1
                crc &= 0xFFFFFFFF
    return (~crc) & 0xFFFFFFFF


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", type=int, default=0)
    parser.add_argument("--points", type=int, default=131072)
    args = parser.parse_args()
    print(
        f"CRC_REF channel={args.channel} points={args.points} "
        f"crc={crc32_waveform(args.channel, args.points):08X}"
    )


if __name__ == "__main__":
    main()
