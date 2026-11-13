"""Tests for script_api/python/awg47dr.py against the loopback FPGA emulator (no hardware)."""
import ast
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "python"))
sys.path.insert(0, str(HERE.parents[1] / "tools"))

import awg47dr as api  # noqa: E402
from awg_eth.fpga_emu import FpgaEmulator  # noqa: E402
from awg_gui import measure as gui_measure, waveforms as gui_wf  # noqa: E402

FUNCS = ["awg_generate_waveform", "awg_scale_waveform", "awg_download", "awg_output", "awg_status",
         "dso_capture", "dso_spectrum", "dso_measure"]


def test_each_function_is_a_single_body():
    """User rule: every function stands alone — no nested defs/lambdas, no calls to the other API functions."""
    tree = ast.parse((HERE.parent / "python" / "awg47dr.py").read_text(encoding="utf-8"))
    top = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
    assert [f.name for f in top] == FUNCS
    for f in top:
        for node in ast.walk(f):
            assert not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)) or node is f, f.name
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                assert node.func.id not in FUNCS, f"{f.name} calls {node.func.id}"
        assert ast.get_docstring(f) and len(ast.get_docstring(f)) > 100


def test_generate_matches_gui_and_scale():
    for kind in ("sine", "square", "triangle", "ramp", "pulse", "multitone", "chirp", "dc"):
        w, info = api.awg_generate_waveform(kind, freq_hz=123e6, samples=65536)
        ref, rinfo = gui_wf.generate(gui_wf.WaveSpec(kind=kind, freq_hz=123e6, amp_dbfs=0.0, samples=65536))
        if kind == "multitone":
            ref = ref / np.max(np.abs(ref))
        assert w.shape == (65536,) and abs(np.max(np.abs(w)) - 1.0) < 1e-9, kind
        assert np.allclose(w, ref, atol=1e-9), kind
        if "freq_hz" in rinfo:
            assert info["freq_hz"] == rinfo["freq_hz"]
    codes, sinfo = api.awg_scale_waveform(w := api.awg_generate_waveform("sine", 100e6, 131072)[0], amp_dbfs=-6.0)
    ref = gui_wf.quantize(gui_wf.generate(gui_wf.WaveSpec(kind="sine", freq_hz=100e6, amp_dbfs=-6.0))[0])
    assert codes.dtype == np.int16 and np.array_equal(codes, ref)
    assert np.all(codes % 4 == 0) and abs(sinfo["peak_dbfs"] + 6.0) < 0.01 and sinfo["clipped"] == 0
    with pytest.raises(ValueError):
        api.awg_scale_waveform(np.ones(100))
    c2, i2 = api.awg_scale_waveform(np.ones(100) * 3.0, amp_dbfs=0.0, mode="gain", fit="pad")
    assert c2.size == 128 and i2["clipped"] == 100 and c2.max() == 8191 * 4


def test_spectrum_and_measure_match_gui():
    x = gui_wf.quantize(gui_wf.generate(gui_wf.WaveSpec(kind="sine", freq_hz=100e6, amp_dbfs=-3.0, samples=65520))[0])
    noisy = (x + np.random.default_rng(3).normal(0, 20, x.size)).astype(np.int16)
    for win in ("blackmanharris", "hann", "flattop", "rect"):
        f, d, r = api.dso_spectrum(noisy, 5e9, win)
        f2, d2, r2 = gui_measure.spectrum(noisy, 5e9, win)
        assert np.allclose(f, f2) and np.allclose(d, d2) and abs(r - r2) < 1e-6
        m = api.dso_measure(noisy, 5e9, win)
        m2 = gui_measure.measure(noisy, 5e9, win)
        for key in ("freq_hz", "peak_dbfs", "sfdr_dbc", "sinad_db", "snr_db", "vpp_lsb", "rms_lsb"):
            assert abs(m[key] - m2[key]) < 1e-9, (win, key)


@pytest.mark.parametrize("drop", [0.0, 0.1])
def test_full_flow_on_emulator(drop):
    with FpgaEmulator(loopback=True, drop_rate=drop, duplicate_rate=drop, seed=11).start() as emu:
        ip, port = "127.0.0.1", emu.port
        st = api.awg_status(ip, port=port, timeout_s=0.1)
        assert st["id"] == "0x41574732" and st["ps_ready"]
        waves = []
        for ch in range(8):
            w, _ = api.awg_generate_waveform("sine", freq_hz=50e6 * (ch + 1), samples=131072)
            waves.append(api.awg_scale_waveform(w, amp_dbfs=-6.0 - ch)[0])
        res = api.awg_download(ip, np.vstack(waves), port=port, timeout_s=0.1, words_per_packet=512)
        assert res["channels"] == list(range(8)) and res["mask"] == 0xFF and len(res["crc"]) == 8
        assert api.awg_status(ip, port=port, timeout_s=0.1)["running"]
        assert api.awg_output(ip, run=True, port=port, timeout_s=0.1)["running"]       # Run while running: no error
        data, info = api.dso_capture(ip, channels=[0, 3, 7], samples=65520, trigger="start", port=port,
                                     timeout_s=0.1, words_per_packet=512)
        assert data.shape == (3, 65520) and info["samples"] == 65520
        for row, ch in enumerate([0, 3, 7]):
            m = api.dso_measure(data[row])
            cycles = int(round(50e6 * (ch + 1) * 131072 / 9.8e9))
            assert abs(m["freq_hz"] - cycles * 5e9 / 131072) < 50e3          # emulator loops TX 1:1 into ADC
            assert abs(m["peak_dbfs"] - (-6.0 - ch)) < 0.3
        manual, _ = api.dso_capture(ip, channels=[1], samples=240, port=port, timeout_s=0.1)
        assert manual.shape == (1, 240)
        assert not api.awg_output(ip, run=False, port=port, timeout_s=0.1)["running"]


def test_errors():
    with pytest.raises(TypeError):
        api.awg_download("127.0.0.1", np.zeros(128), port=1)          # float: must scale first
    with pytest.raises(ValueError):
        api.awg_download("127.0.0.1", np.zeros(100, np.int16), port=1)
    with pytest.raises(ValueError):
        api.dso_capture("127.0.0.1", samples=100, port=1)
    with pytest.raises(TimeoutError):
        api.awg_status("127.0.0.1", port=9, timeout_s=0.01, retries=1)       # nobody listening
