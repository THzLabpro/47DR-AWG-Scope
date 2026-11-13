"""Spectrum and single-tone measurements for 14-bit ADC captures (int16 containers, FS = 32768)."""
from __future__ import annotations

import numpy as np

ADC_FS_HZ = 5_000_000_000
FULL_SCALE = 32768.0

# window name -> (generator, main-lobe half width in bins)
_WINDOWS = {
    "rect": (lambda n: np.ones(n), 1),
    "hann": (np.hanning, 3),
    "blackmanharris": (None, 5),
    "flattop": (None, 6),
}
WINDOW_LABELS = {"blackmanharris": "Blackman-Harris", "hann": "Hann", "flattop": "平顶", "rect": "矩形"}


def window(name: str, n: int) -> np.ndarray:
    if name == "blackmanharris":
        k = np.arange(n) / max(n - 1, 1)
        a = (0.35875, 0.48829, 0.14128, 0.01168)
        return a[0] - a[1] * np.cos(2 * np.pi * k) + a[2] * np.cos(4 * np.pi * k) - a[3] * np.cos(6 * np.pi * k)
    if name == "flattop":
        k = np.arange(n) / max(n - 1, 1)
        a = (0.21557895, 0.41663158, 0.277263158, 0.083578947, 0.006947368)
        return (a[0] - a[1] * np.cos(2 * np.pi * k) + a[2] * np.cos(4 * np.pi * k)
                - a[3] * np.cos(6 * np.pi * k) + a[4] * np.cos(8 * np.pi * k))
    gen, _ = _WINDOWS[name]
    return gen(n)


def spectrum(samples: np.ndarray, fs_hz: float = ADC_FS_HZ, window_name: str = "blackmanharris"):
    """Return (freq_hz, dbfs, rbw_hz). dBFS: a full-scale sine reads 0 dBFS."""
    y = np.asarray(samples, dtype=np.float64)
    n = len(y)
    w = window(window_name, n)
    spec = np.fft.rfft((y - y.mean()) * w)
    mag = np.abs(spec) / (np.sum(w) / 2.0) / FULL_SCALE
    dbfs = 20.0 * np.log10(np.maximum(mag, 1e-12))
    enbw = n * np.sum(w ** 2) / np.sum(w) ** 2
    freqs = np.fft.rfftfreq(n, 1.0 / fs_hz)
    return freqs, dbfs, enbw * fs_hz / n


def measure(samples: np.ndarray, fs_hz: float = ADC_FS_HZ, window_name: str = "blackmanharris") -> dict:
    """Single-tone metrics: frequency, Vpp, RMS, peak dBFS, SFDR, SINAD, SNR (harmonics 2..5 excluded)."""
    y = np.asarray(samples, dtype=np.float64)
    n = len(y)
    out = {"vpp_lsb": float(y.max() - y.min()) if n else 0.0,
           "rms_lsb": float(np.sqrt(np.mean((y - y.mean()) ** 2))) if n else 0.0,
           "mean_lsb": float(y.mean()) if n else 0.0}
    if n < 64:
        return out
    w = window(window_name, n)
    half = _WINDOWS[window_name][1]
    power = np.abs(np.fft.rfft((y - y.mean()) * w)) ** 2
    power[: half + 1] = 0.0                                   # DC
    k = int(np.argmax(power))
    if power[k] <= 0:
        return out
    # Parabolic interpolation on log magnitude for a sub-bin frequency estimate.
    if 0 < k < len(power) - 1 and power[k - 1] > 0 and power[k + 1] > 0:
        a, b, c = np.log(power[k - 1]), np.log(power[k]), np.log(power[k + 1])
        delta = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0.0
    else:
        delta = 0.0
    out["freq_hz"] = float((k + delta) * fs_hz / n)

    def band(center):
        lo, hi = max(center - half, 0), min(center + half + 1, len(power))
        return lo, hi

    lo, hi = band(k)
    sig = float(power[lo:hi].sum())
    rest = power.copy()
    rest[lo:hi] = 0.0
    total_nd = float(rest.sum())
    harm = 0.0
    for h in range(2, 6):
        bin_h = int(round(k * h)) % n
        if bin_h > n // 2:
            bin_h = n - bin_h                                  # aliased harmonic
        hl, hh = band(bin_h)
        harm += float(rest[hl:hh].sum())
    noise = max(total_nd - harm, 1e-30)
    # Tone amplitude from main-lobe energy (Parseval), free of window scalloping:
    # one-sided sum |X|^2 over the lobe = N * A^2/4 * sum(w^2).
    amp = np.sqrt(4.0 * sig / (n * np.sum(w ** 2)))
    out["amp_lsb"] = float(amp)
    out["peak_dbfs"] = float(20 * np.log10(max(amp / FULL_SCALE, 1e-12)))
    out["sinad_db"] = float(10 * np.log10(sig / max(total_nd, 1e-30)))
    out["snr_db"] = float(10 * np.log10(sig / noise))
    spur = float(rest.max())
    out["sfdr_dbc"] = float(10 * np.log10(power[k] / max(spur, 1e-30)))
    return out
