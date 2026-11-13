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

from awg_eth.awg import Awg
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
    os.replace(temporary, path)


class GuiBridge:
    def __init__(self, session: Path):
        self.session = session.resolve()
        self.client: AwgEthClient | None = None
        self.awg: Awg | None = None
        self.quit = False

    def connect(self) -> dict[str, object]:
        config = read_fields(self.session / "config.txt")
        ip = config.get("fpga_ip", "127.0.0.1")
        port = int(config.get("port", "9100"))
        words_per_packet = int(config.get("words_per_packet", "256"))
        self.client = AwgEthClient(ip, port=port, words_per_packet=words_per_packet)
        self.awg = Awg(self.client, progress_callback=self.progress)
        self.client.ping()
        info = self.client.info()
        state = self.awg.status()
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
        write_fields(self.session / "progress.txt", {
            "phase": phase, "channel": channel, "done": done, "total": total,
        })

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
            result = self.awg.load(request["directory"], verify=True)
        elif action == "capture":
            path = self.awg.capture(request["capture"], request.get("trigger", "manual"), int(request.get("mask", "255"), 0))
            result = {**self.awg.status(), "capture": path}
        elif action == "run":
            self.awg.load(request["directory"], verify=True)
            if request.get("trigger", "manual") == "manual":
                self.awg.start()
            path = self.awg.capture(request["capture"], request.get("trigger", "manual"), int(request.get("mask", "255"), 0))
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
