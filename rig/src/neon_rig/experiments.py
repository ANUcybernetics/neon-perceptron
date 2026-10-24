"""The rig's experiments: drive the Pi, watch with the camera, measure.

Each function takes a `Rig`, so the same code runs against the real
installation and against the simulated one in the tests.
"""

from collections.abc import Callable
from collections.abc import Set as AbstractSet
from dataclasses import asdict, dataclass, field
from typing import Any

import numpy as np
import polars as pl
from loguru import logger

from neon_rig.camera import Camera, Clock
from neon_rig.leds import Key, LedMap, linear_lut, locate
from neon_rig.measure import (
    LockIn,
    average,
    flicker,
    lock_in,
    mean_reducer,
    region_reducer,
)
from neon_rig.pi import Condition, Pi, Relatch, Reshift, Wobble

CHANNELS_PER_CHIP = 24


@dataclass
class Rig:
    pi: Pi
    camera: Camera
    clock: Clock
    # Camera output is roughly sRGB; this undoes it to get linear light.
    gamma: float = 2.2
    # Time for an SSH reply, a latch and a stale camera buffer to clear.
    settle_s: float = 0.3

    def capture[T](
        self, seconds: float, reduce: Callable[[np.ndarray], T]
    ) -> tuple[np.ndarray, list[T]]:
        start = self.clock.now() + self.settle_s
        return self.camera.collect(start, start + seconds, reduce)

    def mean_image(self, frames: int) -> tuple[np.ndarray, np.ndarray]:
        """Mean linear BGR image and per-pixel raw maximum over `frames`."""
        _, results = self.capture(frames / self.camera.fps, mean_reducer(self.gamma))
        return average(results)


def map_leds(rig: Rig, level: int = 1024, frames: int = 4) -> tuple[LedMap, np.ndarray]:
    """Light every channel of every chain on its own and locate it. Returns
    the map and a mean image of everything lit at `level`, for annotating."""
    chains = rig.pi.chains()
    rig.pi.fill(0)
    dark_a, _ = rig.mean_image(2 * frames)
    dark_b, _ = rig.mean_image(2 * frames)
    dark = (dark_a + dark_b) / 2
    # Per-frame pixel noise from the two dark means, then the noise of a lit
    # mean minus the dark mean.
    # A pixel steady to within a camera step has no measurable noise, so one
    # step is the floor.
    pair = luminance_of(dark_a) - luminance_of(dark_b)
    mad = float(np.median(np.abs(pair - np.median(pair))))
    step = 3 * float(linear_lut(rig.gamma)[1])
    per_frame = max(1.4826 * mad, step) * np.sqrt(frames)
    noise = per_frame * np.sqrt(1 / frames + 1 / (4 * frames))
    logger.info("Dark frames: pixel noise {:.2e} (linear) per frame", per_frame)

    regions, masks = [], {}
    for chain in chains:
        for chip in range(chain.chips):
            for channel in range(CHANNELS_PER_CHIP):
                rig.pi.light_one(chain.id, chip, channel, level)
                lit, lit_max = rig.mean_image(frames)
                region, mask = locate(
                    (chain.id, chip, channel), lit, dark, noise, lit_max
                )
                regions.append(region)
                if mask is not None:
                    masks[region.key] = mask
            found = sum(
                1
                for r in regions
                if r.present and r.chain == chain.id and r.chip == chip
            )
            logger.info("{} chip {}: {} channels lit", chain.id, chip, found)

    rig.pi.fill(level)
    lit_all, _ = rig.mean_image(2 * frames)
    rig.pi.fill(0)
    return LedMap(
        dark.shape[:2], level, regions, masks, dark.astype(np.float32)
    ), lit_all


def luminance_of(linear: np.ndarray) -> np.ndarray:
    return linear.sum(axis=2)


def saturated(led_map: LedMap, raw_max: np.ndarray, keys: list[Key]) -> set[Key]:
    """Regions with any pixel at the top of the camera's range."""
    clipped = (raw_max >= 250).any(axis=2).ravel()
    return {key for key in keys if clipped[led_map.masks[key][0]].any()}


@dataclass
class Series:
    """One condition's capture: frame times and each region's brightness."""

    name: str
    keys: list[Key]
    times: np.ndarray
    values: np.ndarray
    timing: dict[str, Any] | None = None


