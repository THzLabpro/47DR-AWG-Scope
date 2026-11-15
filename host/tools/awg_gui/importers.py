"""Waveform file import: .npy, .csv/.txt, .mat (v5/v7), and the v1 hex directory (waveform.meta + chN.hex)."""
from __future__ import annotations

from pathlib import Path

import numpy as np

SCALE_MODES = {"auto": "自动", "peak": "归一化到峰值", "int16": "按 int16 码值", "fs": "按满量程(±1)"}


def _columns(array: np.ndarray, name: str) -> dict[str, np.ndarray]:
    a = np.asarray(array)
    if np.iscomplexobj(a):
        a = a.real                                   # 1X real DAC: real part only
    a = np.squeeze(a)
    if a.ndim == 0 or a.size < 2:
        return {}
    if a.ndim == 1:
        return {name: a.astype(np.float64)}
    if a.ndim == 2:
        if a.shape[0] < a.shape[1]:
            a = a.T                                  # samples along rows
        return {f"{name}[:,{c}]": a[:, c].astype(np.float64) for c in range(a.shape[1])}
    return {}


def load_file(path: str | Path) -> dict[str, np.ndarray]:
    """Return {label: 1-D float array}. Labels name the variable/column each array came from."""
    p = Path(path)
    if p.is_dir():
        return _load_hex_dir(p)
    suffix = p.suffix.lower()
    if suffix == ".npy":
        return _columns(np.load(p, allow_pickle=False), p.stem)
    if suffix in (".csv", ".txt", ".dat"):
        text = p.read_text(encoding="utf-8", errors="replace")
        delimiter = "," if "," in text.splitlines()[0] else None
        data = np.loadtxt(p, delimiter=delimiter, comments="#", ndmin=1)
        return _columns(data, p.stem)
    if suffix == ".mat":
        try:
            from scipy.io import loadmat
        except ImportError as exc:  # pragma: no cover
            raise RuntimeError("读取 .mat 需要 scipy") from exc
        try:
            mat = loadmat(p, squeeze_me=False)
        except NotImplementedError as exc:
            raise RuntimeError("这是 MATLAB v7.3 (HDF5) 文件，请在 MATLAB 用 save(...,'-v7') 另存") from exc
        out: dict[str, np.ndarray] = {}
        for key, value in mat.items():
            if key.startswith("__") or not isinstance(value, np.ndarray) or value.dtype.kind not in "iufcb":
                continue
            out.update(_columns(value, key))
        return out
    raise ValueError(f"不支持的文件类型：{suffix or p.name}")


def _load_hex_dir(folder: Path) -> dict[str, np.ndarray]:
    out = {}
    for ch in range(8):
        f = folder / f"ch{ch}.hex"
        if not f.exists():
            continue
        words = np.array([int(t, 16) for t in f.read_text(encoding="ascii").split()], dtype="<u4")
        out[f"ch{ch}.hex"] = words.view("<i2").astype(np.float64)
    if not out:
        raise ValueError("目录里没有 chN.hex")
    return out


def scale(y: np.ndarray, mode: str = "auto") -> tuple[np.ndarray, str]:
    """Convert imported numbers to full-scale units (±1)."""
    y = np.asarray(y, dtype=np.float64)
    peak = float(np.max(np.abs(y))) if y.size else 0.0
    if mode == "auto":
        mode = "fs" if peak <= 1.0 else ("int16" if peak <= 32768 and np.allclose(y, np.round(y)) else "peak")
    if mode == "fs":
        return np.clip(y, -1.0, 1.0), "按满量程(±1)" + ("，超出部分已限幅" if peak > 1.0 else "")
    if mode == "int16":
        return np.clip(y / 32768.0, -1.0, 1.0), "按 int16 码值 (/32768)"
    if mode == "peak":
        return (y / peak if peak > 0 else y), f"归一化到峰值 (原峰值 {peak:.4g})"
    raise ValueError(mode)
