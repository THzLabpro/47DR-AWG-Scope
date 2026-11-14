"""Loopback-only remote service and FPGA emulator for MATLAB tests."""
import json
from pathlib import Path
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from awg_eth.fpga_emu import FpgaEmulator
from awg_eth.remote import RemoteServer

ready, stop = map(Path, sys.argv[1:3])
with FpgaEmulator(host='127.0.0.1', build_id=0xD3C02026, loopback=True) as emu:
    with RemoteServer(('127.0.0.1', 0), fpga_ip='127.0.0.1', fpga_port=emu.port) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        ready.write_text(json.dumps({'port': server.server_address[1]}))
        deadline = time.monotonic() + 600
        while not stop.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        server.shutdown()
        thread.join()
