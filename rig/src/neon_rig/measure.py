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
    if not keys:
        raise ValueError("no regions to measure; the map found nothing lit")
    lut = linear_lut(gamma)
    indices = np.concatenate([led_map.masks[key][0] for key in keys])
    weights = np.concatenate([led_map.masks[key][1] for key in keys])
    starts = np.cumsum([0] + [len(led_map.masks[key][0]) for key in keys[:-1]])
    dark = np.add.reduceat(led_map.dark.sum(axis=2).ravel()[indices] * weights, starts)

    def reduce(frame: np.ndarray) -> np.ndarray:
        lum = luminance(frame, lut).ravel()
        return np.add.reduceat(lum[indices] * weights, starts) - dark

    return keys, reduce


def frame_rate(times: np.ndarray) -> float:
    """Frames per second from frame times, as the camera actually ran."""
    return float(1 / np.median(np.diff(times)))


def uniform(
    times: np.ndarray, values: np.ndarray
) -> tuple[np.ndarray, np.ndarray, int]:
    """Resample onto an even grid at the median frame interval. Returns the
    grid, the values, and how many frames the camera dropped. A frame less
    than half an interval after the one before is a duplicate and is left
    out."""
    step = float(np.median(np.diff(times)))
    keep = np.concatenate([[True], np.diff(times) >= step / 2])
    times, values = times[keep], values[keep]
    dropped = int(np.sum(np.maximum(np.round(np.diff(times) / step) - 1, 0)))
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
    count, step = len(deviation), grid[1] - grid[0]
    window = np.hanning(count)
    spectrum = np.fft.rfft(deviation * window)
    freqs = np.fft.rfftfreq(count, step)
    # The amplitude of a sinusoid at each frequency.
    amplitude = 2 * np.abs(spectrum) / window.sum()
    # At 30 fps the band's top, 15 Hz, is the last bin.
    band = (freqs >= BAND_HZ[0]) & (freqs <= BAND_HZ[1] * (1 + 1e-9))
    # Each bin's share of the variance. The window keeps slow drift from
    # leaking into the band; one-sided bins count twice, apart from DC and,
    # for an even count, the last.
    doubled = np.full(len(freqs), 2.0)
    doubled[0] = 1.0
    if count % 2 == 0:
        doubled[-1] = 1.0
    variance = doubled * np.abs(spectrum) ** 2 / (count * (window**2).sum())
    band_rms = float(np.sqrt(variance[band].sum()))
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
