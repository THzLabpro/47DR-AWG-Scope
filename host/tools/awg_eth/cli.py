"""Command-line interface for the 47DR v2 Ethernet host library."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

from . import protocol
from .awg import Awg, CAP_MAX_SAMPLES, REG_CAP_CTRL, REG_CAP_RD_CH, REG_CAP_RD_DATA, REG_CAP_RD_PTR, REG_COMMAND, REG_TX_WR_CH, REG_TX_WR_DATA
from .client import AwgEthClient


def _make_client(args) -> AwgEthClient:
    return AwgEthClient(
        args.ip, port=args.port, words_per_packet=args.words_per_packet,
        window=args.window, timeout=args.timeout, retries=args.retries,
    )


def _bench(client: AwgEthClient, words: int) -> dict[str, float]:
    if words < 1 or words > CAP_MAX_SAMPLES // 2:
        raise ValueError(f"bench words must be 1..{CAP_MAX_SAMPLES // 2}")
    awg = Awg(client)
    awg.stop()
    awg.clear()
    client.write32(REG_TX_WR_CH, 0)
    pattern = tuple(((index * 0x10203) ^ 0x5A5AA5A5) & 0xFFFFFFFF for index in range(words))
    started = time.perf_counter()
    client.write_block(REG_TX_WR_DATA, pattern, noinc=True)
    write_elapsed = max(time.perf_counter() - started, 1e-12)

    cap_words = max(1, min((words * 2 + 23) // 24, 2730))
    client.write32(REG_CAP_CTRL, cap_words << 16)
    client.write32(REG_COMMAND, 8)
    awg.wait_capture_done()
    client.write32(REG_CAP_RD_CH, 0)
    client.write32(REG_CAP_RD_PTR, 0)
    read_words = (cap_words * 24) // 2
    started = time.perf_counter()
    received = client.read_block(REG_CAP_RD_DATA, read_words, noinc=True)
    read_elapsed = max(time.perf_counter() - started, 1e-12)
    if len(received) != read_words:
        raise RuntimeError("short CAP_RD_DATA benchmark read")
    write_mbps = len(pattern) * 4 / write_elapsed / 1_000_000
    read_mbps = len(received) * 4 / read_elapsed / 1_000_000
    return {"write_mbps": write_mbps, "read_mbps": read_mbps,
            "write_bytes": len(pattern) * 4, "read_bytes": len(received) * 4}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ip", default="192.168.42.2")
    parser.add_argument("--port", type=int, default=9100)
    parser.add_argument("--words-per-packet", type=int, default=256)
    parser.add_argument("--window", type=int, default=8)
    parser.add_argument("--timeout", type=float, default=0.05)
    parser.add_argument("--retries", type=int, default=5)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ping")
    sub.add_parser("info")
    sub.add_parser("status")
    load_parser = sub.add_parser("load")
    load_parser.add_argument("directory", type=Path)
    sub.add_parser("start")
    sub.add_parser("stop")
    sub.add_parser("abort")
    capture_parser = sub.add_parser("capture")
    capture_parser.add_argument("csv", type=Path)
    capture_parser.add_argument("--mask", type=lambda value: int(value, 0), default=0xFF)
    capture_parser.add_argument("--trigger", choices=("manual", "start"), default="manual")
    bench_parser = sub.add_parser("bench")
    bench_parser.add_argument("--words", type=int, default=32760)
    args = parser.parse_args()

    with _make_client(args) as client:
        awg = Awg(client)
        if args.command == "ping":
            client.ping()
            print("PING OK")
        elif args.command == "info":
            print(json.dumps(client.info(), indent=2))
        elif args.command == "status":
            print(json.dumps(awg.status(), indent=2))
        elif args.command == "load":
            print(json.dumps(awg.load(args.directory, verify=True), indent=2))
        elif args.command == "start":
            print(json.dumps(awg.start(), indent=2))
        elif args.command == "stop":
            print(json.dumps(awg.stop(), indent=2))
        elif args.command == "abort":
            print(json.dumps(awg.abort_capture(), indent=2))
        elif args.command == "capture":
            print(awg.capture(args.csv, trigger=args.trigger, channel_mask=args.mask))
        elif args.command == "bench":
            result = _bench(client, args.words)
            print(f"WRITE {result['write_mbps']:.3f} MB/s ({result['write_bytes']} bytes)")
            print(f"READ  {result['read_mbps']:.3f} MB/s ({result['read_bytes']} bytes)")


if __name__ == "__main__":
    main()
