import numpy as np
import pytest

from awg_gui import importers, measure, waveforms as wf


def test_snap_whole_cycles_and_seamless_loop():
    y, info = wf.generate(wf.WaveSpec(kind="sine", freq_hz=100e6, amp_dbfs=0, samples=131072))
    cycles = info["freq_hz"] * 131072 / wf.DAC_FS_HZ
    assert abs(cycles - round(cycles)) < 1e-9
    assert abs(info["freq_hz"] - 100e6) < wf.DAC_FS_HZ / 131072
    # the sample after the last one equals the first: loop is phase-continuous
    nxt = np.sin(2 * np.pi * round(cycles) * 131072 / 131072)
    assert abs(nxt - y[0]) < 1e-9


@pytest.mark.parametrize("kind", wf.KINDS)
def test_every_kind_in_range_and_length(kind):
    y, info = wf.generate(wf.WaveSpec(kind=kind, samples=1000, amp_dbfs=-3))
    assert len(y) == 992 and info["samples"] == 992          # rounded down to a multiple of 32
    assert np.max(np.abs(y)) <= 1.0
    assert np.max(np.abs(y)) <= 10 ** (-3 / 20) + 1e-9 or kind == "dc"


def test_offset_clip_flag():
    _, info = wf.generate(wf.WaveSpec(kind="sine", amp_dbfs=0, offset_fs=0.5, samples=256))
    assert info["clipped"]


def test_chirp_phase_continuous_total_cycles():
    _, info = wf.generate(wf.WaveSpec(kind="chirp", freq_hz=100e6, stop_hz=900e6, samples=4096))
    total = (info["start_hz"] + info["stop_hz"]) / 2 * 4096 / wf.DAC_FS_HZ
    assert abs(total - round(total)) < 1e-6


def test_quantize_and_pack_roundtrip():
    y = np.array([1.0, -1.0, 0.5, -0.25, 0.0, 2.0])
    q = wf.quantize(y)
    assert q.tolist() == [32764, -32764, 16384, -8192, 0, 32764]
    assert all(v % 4 == 0 for v in q.tolist())
    words = wf.pack_words(q)
    assert words[0] == ((-32764 & 0xFFFF) << 16) | 32764      # earlier sample in [15:0]
    assert wf.unpack_pairs(words).tolist() == q.tolist()


def test_fit_length():
    y, note = wf.fit_length(np.ones(100))
    assert len(y) == 96 and "截" in note
    y, note = wf.fit_length(np.ones(100), mode="pad")
    assert len(y) == 128 and "补零" in note
    y, _ = wf.fit_length(np.ones(200000))
    assert len(y) == wf.TX_MAX_SAMPLES


def _tone(freq, amp_fs, n=65520, fs=5e9, noise_lsb=0.0, harm=0.0, seed=3):
    t = np.arange(n) / fs
    y = amp_fs * 32768 * np.sin(2 * np.pi * freq * t) + harm * 32768 * np.sin(2 * np.pi * 2 * freq * t)
    y += np.random.default_rng(seed).normal(0, noise_lsb, n)
    return y


def test_measure_frequency_and_level():
    m = measure.measure(_tone(123.456e6, 0.5, noise_lsb=2.0))
    assert abs(m["freq_hz"] - 123.456e6) < 20e3
    assert abs(m["peak_dbfs"] - 20 * np.log10(0.5)) < 0.1


def test_measure_sfdr_and_sinad():
    m = measure.measure(_tone(200e6, 0.5, noise_lsb=10.0, harm=0.5 * 10 ** (-60 / 20)))
    assert abs(m["sfdr_dbc"] - 60) < 1.0
    # SNR from white noise: signal rms 0.5*32768/sqrt2 over 10 LSB rms
    expected_snr = 20 * np.log10(0.5 * 32768 / np.sqrt(2) / 10.0)
    assert abs(m["snr_db"] - expected_snr) < 1.0
    assert m["sinad_db"] <= m["snr_db"] + 1e-6


def test_spectrum_full_scale_reads_0dbfs():
    f, db, rbw = measure.spectrum(_tone(100e6, 1.0), window_name="flattop")
    assert abs(db.max()) < 0.05
    assert rbw > 5e9 / 65520


def test_import_csv_npy_mat_and_scale(tmp_path):
    from scipy.io import savemat
    a = np.sin(np.linspace(0, 20, 640))
    np.save(tmp_path / "w.npy", a)
    (tmp_path / "w.csv").write_text("\n".join(f"{v},{-v}" for v in a), encoding="ascii")
    savemat(tmp_path / "w.mat", {"wave": a, "iq": a + 1j * a})
    assert list(importers.load_file(tmp_path / "w.npy")) == ["w"]
    cols = importers.load_file(tmp_path / "w.csv")
    assert len(cols) == 2 and np.allclose(list(cols.values())[1], -a)
    mat = importers.load_file(tmp_path / "w.mat")
    assert "wave" in mat and np.allclose(mat["iq"], a)
    y, note = importers.scale(a * 16000.0 // 1, "auto")
    assert np.max(np.abs(y)) <= 1.0 and "int16" in note
