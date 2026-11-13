"""Run the MATLAB script API against the emulator and cross-check its numbers with awg47dr.py.

Skipped when MATLAB is not installed. Set AWG_MATLAB to matlab.exe to override the default path.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
API = HERE.parent
sys.path.insert(0, str(API / "python"))
sys.path.insert(0, str(API.parent / "tools"))

import awg47dr as api  # noqa: E402
from awg_eth.fpga_emu import FpgaEmulator  # noqa: E402

MATLAB = os.environ.get("AWG_MATLAB", r"D:\Program Files\MATLAB\R2023b\bin\matlab.exe")
FUNCS = ["awg_generate_waveform", "awg_scale_waveform", "awg_download", "awg_output", "awg_status",
         "dso_capture", "dso_spectrum", "dso_measure"]


def test_matlab_files_are_single_bodies():
    """User rule: one function per file, no local/nested functions, no anonymous functions, rich comments."""
    for name in FUNCS:
        text = (API / "matlab" / f"{name}.m").read_text(encoding="utf-8")
        code = [ln.split("%")[0] for ln in text.splitlines()]
        assert sum(1 for ln in code if re.match(r"\s*function\b", ln)) == 1, name
        assert not any("@(" in ln for ln in code), name
        assert not any(re.search(r"\b%s\s*\(" % other, ln) for ln in code[1:] for other in FUNCS), name
        comments = sum(1 for ln in text.splitlines() if ln.strip().startswith("%"))
        assert comments >= 15, (name, comments)


@pytest.mark.skipif(not Path(MATLAB).is_file(), reason="MATLAB not installed")
def test_matlab_api_on_emulator(tmp_path):
    with FpgaEmulator(loopback=True, drop_rate=0.05, duplicate_rate=0.05, seed=5).start() as emu:
        cmd = (f"addpath('{(API / 'matlab').as_posix()}'); addpath('{HERE.as_posix()}'); "
               f"test_matlab_api({emu.port}, '{tmp_path.as_posix()}')")
        proc = subprocess.run([MATLAB, "-batch", cmd], capture_output=True, text=True, timeout=900,
                              encoding="utf-8", errors="replace")
    print(proc.stdout[-3000:], proc.stderr[-2000:])
    assert proc.returncode == 0 and "MATLAB_API_TEST PASS" in proc.stdout

    res = json.loads((tmp_path / "results.json").read_text(encoding="utf-8"))
    # MATLAB waveform/scale == Python waveform/scale (MATLAB round() is half-away-from-zero, numpy half-even:
    # at most 1 code step = 4 LSB difference on exact .5 ties)
    for kind in ("sine", "square", "triangle", "ramp", "pulse", "multitone", "chirp", "dc"):
        m_codes = np.fromfile(tmp_path / f"gen_{kind}.bin", dtype="<i2")
        p_codes, _ = api.awg_scale_waveform(api.awg_generate_waveform(kind, 123e6, 65536)[0], amp_dbfs=-6.0)
        assert m_codes.size == p_codes.size and np.max(np.abs(m_codes.astype(int) - p_codes)) <= 4, kind
    # MATLAB measurements on the captured data == Python measurements on the same data
    data = np.fromfile(tmp_path / "capture.bin", dtype="<i2").reshape(3, 65520)
    for row in range(3):
        p = api.dso_measure(data[row])
        m = res["measure"][row]
        for key in ("freq_hz", "peak_dbfs", "sfdr_dbc", "sinad_db", "snr_db", "vpp_lsb", "rms_lsb", "enob_bits"):
            assert abs(p[key] - m[key]) < 1e-6 * max(1.0, abs(p[key])), (row, key, p[key], m[key])
    f, db, rbw = api.dso_spectrum(data[0])
    assert res["spectrum"]["n"] == f.size and abs(res["spectrum"]["peak_db"] - db.max()) < 1e-9
    assert abs(res["spectrum"]["rbw"] - rbw) < 1e-6
