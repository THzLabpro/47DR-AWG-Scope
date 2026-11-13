"""E5 probe: single-word CAP_RD_DATA reads at each capture stage, to locate the read-back hang.
Run from tools/:  py -X utf8 ../scripts/e5/e5_cap_read_probe.py <stage>
stage: idle | manual | start   (each stops at the first AXI timeout and prints the controller state it could read)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from awg_eth.awg import (Awg, REG_CAP_CTRL, REG_CAP_RD_CH, REG_CAP_RD_DATA, REG_CAP_RD_PTR,  # noqa: E402
                         REG_CAP_STATUS, REG_CAP_SAMPLES, REG_STATUS, REG_COMMAND)
from awg_eth.client import AwgEthClient  # noqa: E402


def regs(c):
    return {n: hex(c.read32(r)) for n, r in (("STATUS", REG_STATUS), ("CAP_STATUS", REG_CAP_STATUS),
                                             ("CAP_SAMPLES", REG_CAP_SAMPLES), ("CAP_RD_PTR", REG_CAP_RD_PTR))}


stage = sys.argv[1]
with AwgEthClient("192.168.42.2", words_per_packet=256, window=1, timeout=0.2, retries=1) as c:
    awg = Awg(c)
    print("before", regs(c), flush=True)
    if stage in ("manual", "start"):
        c.write32(REG_CAP_CTRL, (10 << 16) | (1 if stage == "start" else 0))
        awg.command(8)
        print("armed", regs(c), flush=True)
        if stage == "start":
            awg.start()
        awg.wait_capture_done()
        print("done", regs(c), flush=True)
    c.write32(REG_CAP_RD_CH, 2)
    print("rd_ch written", regs(c), flush=True)
    for i in range(4):
        v = c.read32(REG_CAP_RD_DATA)
        print(f"CAP_RD_DATA[{i}] = 0x{v:08X}", flush=True)
    print("after", regs(c), c.info(), flush=True)
