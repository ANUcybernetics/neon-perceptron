import numpy as np

from neon_rig.measure import flicker, lock_in, uniform


def series(
    amplitude: float, freq_hz: float, noise: float, seconds: float = 10
) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(7)
    times = np.arange(0, seconds, 1 / 30)
    values = 100 * (1 + amplitude * np.sin(2 * np.pi * freq_hz * times))
    return times, values + rng.normal(0, 100 * noise, times.shape)


def test_flicker_measures_a_sinusoid_in_the_visible_band() -> None:
    result = flicker(*series(0.02, 3.0, 0.001))

    assert abs(result.peak_hz - 3.0) < 0.1
    assert abs(result.peak_amplitude - 0.02) < 0.002
    assert abs(result.band_rms - 0.02 / np.sqrt(2)) < 0.001
    assert abs(result.rms - 0.02 / np.sqrt(2)) < 0.001
    assert result.dropped == 0


def test_lock_in_picks_a_small_wobble_out_of_larger_noise() -> None:
    wobble = lock_in(*series(0.01, 5.0, 0.02), freq_hz=5.0)
    nothing = lock_in(*series(0.0, 5.0, 0.02), freq_hz=5.0)

    assert abs(wobble.amplitude - 0.01) < 0.003
    assert wobble.snr > 5
    assert nothing.snr < 3


def test_dropped_frames_are_counted_and_filled_in() -> None:
    times, values = series(0.0, 1.0, 0.0)
    kept = np.ones(times.shape, dtype=bool)
    kept[[10, 11, 50]] = False

    grid, filled, dropped = uniform(times[kept], values[kept])

    assert dropped == 3
    assert len(grid) == len(times)
    np.testing.assert_allclose(filled, values, rtol=1e-6)


def test_a_duplicated_frame_doesnt_cancel_a_dropped_one() -> None:
    times, values = series(0.0, 1.0, 0.0)
    times = np.insert(np.delete(times, [20, 21]), 40, times[40] + 0.002)
    values = np.interp(times, *series(0.0, 1.0, 0.0))

    _, _, dropped = uniform(times, values)

    assert dropped == 2


def test_band_rms_counts_15_hz_once_and_ignores_slow_drift() -> None:
    times = np.arange(0, 10, 1 / 30)
    alternating = 100 * (1 + 0.01 * (-1.0) ** np.arange(len(times)))
    drifting = 100 * (1 + 0.01 * np.sin(2 * np.pi * 0.2 * times))

    assert abs(flicker(times, alternating).band_rms - 0.01) < 0.001
    assert flicker(times, drifting).band_rms < 0.002
