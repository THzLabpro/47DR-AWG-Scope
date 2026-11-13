"""E5: repeat start-triggered captures of the already loaded tones and locate residual bursts on the loop channel.
Run from tools/:  py -X utf8 ../scripts/e5/e5_repeat_capture.py --out ../reports/E5/repeat --runs 3 [--trigger start|manual]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tools"))
sys.path.insert(0, str(HERE))
import e5_board_test as t  # noqa: E402
from awg_eth.awg import Awg, CAP_MAX_SAMPLES  # noqa: E402
from awg_eth.client import AwgEthClient  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--out", type=Path, required=True)
ap.add_argument("--runs", type=int, default=3)
ap.add_argument("--channel", type=int, default=0)
ap.add_argument("--trigger", default="start")
a = ap.parse_args()
a.out.mkdir(parents=True, exist_ok=True)
fs = 5e9
f = t.KS[a.channel] * t.BIN_HZ
summary = []
with AwgEthClient("192.168.42.2", words_per_packet=256, window=8, timeout=0.2, retries=5) as c:
    awg = Awg(c)
    for run in range(a.runs):
        path = awg.capture(a.out / f"cap{run}.csv", trigger=a.trigger, channel_mask=1 << a.channel, samples=CAP_MAX_SAMPLES)
        y = np.loadtxt(path, dtype=float)
        env = np.abs(y)
        onset = int(np.argmax(env > 0.2 * env.max())) if a.trigger == "start" else 0
        seg = y[onset + 64:]
        tt = (np.arange(len(seg)) + onset + 64) / fs
        A = np.column_stack([np.sin(2 * np.pi * f * tt), np.cos(2 * np.pi * f * tt), np.ones_like(tt)])
        q, *_ = np.linalg.lstsq(A, seg, rcond=None)
        r = seg - A @ q
        rb = np.sqrt(np.mean(r[:len(r) // 24 * 24].reshape(-1, 24) ** 2, axis=1))
        bad = (np.where(rb > 4 * np.median(rb))[0] * 24 + onset + 64).tolist()
        clusters = []
        for b in bad:
            if clusters and b - clusters[-1][1] <= 240:
                clusters[-1][1] = b
            else:
                clusters.append([b, b])
        item = {"run": run, "onset": onset, "amp": float(np.hypot(q[0], q[1])), "phase": float(np.arctan2(q[1], q[0])),
                "resid_rms": float(r.std()), "median_block_rms": float(np.median(rb)),
                "sinad_db": float(20 * np.log10(np.hypot(q[0], q[1]) / np.sqrt(2) / r.std())),
                "burst_clusters": [(int(x), int(y_) + 24) for x, y_ in clusters]}
        summary.append(item)
        print(json.dumps(item), flush=True)
    awg.stop()
(a.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
