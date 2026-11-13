"""Standard waveforms for the 9.8 GS/s DAC, quantization to the 14-bit DAC and packing for awg_eth.

All generators return float64 arrays in full-scale units (+-1.0 = DAC full scale). Periodic waveforms
are snapped to a whole number of cycles in the buffer so the hardware loop has no seam.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

DAC_FS_HZ = 9_800_000_000
TX_MAX_SAMPLES = 131072
SAMPLE_QUANTUM = 32          # TX_LENGTH is in 32-sample URAM words
DAC_CODE_MAX = 8191          # 14-bit two's complement
DAC_CODE_MIN = -8192

KINDS = ("sine", "square", "triangle", "ramp", "pulse", "noise", "multitone", "chirp", "dc")
KIND_LABELS = {
    "sine": "正弦", "square": "方波", "triangle": "三角波", "ramp": "锯齿波", "pulse": "脉冲",
    "noise": "高斯噪声", "multitone": "多音", "chirp": "线性扫频", "dc": "直流",
}


@dataclass
class WaveSpec:
    kind: str = "sine"
    freq_hz: float = 100e6
    amp_dbfs: float = -6.0          # peak amplitude relative to full scale
    phase_deg: float = 0.0
    offset_fs: float = 0.0          # DC offset in full-scale units
    duty: float = 0.5               # square / pulse
    tones: int = 8                  # multitone
    spacing_hz: float = 50e6        # multitone
    stop_hz: float = 1e9            # chirp
    samples: int = TX_MAX_SAMPLES
    seed: int = 1                   # noise / multitone phases
    extra: dict = field(default_factory=dict)


def valid_length(samples: int) -> int:
    """Clamp to 32..131072 and round down to a multiple of 32."""
    samples = int(samples)
    samples = max(SAMPLE_QUANTUM, min(TX_MAX_SAMPLES, samples))
    return samples - samples % SAMPLE_QUANTUM


def snap_cycles(freq_hz: float, samples: int, fs_hz: float = DAC_FS_HZ) -> tuple[int, float]:
    """Whole cycles per buffer closest to freq_hz (at least 1, below Nyquist); returns (cycles, actual Hz)."""
    cycles = int(round(freq_hz * samples / fs_hz))
    cycles = max(1, min(cycles, samples // 2 - 1))
    return cycles, cycles * fs_hz / samples


def generate(spec: WaveSpec, fs_hz: float = DAC_FS_HZ) -> tuple[np.ndarray, dict]:
    """Return (waveform in FS units, info dict with actual frequencies, peak and clipping)."""
    n = valid_length(spec.samples)
    if spec.kind not in KINDS:
        raise ValueError(f"unknown waveform kind {spec.kind!r}")
    amp = 10.0 ** (spec.amp_dbfs / 20.0)
    idx = np.arange(n, dtype=np.float64)
    phase = np.deg2rad(spec.phase_deg)
    info: dict = {"samples": n}

    if spec.kind in ("sine", "square", "triangle", "ramp", "pulse"):
        cycles, f_act = snap_cycles(spec.freq_hz, n, fs_hz)
        info["freq_hz"] = f_act
        frac = (idx * cycles / n + phase / (2 * np.pi)) % 1.0
        duty = min(max(spec.duty, 0.001), 0.999)
        if spec.kind == "sine":
            y = np.sin(2 * np.pi * frac)
        elif spec.kind == "square":
            y = np.where(frac < duty, 1.0, -1.0)
        elif spec.kind == "triangle":
            y = 1.0 - 4.0 * np.abs(frac - 0.5)
        elif spec.kind == "ramp":
            y = 2.0 * frac - 1.0
        else:
            y = np.where(frac < duty, 1.0, 0.0)
        y = amp * y
    elif spec.kind == "noise":
        rng = np.random.default_rng(spec.seed)
        y = np.clip(rng.standard_normal(n) * amp / 4.0, -amp, amp)     # crest factor 4 -> peak ~ amp
        info["rms_fs"] = float(np.sqrt(np.mean(y ** 2)))
    elif spec.kind == "multitone":
        count = max(1, int(spec.tones))
        base, _ = snap_cycles(spec.freq_hz, n, fs_hz)
        step = max(1, int(round(spec.spacing_hz * n / fs_hz)))
        cycles = base + step * np.arange(count)
        cycles = cycles[cycles < n // 2]
        k = np.arange(len(cycles))
        phases = np.pi * k * (k + 1) / max(len(cycles), 1)                 # Schroeder: low crest factor
        y = np.zeros(n)
        for c, p in zip(cycles, phases):
            y += np.sin(2 * np.pi * c * idx / n + p + phase)
        y *= amp / max(np.max(np.abs(y)), 1e-12)
        info["freqs_hz"] = [float(c * fs_hz / n) for c in cycles]
    elif spec.kind == "chirp":
        f0 = spec.freq_hz
        f1 = spec.stop_hz
        # Make the total phase a whole number of cycles so the loop seam is phase-continuous.
        cycles = max(1, int(round((f0 + f1) / 2 * n / fs_hz)))
        f1 = 2 * cycles * fs_hz / n - f0
        t = idx / fs_hz
        duration = n / fs_hz
        y = amp * np.sin(2 * np.pi * (f0 * t + (f1 - f0) * t * t / (2 * duration)) + phase)
        info["start_hz"] = float(f0)
        info["stop_hz"] = float(f1)
    else:
        y = np.full(n, amp)

    y = y + spec.offset_fs
    info["clipped"] = bool(np.any(np.abs(y) > 1.0))
    y = np.clip(y, -1.0, 1.0)
    info["peak_fs"] = float(np.max(np.abs(y))) if n else 0.0
    return y, info


def fit_length(y: np.ndarray, mode: str = "truncate") -> tuple[np.ndarray, str]:
    """Fit an arbitrary waveform to the TX length rules. mode: truncate | pad."""
    y = np.asarray(y, dtype=np.float64).ravel()
    note = ""
    if len(y) > TX_MAX_SAMPLES:
        y = y[:TX_MAX_SAMPLES]
        note = f"超过 {TX_MAX_SAMPLES} 点，已截断"
    rem = len(y) % SAMPLE_QUANTUM
    if rem or len(y) < SAMPLE_QUANTUM:
        if mode == "pad" or len(y) < SAMPLE_QUANTUM:
            pad = (SAMPLE_QUANTUM - rem) if rem else SAMPLE_QUANTUM - len(y)
            y = np.concatenate([y, np.zeros(pad)])
            note = (note + "；" if note else "") + f"补零 {pad} 点到 32 的倍数"
        else:
            y = y[: len(y) - rem]
            note = (note + "；" if note else "") + f"截掉末尾 {rem} 点到 32 的倍数"
    return y, note


def quantize(y: np.ndarray) -> np.ndarray:
    """FS float -> int16 container with the 14-bit DAC code left-aligned (low 2 bits zero)."""
    codes = np.clip(np.round(np.asarray(y) * DAC_CODE_MAX), DAC_CODE_MIN, DAC_CODE_MAX).astype(np.int16)
    return (codes.astype(np.int32) * 4).astype(np.int16)


def pack_words(samples_i16: np.ndarray) -> list[int]:
    """int16 samples -> list of 32-bit words, earlier sample in bits [15:0] (doc/01 §3)."""
    data = np.ascontiguousarray(np.asarray(samples_i16, dtype="<i2"))
    if len(data) % 2:
        raise ValueError("sample count must be even")
    return data.view("<u4").tolist()


def unpack_pairs(pairs) -> np.ndarray:
    """Packed capture pairs (list of uint32) -> int16 samples in time order."""
    return np.asarray(pairs, dtype="<u4").view("<i2").copy()
