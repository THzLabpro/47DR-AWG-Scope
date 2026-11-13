"""Run only via Vitis 2025.2: vitis -s software/build/build_vitis_bsp.py.
Copied from D:/ClaudeProject/rf_udp_link_v3/firmware/build_vitis.py (read-only source) for rf_awg_eth_v1 F1.
Creates a standalone (SDT) BSP from the C18 xsa; no debug session, no hardware connection.
Adapted from D:/ClaudeProject/rf_udp_link_v2/firmware/build_vitis.py (read-only source).

C20 fix (encoding): on a Chinese Windows (cp936) vitis-server.bat prints, as its FIRST stdout line,
the localized cmd.exe message for the missing
  %XILINX_VITIS%/tps/win64/lopper-1.1.0-packages/min_sdk/environment-setup.bat
(bytes 0xCF 0xB5 0xCD 0xB3 0xD5 0xD2 ... = "system cannot find the path specified" in cp936).
Vitis cli/vitis/_server.py:136 does `str(line, 'utf-8')` on every server stdout line until it finds
"serverPort", so create_client() dies with "'utf-8' codec can't decode byte 0xd5 in position 4".
The message itself is harmless.  We wrap subprocess.Popen so the server's stdout lines are decoded
leniently (utf-8, else cp936, else replace) and re-encoded as utf-8 before the Vitis client sees them.
"""
import json
import os
import subprocess
from pathlib import Path


class _Utf8Lines:
    """Proxy for a bytes pipe: readline()/read() always return utf-8 decodable bytes."""

    def __init__(self, pipe):
        self._pipe = pipe

    @staticmethod
    def _fix(raw):
        try:
            raw.decode("utf-8")
            return raw
        except UnicodeDecodeError:
            for codec in ("cp936", "cp1252"):
                try:
                    return raw.decode(codec).encode("utf-8")
                except UnicodeDecodeError:
                    pass
            return raw.decode("utf-8", errors="replace").encode("utf-8")

    def readline(self, *args):
        return self._fix(self._pipe.readline(*args))

    def read(self, *args):
        return self._fix(self._pipe.read(*args))

    def __getattr__(self, name):
        return getattr(self._pipe, name)


_RealPopen = subprocess.Popen


class _LenientPopen(_RealPopen):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if (self.stdout is not None and kwargs.get("stdout") == subprocess.PIPE and not kwargs.get("text")
                and not kwargs.get("universal_newlines") and not kwargs.get("encoding")):
            self.stdout = _Utf8Lines(self.stdout)


subprocess.Popen = _LenientPopen

import vitis  # noqa: E402  (must be imported after the Popen patch is installed)

request = json.loads(Path(os.environ["AWG_FW_REQUEST"]).read_text(encoding="utf-8-sig"))
client = vitis.create_client(workspace=request["workspace"])
try:
    platform = client.create_platform_component(
        name="awg", hw_design=request["xsa"], cpu="psu_cortexa53_0",
        os="standalone", domain_name="a53", architecture="64-bit", compiler="gcc",
        no_boot_bsp=True, generate_dtb=False)
    platform.build()
    Path(request["workspace"], "bsp.ok").write_text("Vitis BSP built\n", encoding="ascii")
finally:
    vitis.dispose()
