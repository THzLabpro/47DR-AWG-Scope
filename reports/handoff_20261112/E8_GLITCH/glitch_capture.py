"""E8: capture full 65520-sample ADC0 records on the board and characterise glitches.

Usage: py -X utf8 glitch_capture.py <tag> <freq_MHz|off> <amp_dbfs> <trigger> <count> [channels_on_mask]
Saves <tag>.npz (raw int16 captures) and prints a per-capture summary + aggregate.
"""
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "script_api" / "python"))
import awg47dr as api  # noqa: E402

IP = "192.168.42.2"
FS = 5e9


def sine_fit(x, f0):
    """4-parameter LS sine fit (Gauss-Newton on frequency). Returns fit, residual, params."""
    n = x.size
    t = np.arange(n) / FS
    f = f0
    for _ in range(8):
        c, s = np.cos(2 * np.pi * f * t), np.sin(2 * np.pi * f * t)
        a_mat = np.column_stack([c, s, np.ones(n)])
        coef, *_ = np.linalg.lstsq(a_mat, x, rcond=None)
        a, b, d = coef
        # derivative wrt f
        dfc = 2 * np.pi * t * (-a * s + b * c)
        r = x - a_mat @ coef
        step = np.dot(dfc, r) / max(np.dot(dfc, dfc), 1e-30)
        f += step
        if abs(step) < 1e-3:
            break
    c, s = np.cos(2 * np.pi * f * t), np.sin(2 * np.pi * f * t)
    a_mat = np.column_stack([c, s, np.ones(n)])
    coef, *_ = np.linalg.lstsq(a_mat, x, rcond=None)
    fit = a_mat @ coef
    return fit, x - fit, {"freq_hz": f, "amp": float(np.hypot(coef[0], coef[1])), "dc": float(coef[2])}


def analyse(x16):
    x = x16.astype(np.float64) / 4.0                      # 14-bit ADC codes
    m = api.dso_measure(x16)
    if m.get("peak_dbfs", -200) > -40:
        fit, r, p = sine_fit(x, m["freq_hz"])
    else:                                                  # no tone: residual = signal minus mean
        fit, r, p = np.full_like(x, x.mean()), x - x.mean(), {"freq_hz": 0.0, "amp": 0.0, "dc": float(x.mean())}
    sigma = 1.4826 * np.median(np.abs(r - np.median(r)))
    thr = max(8 * sigma, 40.0)                             # 40 LSB14 floor
    idx = np.flatnonzero(np.abs(r) > thr)
    # group consecutive outliers into events
    events = []
    if idx.size:
        start = prev = idx[0]
        for i in list(idx[1:]) + [None]:
            if i is not None and i <= prev + 2:
                prev = i
                continue
            seg = np.arange(start, prev + 1)
            k = seg[np.argmax(np.abs(r[seg]))]
            events.append({"index": int(k), "width": int(prev - start + 1), "resid_lsb": float(r[k]),
                           "code": float(x[k]), "fit": float(fit[k]), "mod2": int(k % 2), "mod12": int(k % 12),
                           "mod24": int(k % 24)})
            if i is not None:
                start = prev = i
    # residual RMS envelope in 1024-sample windows (bursty interference shows up here)
    win = 1024
    env = np.sqrt(np.mean(r[: (r.size // win) * win].reshape(-1, win) ** 2, axis=1))
    return {"sigma_lsb": float(sigma), "thr_lsb": float(thr), "events": events, "fit": p, "meas": m,
            "env_min": float(env.min()), "env_max": float(env.max()), "env_med": float(np.median(env))}


def main():
    tag, freq, amp, trig, count = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], int(sys.argv[5])
    on_mask = int(sys.argv[6], 0) if len(sys.argv) > 6 else 0x01
    if freq == "off":
        api.awg_output(IP, run=False)
    else:
        w, info = api.awg_generate_waveform("sine", freq_hz=float(freq) * 1e6, samples=131072)
        codes, _ = api.awg_scale_waveform(w, amp_dbfs=amp)
        chans = [c for c in range(8) if on_mask & (1 << c)]
        api.awg_download(IP, np.vstack([codes] * len(chans)), channels=chans)
    caps, results = [], []
    for k in range(count):
        d, ci = api.dso_capture(IP, channels=[0], samples=65520, trigger=trig if freq != "off" else "manual")
        caps.append(d[0])
        res = analyse(d[0])
        results.append(res)
        ev = res["events"]
        big = max((abs(e["resid_lsb"]) for e in ev), default=0.0)
        print(f"{tag} #{k:02d}: sigma={res['sigma_lsb']:.1f} LSB14  events={len(ev):3d}  max|resid|={big:7.1f}  "
              f"env(min/med/max)={res['env_min']:.1f}/{res['env_med']:.1f}/{res['env_max']:.1f}  "
              f"f={res['fit']['freq_hz']/1e6:.5f} MHz amp={res['fit']['amp']:.1f}")
    np.savez_compressed(HERE / f"{tag}.npz", caps=np.array(caps, dtype=np.int16))
    (HERE / f"{tag}.json").write_text(json.dumps(results, indent=1, ensure_ascii=False, default=float), encoding="utf-8")
    allev = [e for r in results for e in r["events"]]
    print(f"{tag} TOTAL: {len(allev)} events in {count} captures ({count*65520} samples)")
    if allev:
        for key in ("mod2", "mod12", "mod24"):
            hist = np.bincount([e[key] for e in allev], minlength={"mod2": 2, "mod12": 12, "mod24": 24}[key])
            print(f"  {key} histogram: {hist.tolist()}")
        widths = np.bincount([min(e["width"], 9) for e in allev], minlength=10)
        print(f"  width histogram (1..9+): {widths[1:].tolist()}")
        top = sorted(allev, key=lambda e: -abs(e["resid_lsb"]))[:12]
        for e in top:
            print("  ", {k: (round(v, 1) if isinstance(v, float) else v) for k, v in e.items()})


if __name__ == "__main__":
    main()
