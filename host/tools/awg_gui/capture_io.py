"""Read saved raw captures without opening any device connection."""
import json
from pathlib import Path
import time
import numpy as np
from . import measure


def load_capture(path, window="blackmanharris"):
    path = Path(path)
    meta = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
    channels = meta["channels"]
    if (meta.get("format") != "47dr-raw-adc-v2" or meta.get("fs_hz") != measure.ADC_FS_HZ
            or not channels or len(set(channels)) != len(channels)
            or any(type(ch) is not int or not 0 <= ch < 8 for ch in channels)):
        raise ValueError("采集元数据格式、采样率或通道无效")
    with path.open(encoding="utf-8-sig") as stream:
        header = stream.readline().strip()
    if header != ",".join(f"ADC{ch}" for ch in channels):
        raise ValueError("CSV 通道表头与元数据不一致")
    data = np.loadtxt(path, delimiter=",", skiprows=1, ndmin=2)
    if (data.shape != (meta["samples"], len(channels)) or not np.isfinite(data).all()
            or np.any(data < -32768) or np.any(data > 32764) or np.any(data % 4)):
        raise ValueError("CSV 点数或 14 bit 左对齐码值无效")
    samples = {ch: data[:, i].astype(np.int16) for i, ch in enumerate(channels)}
    spectra, measurements = {}, {}
    t0 = time.perf_counter()
    for ch, y in samples.items():
        f, db, rbw, measurements[ch] = measure.analyze(y[:262144], measure.ADC_FS_HZ, window)
        spectra[ch] = (f, db)
    return dict(samples=samples, spectra=spectra, meas=measurements, rbw_hz=rbw,
                count=meta["samples"], trigger=meta.get("trigger", "manual"),
                cap_tx_word=meta.get("cap_tx_word", 0), window=window, offline=True,
                read_s=0, capture_s=0, total_s=time.perf_counter()-t0,
                process_s=time.perf_counter()-t0, emit_t=time.perf_counter(),
                analysis_points=min(meta["samples"], 262144), analysis_limited=meta["samples"] > 262144)
