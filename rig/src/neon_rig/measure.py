"""Brightness time series per LED channel, and flicker metrics from them."""

from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from neon_rig.leds import Key, LedMap, linear_lut, luminance

# The band the eye can see flicker in, and that 30 fps can resolve.
BAND_HZ = (0.5, 15.0)


def region_reducer(
    led_map: LedMap, gamma: float, keys: list[Key] | None = None
) -> tuple[list[Key], Callable[[np.ndarray], np.ndarray]]:
    """A frame reducer giving each region's weighted linear luminance, minus
    the same weighted sum over the map's dark image (linear BGR)."""
    keys = keys if keys is not None else [region.key for region in led_map.present()]
    lut = linear_lut(gamma)
    indices = np.concatenate([led_map.masks[key][0] for key in keys])
    weights = np.concatenate([led_map.masks[key][1] for key in keys])
    starts = np.cumsum([0] + [len(led_map.masks[key][0]) for key in keys[:-1]])
    dark = np.add.reduceat(led_map.dark.sum(axis=2).ravel()[indices] * weights, starts)

    def reduce(frame: np.ndarray) -> np.ndarray:
        lum = luminance(frame, lut).ravel()
        return np.add.reduceat(lum[indices] * weights, starts) - dark

    return keys, reduce


def mean_reducer(gamma: float) -> Callable[[np.ndarray], tuple[np.ndarray, np.ndarray]]:
    """A frame reducer giving the linear BGR image and the raw frame, for
    averaging and for spotting saturation."""
    lut = linear_lut(gamma)
    return lambda frame: (lut[frame], frame)


def average(
    results: list[tuple[np.ndarray, np.ndarray]],
) -> tuple[np.ndarray, np.ndarray]:
    """Mean linear image and per-pixel raw maximum of `mean_reducer` results."""
    linear = np.mean([linear for linear, _ in results], axis=0)
    raw_max = np.max([raw for _, raw in results], axis=0)
    return linear, raw_max


def uniform(
    times: np.ndarray, values: np.ndarray
) -> tuple[np.ndarray, np.ndarray, int]:
    """Resample onto an even grid at the median frame interval. Returns the
    grid, the values, and how many frames the camera dropped."""
    step = float(np.median(np.diff(times)))
    dropped = int(np.sum(np.round(np.diff(times) / step) - 1))
    grid = times[0] + step * np.arange(round((times[-1] - times[0]) / step) + 1)
    return grid, np.interp(grid, times, values), dropped


def relative(times: np.ndarray, values: np.ndarray) -> np.ndarray:
    """Deviation from the mean as a fraction of it, with any linear drift
    (the camera or the LEDs warming up) removed."""
    mean = values.mean()
    trend = np.polyval(np.polyfit(times - times[0], values, 1), times - times[0])
    return (values - trend) / mean


@dataclass(frozen=True)
class Flicker:
    mean: float
    rms: float
    p2p: float
    dip: float
    band_rms: float
    peak_hz: float
    peak_amplitude: float
    dropped: int


def flicker(times: np.ndarray, values: np.ndarray) -> Flicker:
    """Flicker metrics for one channel's brightness series. `rms`, `p2p`
    (0.5th to 99.5th percentile) and `dip` (deepest drop) are fractions of the
    mean; `band_rms` and the peak are the part between 0.5 and 15 Hz."""
    grid, series, dropped = uniform(times, values)
    deviation = relative(grid, series)
    step = grid[1] - grid[0]
    window = np.hanning(len(deviation))
    spectrum = np.fft.rfft(deviation * window)
    freqs = np.fft.rfftfreq(len(deviation), step)
    # Amplitude of a sinusoid at each frequency, and the RMS in the band.
    amplitude = 2 * np.abs(spectrum) / window.sum()
    band = (freqs >= BAND_HZ[0]) & (freqs <= BAND_HZ[1])
    power = np.abs(np.fft.rfft(deviation)) ** 2 / len(deviation) ** 2
    band_rms = float(np.sqrt(2 * power[band].sum()))
    peak = int(np.argmax(np.where(band, amplitude, 0.0)))
    return Flicker(
        mean=float(series.mean()),
        rms=float(deviation.std()),
        p2p=float(np.percentile(deviation, 99.5) - np.percentile(deviation, 0.5)),
        dip=float(-deviation.min()),
        band_rms=band_rms,
        peak_hz=float(freqs[peak]),
        peak_amplitude=float(amplitude[peak]),
        dropped=dropped,
    )


@dataclass(frozen=True)
class LockIn:
    amplitude: float
    sigma: float

    @property
    def snr(self) -> float:
        return self.amplitude / self.sigma


def lock_in(times: np.ndarray, values: np.ndarray, freq_hz: float) -> LockIn:
    """Amplitude (a fraction of the mean) of the sinusoid at a known frequency,
    with its standard error from the residual noise."""
    t = times - times[0]
    deviation = values / values.mean() - 1
    design = np.column_stack(
        [
            np.sin(2 * np.pi * freq_hz * t),
            np.cos(2 * np.pi * freq_hz * t),
            np.ones_like(t),
            t,
        ]
    )
    coefficients, *_ = np.linalg.lstsq(design, deviation)
    residual = deviation - design @ coefficients
    sigma = float(residual.std() * np.sqrt(2 / len(t)))
    return LockIn(float(np.hypot(coefficients[0], coefficients[1])), sigma)
