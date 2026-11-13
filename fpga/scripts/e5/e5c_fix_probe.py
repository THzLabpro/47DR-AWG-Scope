"""E5C: on-board checks of the D3C fixes. Run from tools/:  py -X utf8 ../scripts/e5/e5c_fix_probe.py
A jumbo: TX_WR_DATA writes of 256..2048 words per packet are accepted.
B CAP_RD_CH rewinds CAP_RD_PTR (raw register writes, no host workaround).
C CAP_RD_DATA with the pointer past the buffer returns an AXI error and the bus stays usable.
Also COMMAND=32 abort of an armed capture.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from awg_eth import protocol  # noqa: E402
from awg_eth.awg import (Awg, REG_BUILD_ID, REG_CAP_CTRL, REG_CAP_RD_CH, REG_CAP_RD_DATA, REG_CAP_RD_PTR,  # noqa: E402
                         REG_CAP_STATUS, REG_ID, REG_TX_WR_CH, REG_TX_WR_DATA, REG_TX_WR_PTR)
from awg_eth.client import AwgEthClient, AwgEthError  # noqa: E402

results = []


def check(name, ok, detail=""):
    results.append({"name": name, "pass": bool(ok), "detail": detail})
    print(("PASS " if ok else "FAIL ") + name + (f"  {detail}" if detail else ""), flush=True)


with AwgEthClient("192.168.42.2", words_per_packet=2048, window=1, timeout=0.2, retries=1) as c:
    awg = Awg(c)
    check("BUILD_ID is D3C", c.read32(REG_BUILD_ID) == 0xD3C02026, hex(c.read32(REG_BUILD_ID)))
    awg.stop()
    for n in (256, 350, 368, 512, 1024, 2048):
        c.write32(REG_TX_WR_CH, 0)
        before = c.info()["rx_ok"]
        try:
            c.write_block(REG_TX_WR_DATA, [0x00040008] * n, noinc=True)
            ok = c.read32(REG_TX_WR_PTR) == (2 * n) // 32 * 32   # TX_WR_PTR counts whole 32-sample URAM words
            err = ""
        except Exception as exc:  # noqa: BLE001
            ok, err = False, type(exc).__name__
        check(f"A jumbo write {n} words ({24 + 4 * n} B payload)", ok, err or f"rx_ok+{c.info()['rx_ok'] - before - 1}")
    c.write32(REG_CAP_RD_CH, 0)          # rewinds the pointer (fix B), otherwise a previous run may leave it at 32760
    try:
        data = c.read_block(REG_CAP_RD_DATA, 2048, noinc=True)
        check("A jumbo read 2048 words", len(data) == 2048)
    except Exception as exc:  # noqa: BLE001
        check("A jumbo read 2048 words", False, type(exc).__name__)

    c.write32(REG_CAP_RD_PTR, 123)
    c.write32(REG_CAP_RD_CH, 1)
    check("B CAP_RD_CH rewinds pointer", c.read32(REG_CAP_RD_PTR) == 0, f"ptr={c.read32(REG_CAP_RD_PTR)}")

    c.write32(REG_CAP_RD_PTR, 32759)
    c.read32(REG_CAP_RD_DATA)
    check("C pointer reaches 32760", c.read32(REG_CAP_RD_PTR) == 32760)
    try:
        c.read32(REG_CAP_RD_DATA)
        check("C past-end read returns AXI error", False, "no error")
    except AwgEthError as exc:
        check("C past-end read returns AXI error", exc.status == protocol.STATUS_AXI_ERR, f"status={exc.status}")
    except TimeoutError as exc:
        check("C past-end read returns AXI error", False, f"timeout {exc}")
    check("C bus alive after past-end read", c.read32(REG_ID) == 0x41574732)
    info = c.info()
    check("C no AXI timeouts", info["axi_timeouts"] == 0, f"axi_timeouts={info['axi_timeouts']} axi_errors={info['axi_errors']}")

    c.write32(REG_CAP_CTRL, (10 << 16) | 1)
    awg.command(8)
    armed = c.read32(REG_CAP_STATUS)
    awg.abort_capture()
    after = c.read32(REG_CAP_STATUS)
    check("abort clears armed capture", (armed & 4) and after == 0, f"armed={armed:#x} after={after:#x}")
    print(json.dumps(c.info()))

Path("../reports/E5C").mkdir(parents=True, exist_ok=True)
Path("../reports/E5C/fix_probe.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
print(f"RESULT PASS={sum(r['pass'] for r in results)} FAIL={sum(not r['pass'] for r in results)}")