def record(
    rig: Rig, led_map: LedMap, name: str, condition: Condition | None, seconds: float
) -> Series:
    """Capture every present region for `seconds`, with `condition` running
    on the Pi (or nothing, for a static frame)."""
    keys, reduce = region_reducer(led_map, rig.gamma)
    if condition is not None:
        rig.pi.start(condition)
    times, rows = rig.capture(seconds, reduce)
    timing = rig.pi.stop() if condition is not None else None
    return Series(name, keys, times, np.vstack(rows), timing)


def metrics(series: Series, excluded: AbstractSet[Key] = frozenset()) -> pl.DataFrame:
    """Flicker metrics per region (see `measure.flicker`)."""
    rows = []
    for index, key in enumerate(series.keys):
        if key in excluded:
            continue
        result = flicker(series.times, series.values[:, index])
        chain, chip, channel = key
        rows.append(
            {
                "condition": series.name,
                "chain": chain,
                "chip": chip,
                "channel": channel,
                **asdict(result),
            }
        )
    return pl.DataFrame(rows)


def summarise(table: pl.DataFrame, baseline: str = "static") -> pl.DataFrame:
    """Per condition and chain: the median, 90th percentile and worst RMS
    flicker and the median deepest dip, as fractions of the mean; the median
    RMS over the baseline condition's; and the median brightness over the
    baseline's, which shows light a condition loses without flickering."""
    base = table.filter(pl.col("condition") == baseline).select(
        "chain", "chip", "channel", base_mean=pl.col("mean")
    )
    summary = (
        table.join(base, on=["chain", "chip", "channel"], how="left")
        .group_by("condition", "chain", maintain_order=True)
        .agg(
            regions=pl.len(),
            rms_median=pl.col("rms").median(),
            rms_p90=pl.col("rms").quantile(0.9),
            rms_max=pl.col("rms").max(),
            dip_median=pl.col("dip").median(),
            mean_vs_static=(pl.col("mean") / pl.col("base_mean")).median(),
        )
    )
    base_rms = summary.filter(pl.col("condition") == baseline).select(
        "chain", base_rms=pl.col("rms_median")
    )
    return (
        summary.join(base_rms, on="chain", how="left")
        .with_columns(rms_vs_static=pl.col("rms_median") / pl.col("base_rms"))
        .drop("base_rms")
    )


# Spreads each condition's ticks across the camera's frames (see Lab's
# moduledoc). It has to stay under half the shortest period, 16.7 ms at 30 Hz.
SUITE_JITTER_MS = 10.0


def suite_conditions(blank_pulse: bool) -> list[tuple[str, Condition | None]]:
    jitter = SUITE_JITTER_MS
    conditions: list[tuple[str, Condition | None]] = [
        ("static", None),
        ("relatch 30 Hz", Relatch(30, jitter_ms=jitter)),
        ("relatch 10 Hz", Relatch(10, jitter_ms=jitter)),
        ("reshift 30 Hz", Reshift(30, jitter_ms=jitter)),
    ]
    if blank_pulse:
        conditions.append(
            (
                "relatch 30 Hz, BLANK pulsed",
                Relatch(30, "blank_pulse", jitter_ms=jitter),
            )
        )
    return conditions


@dataclass
class SuiteResult:
    table: pl.DataFrame
    summary: pl.DataFrame
    series: list[Series]
    saturated: set[Key] = field(default_factory=set)


def flicker_suite(
    rig: Rig, led_map: LedMap, level: int = 4095, seconds: float = 10.0
) -> SuiteResult:
    """Every channel at `level`, measured static, re-latched at 30 and 10 Hz,
    re-shifted at 30 Hz without latching, and (if every chain has a BLANK
    GPIO configured) re-latched at 30 Hz with BLANK pulsed. A level near full
    duty keeps the PWM period from beating against the exposure, which at
    mid levels adds frame-to-frame noise that isn't there for the eye."""
    chains = rig.pi.chains()
    blank_pulse = all(chain.switches.get("blank_gpio") for chain in chains)
    rig.pi.fill(level)
    keys = [region.key for region in led_map.present()]
    _, raw_max = rig.mean_image(8)
    clipped = saturated(led_map, raw_max, keys)
    if clipped:
        logger.warning(
            "{} regions saturate at level {}; leaving them out", len(clipped), level
        )

    series, tables = [], []
    for name, condition in suite_conditions(blank_pulse):
        logger.info("Recording {} for {:.0f} s", name, seconds)
        captured = record(rig, led_map, name, condition, seconds)
        series.append(captured)
        tables.append(metrics(captured, clipped))
    table = pl.concat(tables)
    return SuiteResult(table, summarise(table), series, clipped)


