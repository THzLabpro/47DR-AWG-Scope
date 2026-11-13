"""E5 board test: load tones over 40GbE, play, capture with start trigger, analyse the DAC CH2 -> ADC CH2 loopback.

  cd tools && py -X utf8 ../scripts/e5/e5_board_test.py --out ../reports/E5/run1

Needs the board initialized with build/F1/package (AWG READY). Writes waveform, capture CSV/JSON and result.json.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from awg_eth.awg import (Awg, CAP_MAX_SAMPLES, DAC_FS_HZ, ADC_FS_HZ, REG_ID, REG_DAC_FS_KSPS,  # noqa: E402
                         REG_ADC_FS_KSPS, REG_BUILD_ID, REG_CAP_TX_WORD)
from awg_eth.client import AwgEthClient  # noqa: E402

N_TX = 131072
BIN_HZ = DAC_FS_HZ / N_TX            # 74768.07 Hz: whole cycles per buffer -> seamless loop
# Channel k plays tone index KS[k] (CH2 ~ 99.97 MHz, same band as the v1 CH2 loopback test).
KS = [669, 2003, 1337, 4007, 6011, 8017, 10007, 12011]
AMPLITUDE = 0.5                       # of int16 full scale


def make_waveform(folder: Path) -> dict[int, np.ndarray]:
    folder.mkdir(parents=True, exist_ok=True)
    n = np.arange(N_TX)
    waves = {}
    for ch, k in enumerate(KS):
        x = np.round(AMPLITUDE * 32767 * np.sin(2 * np.pi * k * n / N_TX)).astype(np.int32)
        waves[ch] = x
        lo = x[0::2].astype(np.int64) & 0xFFFF
        hi = x[1::2].astype(np.int64) & 0xFFFF
        words = (hi << 16) | lo
        (folder / f"ch{ch}.hex").write_text("".join(f"{w:08X}\n" for w in words), encoding="ascii")
    meta = {"samples": N_TX, "fs_hz": DAC_FS_HZ, "nco_hz": 0, "channel_mask": 0xFF, "sample_format": 1}
    (folder / "waveform.meta").write_text("".join(f"{k} {v}\n" for k, v in meta.items()), encoding="ascii")
    return waves


def sine_fit(y: np.ndarray, f_hz: float, fs: float) -> dict[str, float]:
    """Least-squares fit of a*sin+b*cos+c at a known frequency; SINAD from the residual."""
    t = np.arange(len(y)) / fs
    a = np.column_stack([np.sin(2 * np.pi * f_hz * t), np.cos(2 * np.pi * f_hz * t), np.ones_like(t)])
    coef, *_ = np.linalg.lstsq(a, y, rcond=None)
    resid = y - a @ coef
    amp = float(np.hypot(coef[0], coef[1]))
    rms_sig = amp / np.sqrt(2)
    rms_res = float(np.sqrt(np.mean(resid ** 2)))
    return {"amplitude_lsb": amp, "dc_lsb": float(coef[2]), "residual_rms_lsb": rms_res,
            "sinad_db": float(20 * np.log10(rms_sig / rms_res)) if rms_res > 0 else float("inf"),
            "max_abs_residual_lsb": float(np.max(np.abs(resid)))}


def spectrum_peak(y: np.ndarray, fs: float) -> dict[str, float]:
    w = np.hanning(len(y))
    s = np.abs(np.fft.rfft((y - y.mean()) * w))
    k = int(np.argmax(s[1:]) + 1)
    # second-largest spur at least 20 bins away from the carrier
    mask = s.copy()
    mask[max(0, k - 20):k + 21] = 0
    mask[:3] = 0
    k2 = int(np.argmax(mask))
    return {"peak_hz": k * fs / len(y), "peak_db": float(20 * np.log10(s[k] + 1e-12)),
            "spur_hz": k2 * fs / len(y), "sfdr_db": float(20 * np.log10(s[k] / (s[k2] + 1e-12)))}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--ip", default="192.168.42.2")
    ap.add_argument("--words-per-packet", type=int, default=1024)
    ap.add_argument("--loop-channel", type=int, default=2)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    result: dict = {"tones_hz": {ch: k * BIN_HZ for ch, k in enumerate(KS)}}
    waves = make_waveform(a.out / "wave")

    with AwgEthClient(a.ip, words_per_packet=a.words_per_packet, window=8, timeout=0.2, retries=5) as client:
        awg = Awg(client)
        result["regs"] = {"id": hex(client.read32(REG_ID)), "dac_fs_ksps": client.read32(REG_DAC_FS_KSPS),
                          "adc_fs_ksps": client.read32(REG_ADC_FS_KSPS), "build_id": hex(client.read32(REG_BUILD_ID))}
        t0 = time.perf_counter()
        status = awg.load(a.out / "wave", verify=True)        # raises on any CRC mismatch
        load_s = time.perf_counter() - t0
        result["load"] = {"seconds": load_s, "bytes": 8 * N_TX * 2,
                          "mb_per_s": 8 * N_TX * 2 / load_s / 1e6, "crc_verified_channels": 8, "status": status}

        t0 = time.perf_counter()
        csv_path = awg.capture(a.out / "capture.csv", trigger="start", channel_mask=0xFF, samples=CAP_MAX_SAMPLES)
        cap_s = time.perf_counter() - t0
        result["capture"] = {"seconds_incl_readback": cap_s, "bytes": 8 * CAP_MAX_SAMPLES * 2,
                             "cap_tx_word": client.read32(REG_CAP_TX_WORD), "status_after": awg.status()}
        result["info_counters"] = client.info()

    data = np.loadtxt(csv_path, delimiter=",", dtype=np.int64)
    analysis = {}
    for ch in range(8):
        y = data[:, ch].astype(float)
        analysis[ch] = {"rms_lsb": float(np.sqrt(np.mean((y - y.mean()) ** 2))), "min": int(y.min()), "max": int(y.max()),
                        **spectrum_peak(y, ADC_FS_HZ)}
    lc = a.loop_channel
    y = data[:, lc].astype(float)
    # start trigger: skip the leading latency before the tone appears
    env = np.abs(y - np.median(y))
    onset = int(np.argmax(env > 0.2 * env.max()))
    steady = y[onset + 64:]
    f_expected = KS[lc] * BIN_HZ
    analysis["loop"] = {"channel": lc, "expected_hz": f_expected, "onset_sample": onset,
                        "fit": sine_fit(steady, f_expected, ADC_FS_HZ)}
    result["analysis"] = analysis
    (a.out / "result.json").write_text(json.dumps(result, indent=2, default=float) + "\n", encoding="utf-8")
    print(json.dumps({"regs": result["regs"], "load": {k: v for k, v in result["load"].items() if k != "status"},
                      "capture_s": cap_s, "loop": analysis["loop"],
                      "loop_spectrum": analysis[lc]}, indent=2, default=float))
    return 0


if __name__ == "__main__":
    sys.exit(main())
