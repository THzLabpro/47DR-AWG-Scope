"""File-IPC bridge used by MATLAB AWGBridge for the Ethernet backend."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import time

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from awg_eth.awg import (
    ABI, ADC_FS_HZ, DAC_FS_HZ, CAP_MAX_WORDS, TX_MAX_WORDS,
    REG_ID, REG_ABI, REG_BUILD_ID, REG_DAC_FS_KSPS, REG_ADC_FS_KSPS,
    REG_MAX_WORDS, Awg,
)
from awg_eth.client import AwgEthClient

_FIELD = re.compile(r"^([a-z_]+) ([0-9a-fA-F]*)\r?$")


def read_fields(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        if not line:
            continue
        match = _FIELD.fullmatch(line)
        if not match or len(match.group(2)) % 2:
            raise ValueError("Malformed bridge field")
        result[match.group(1)] = bytes.fromhex(match.group(2)).decode("utf-8")
    return result


def write_fields(path: Path, fields: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="ascii", newline="\n") as stream:
        for key, value in fields.items():
            if not re.fullmatch(r"[a-z_]+", key):
                raise ValueError(f"Invalid IPC field name: {key}")
            encoded = str(value).encode("utf-8").hex()
            stream.write(f"{key} {encoded}\n")
    # MATLAB/Windows may briefly hold the destination open during fileread.
    # Retry the atomic rename; the previous complete record remains readable.
    deadline = time.monotonic() + 1.0
    while True:
        try:
            os.replace(temporary, path)
            break
        except PermissionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.01)


class GuiBridge:
    def __init__(self, session: Path):
        self.session = session.resolve()
        self.client: AwgEthClient | None = None
        self.awg: Awg | None = None
        self.quit = False
        self.request = ""

    def connect(self) -> dict[str, object]:
        config = read_fields(self.session / "config.txt")
        ip = config.get("fpga_ip", "127.0.0.1")
        port = int(config.get("port", "9100"))
        words_per_packet = int(config.get("words_per_packet", "256"))
        self.client = AwgEthClient(ip, port=port, words_per_packet=words_per_packet)
        try:
            self.client.ping()
            info = self.client.info()
            # Only reads are allowed until the exact release contract is checked.
            checks = {
                "INFO AWG ID": (info["awg_id"], 0x41574531),
                "INFO build": (info["build_id"], 0xD3C02026),
                "register ID": (self.client.read32(REG_ID), 0x41574732),
                "ABI": (self.client.read32(REG_ABI), ABI),
                "build": (self.client.read32(REG_BUILD_ID), 0xD3C02026),
                "DAC kS/s": (self.client.read32(REG_DAC_FS_KSPS), DAC_FS_HZ // 1000),
                "ADC kS/s": (self.client.read32(REG_ADC_FS_KSPS), ADC_FS_HZ // 1000),
                "RAM capacity": (self.client.read32(REG_MAX_WORDS),
                                 (CAP_MAX_WORDS << 16) | TX_MAX_WORDS),
            }
            mismatch = [f"{key}: got 0x{actual:X}, expected 0x{expected:X}"
                        for key, (actual, expected) in checks.items() if actual != expected]
            if mismatch:
                raise ValueError("firmware mismatch: " + "; ".join(mismatch))
            self.awg = Awg(self.client, progress_callback=self.progress)
            state = self.awg.status()
        except BaseException:
            self.client.close()
            self.client = None
            self.awg = None
            raise
        result: dict[str, object] = {
            "ok": 1, "message": "Ethernet connected", "transport": "eth",
            "device": ip, "target": f"UDP:{port}",
            "running": state["running"], "busy": state["busy"], "ps_ready": state["ps_ready"],
            "fault": state["fault"], "command_result": state["command_result"],
            "init_stage": "unavailable", "fault_channels": state["fault_channels"],
            "length_beats": state["length_beats"], "channel_mask": state["channel_mask"],
            "abi": state["abi"], "cap_busy": state["cap_busy"], "cap_done": state["cap_done"],
        }
        result.update({f"info_{key}": value for key, value in info.items()})
        return result

    def progress(self, phase: str, channel: str, done: int, total: int) -> None:
        try:
            write_fields(self.session / "progress.txt", {
                "request": self.request, "phase": phase,
                "channel": channel.removeprefix("CH"), "done": done, "total": total,
            })
        except OSError:
            # Progress is advisory. A display-file lock must not abort an RF task.
            pass

    @staticmethod
    def verify(request: dict[str, str]) -> bool:
        value = request.get("verify", "1")
        if value not in {"0", "1"}:
            raise ValueError("verify must be 0 or 1")
        return value == "1"

    def dispatch(self, request: dict[str, str]) -> dict[str, object]:
        if self.awg is None:
            raise RuntimeError("Ethernet bridge is not connected")
        action = request.get("action", "")
        if action == "status":
            result = self.awg.status()
        elif action == "start":
            result = self.awg.start()
        elif action == "stop":
            result = self.awg.stop()
        elif action == "clear":
            result = self.awg.clear()
        elif action == "load":
            result = self.awg.load(request["directory"], verify=self.verify(request))
        elif action == "capture":
            path = self.awg.capture(request["capture"], request.get("trigger", "manual"),
                                    int(request.get("mask", "255"), 0), samples=int(request.get("samples", "65520")))
            result = {**self.awg.status(), "capture": path}
        elif action == "run":
            # Validate capture arguments before load changes board state.
            samples = int(request.get("samples", "65520"))
            mask = int(request.get("mask", "255"), 0)
            trigger = request.get("trigger", "manual")
            if not 24 <= samples <= CAP_MAX_WORDS * 24 or samples % 24:
                raise ValueError("capture samples must be 24..65520 and divisible by 24")
            if not 1 <= mask <= 255 or trigger not in {"manual", "start"}:
                raise ValueError("invalid capture mask or trigger")
            self.awg.load(request["directory"], verify=self.verify(request))
            if request.get("trigger", "manual") == "manual":
                self.awg.start()
            path = self.awg.capture(request["capture"], trigger, mask, samples=samples)
            result = {**self.awg.status(), "capture": path}
        elif action == "disconnect":
            self.quit = True
            result = {"disconnected": 1}
        else:
            raise ValueError(f"Unsupported application action: {action}")
        return {"ok": 1, "message": "Completed", **result}

    def main(self) -> int:
        try:
            write_fields(self.session / "hello.res", self.connect())
        except Exception as exc:
            write_fields(self.session / "hello.res", {"ok": 0, "message": str(exc)})
            return 1
        try:
            while not self.quit:
                requests = sorted(self.session.glob("*.req"))
                for path in requests:
                    response_path = path.with_suffix(".res")
                    self.request = path.stem
                    try:
                        response = self.dispatch(read_fields(path))
                    except Exception as exc:
                        response = {"ok": 0, "message": str(exc)}
                        if self.awg:
                            try:
                                response.update(self.awg.status())
                            except Exception:
                                pass
                    write_fields(response_path, response)
                    path.unlink(missing_ok=True)
                    if self.quit:
                        break
                heartbeat = self.session / "heartbeat"
                if not heartbeat.exists() or time.time() - heartbeat.stat().st_mtime > 120:
                    break
                time.sleep(0.05)
        finally:
            if self.client:
                self.client.close()
        return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    args = parser.parse_args()
    raise SystemExit(GuiBridge(args.session).main())


if __name__ == "__main__":
    main()
