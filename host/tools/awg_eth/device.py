"""The single supported hardware contract: V2.1 / D4B / F3."""
from .awg import (Awg, ABI_V21, REG_ID, REG_ABI, REG_BUILD_ID, REG_MAX_WORDS,
                  REG_DAC_FS_KSPS, REG_ADC_FS_KSPS)
from .client import AwgEthClient


def open_device(ip, port=9100, words=2048, progress=None):
    client = AwgEthClient(ip, port=port, words_per_packet=words, timeout=1.0, retries=5)
    awg = None
    try:
        client.ping()
        info = client.info()
        checks = {
            "INFO ID": (info["awg_id"], 0x41574531),
            "INFO build": (info["build_id"], 0xD4B02026),
            "ID": (client.read32(REG_ID), 0x41574732),
            "ABI": (client.read32(REG_ABI), ABI_V21),
            "build": (client.read32(REG_BUILD_ID), 0xD4B02026),
            "DAC rate": (client.read32(REG_DAC_FS_KSPS), 9800000),
            "ADC rate": (client.read32(REG_ADC_FS_KSPS), 5000000),
            "RAM": (client.read32(REG_MAX_WORDS), (10240 << 16) | 4096),
        }
        mismatch = [f"{k}: 0x{a:X} != 0x{b:X}" for k, (a, b) in checks.items() if a != b]
        if mismatch:
            raise ValueError("V2.1 firmware mismatch: " + "; ".join(mismatch))
        awg = Awg(client, progress_callback=progress)
        if awg.bulk is None:
            raise RuntimeError("V2.1 bulk port unavailable; check UDP 9101 and MTU 9000")
        if awg._bulk_stat.get("build_id") != 0xD4B02026:
            raise ValueError("V2.1 bulk firmware mismatch")
        info.update(ip=ip, port=port, build_id_reg=0xD4B02026, status=awg.status())
        return client, awg, info
    except BaseException:
        if awg:
            awg.close()
        client.close()
        raise
