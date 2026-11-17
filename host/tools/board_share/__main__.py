"""Serve the shared panel, launch a configured client, or guard a local command."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
from .client import credentials, Lease
from .server import Server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=4749)
    serve.add_argument("--state", default=str(Path(__file__).resolve().parents[2] / "app_data" / "board_share.sqlite3"))
    for mode in ("client", "run"):
        cmd = sub.add_parser(mode)
        cmd.add_argument("--ticket-file", required=True)
        cmd.add_argument("--url")
        if mode == "run":
            cmd.add_argument("--project", required=True)
            cmd.add_argument("--label", default="下载与测试")
        cmd.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.mode == "serve":
        with Server((args.bind, args.port), args.state) as server:
            print(f"Board sharing panel listening on {args.bind}:{args.port}", flush=True)
            server.serve_forever()
        return 0
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("请在 -- 后填写要启动的程序。")
    data = credentials(args.ticket_file)
    url = args.url or data["url"]
    env = os.environ.copy()
    env.update(BOARD_SHARE_URL=url, BOARD_SHARE_TICKET_FILE=str(Path(args.ticket_file).resolve()))
    if args.mode == "client":
        return subprocess.call(command, env=env)
    lease = Lease(url, data["ticket"], args.project, args.label)
    try:
        # Generic external tools have no inner gate. Keep ownership until the tool exits.
        # An interrupted wrapper must retain the operation record for manual reconciliation.
        result = subprocess.call(command, env=os.environ.copy())
    except BaseException:
        print("入口中断，操作占用已保留；确认原程序结束后在面板解除。", file=sys.stderr)
        raise
    lease.close()
    return result


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(2)
