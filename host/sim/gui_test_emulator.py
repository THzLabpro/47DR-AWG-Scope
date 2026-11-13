"""Local-only emulator fixture for the native MATLAB GUI integration test."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from awg_eth.fpga_emu import FpgaEmulator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ready_file", type=Path)
    parser.add_argument("stop_file", type=Path)
    parser.add_argument("--build-id", type=lambda value: int(value, 0), default=0xD3C02026)
    parser.add_argument("--not-ready", action="store_true")
    args = parser.parse_args()
    with FpgaEmulator(host="127.0.0.1", build_id=args.build_id, loopback=True) as emulator:
        emulator._ps_ready = not args.not_ready
        args.ready_file.write_text(json.dumps({"port": emulator.port, "synthetic": True}))
        deadline = time.monotonic() + 600
        while not args.stop_file.exists() and time.monotonic() < deadline:
            time.sleep(0.05)


if __name__ == "__main__":
    main()