@dataclass(frozen=True)
class Calibration:
    target: Key
    level: int
    depth: float
    freq_hz: float
    floor_rms_median: float
    floor_rms_p90: float
    steady: LockIn
    wobble: LockIn

    @property
    def detected(self) -> bool:
        return self.wobble.snr >= 5 and self.steady.snr < 3

    @property
    def gain(self) -> float:
        """Measured over injected modulation depth."""
        return self.wobble.amplitude / self.depth


def calibrate(
    rig: Rig,
    led_map: LedMap,
    level: int = 4000,
    target: Key | None = None,
    depth: float = 0.01,
    freq_hz: float = 5.0,
    seconds: float = 10.0,
) -> Calibration:
    """The noise floor of a static frame with every channel at `level`. Then,
    with only `target` lit, a lock-in reading at `freq_hz` while the channel is
    held steady and while it wobbles by `depth`. The wobble runs with nothing
    else lit because the camera can't separate the dies of an RGB LED."""
    rig.pi.fill(level)
    keys = [region.key for region in led_map.present()]
    _, raw_max = rig.mean_image(8)
    clipped = saturated(led_map, raw_max, keys)
    floor = metrics(record(rig, led_map, "static", None, seconds), clipped)

    if target is None:
        candidates = [r for r in led_map.present() if r.key not in clipped]
        target = max(candidates, key=lambda region: region.peak).key
    chain, chip, channel = target
    rig.pi.light_one(chain, chip, channel, level)
    steady = record(rig, led_map, "steady", None, seconds)
    condition = Wobble(chain, chip, channel, depth, freq_hz)
    wobble = record(rig, led_map, "wobble", condition, seconds)
    index = steady.keys.index(target)
    return Calibration(
        target=target,
        level=level,
        depth=depth,
        freq_hz=freq_hz,
        floor_rms_median=floor.select(pl.col("rms").median()).item(),
        floor_rms_p90=floor.select(pl.col("rms").quantile(0.9)).item(),
        steady=lock_in(steady.times, steady.values[:, index], freq_hz),
        wobble=lock_in(wobble.times, wobble.values[:, index], freq_hz),
    )


def blank_search(
    rig: Rig,
    led_map: LedMap,
    gpios: tuple[str, ...] = ("GPIO22", "GPIO24", "GPIO17"),
    level: int = 2048,
    seconds: float = 1.0,
) -> tuple[dict[str, str], dict[str, dict[str, dict[str, float]]]]:
    """Drive each candidate GPIO high, then low, and see which chain goes
    dark. Returns the BLANK GPIO found for each chain, and every chain's
    brightness relative to before, per GPIO and level."""
    rig.pi.fill(level)
    keys, reduce = region_reducer(led_map, rig.gamma)
    chains = sorted({key[0] for key in keys})
    columns = {
        chain: [i for i, key in enumerate(keys) if key[0] == chain] for chain in chains
    }

    def brightness() -> dict[str, float]:
        _, rows = rig.capture(seconds, reduce)
        values = np.vstack(rows).mean(axis=0)
        return {chain: float(values[columns[chain]].sum()) for chain in chains}

    before = brightness()
    ratios: dict[str, dict[str, dict[str, float]]] = {}
    for gpio in gpios:
        rig.pi.probe_gpio(gpio, 1)
        high = brightness()
        rig.pi.probe_gpio(gpio, 0)
        low = brightness()
        rig.pi.release_gpio(gpio)
        ratios[gpio] = {
            chain: {
                "high": high[chain] / before[chain],
                "low": low[chain] / before[chain],
            }
            for chain in chains
        }
        logger.info("{}: {}", gpio, ratios[gpio])

    found = {
        chain: gpio
        for gpio, by_chain in ratios.items()
        for chain, ratio in by_chain.items()
        if ratio["high"] < 0.1 and ratio["low"] > 0.9
    }
    return found, ratios
