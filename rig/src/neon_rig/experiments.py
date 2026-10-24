"""The rig's experiments: drive the Pi, watch with the camera, measure.

Each function takes a `Rig`, so the same code runs against the real
installation and against the simulated one in the tests.
"""

from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from typing import Any

import cv2
import numpy as np
import polars as pl
from loguru import logger

from neon_rig.camera import Camera, Clock
from neon_rig.leds import Key, LedMap, Region, linear_lut, locate
from neon_rig.measure import LockIn, flicker, frame_rate, lock_in, region_reducer
from neon_rig.pi import Condition, Pi, Relatch, Reshift, Wobble

CHANNELS_PER_CHIP = 24
KEY_COLUMNS = ["chain", "chip", "channel"]


def jitter_ms(rate_hz: float) -> float:
    """Tick jitter that spreads a condition's disturbances evenly across the
    camera's frames, whatever its frame rate (see Lab's moduledoc). Uniform
    jitter of a whole period would remove the tick rate's periodicity
    entirely; the Lab allows just under half a period either side."""
    return 0.48 * 1000 / rate_hz


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

    def frames(self, count: int) -> tuple[np.ndarray, np.ndarray]:
        """`count` frames as linear BGR, and the raw 8-bit frames."""
        lut = linear_lut(self.gamma)
        _, raw = self.capture(count / self.camera.fps, lambda frame: frame)
        stack = np.stack(raw)
        return lut[stack], stack

    def mean_image(self, count: int) -> tuple[np.ndarray, np.ndarray]:
        """Mean linear BGR image and per-pixel raw maximum over `count` frames."""
        linear, raw = self.frames(count)
        return linear.mean(axis=0), raw.max(axis=0)


# The 3x3 Gaussian `locate` smooths with reduces white noise by this factor.
_BLUR_NOISE = float(np.sqrt((np.outer(*[cv2.getGaussianKernel(3, 0)] * 2) ** 2).sum()))


def noise_map(
    dark: np.ndarray, raw: np.ndarray, gamma: float, lit_frames: int
) -> np.ndarray:
    """Per-pixel noise of a lit mean minus the dark mean, after `locate`'s blur.

    A camera's noise is roughly constant in its 8-bit codes, so in linear light
    a brighter pixel is noisier; one figure for the whole frame would let a
    status LED or a glowing screen pass for a lit channel. A pixel too steady
    to measure gets the noise of one camera step at its level, and each pixel
    takes the largest noise around it, to be safe at the edges of bright
    patches.
    """
    frames = len(dark)
    per_frame = dark.sum(axis=3).std(axis=0, ddof=1)
    lut = linear_lut(gamma)
    codes = np.clip(np.rint(raw.mean(axis=0)).astype(int), 0, 254)
    step = np.sqrt(((lut[codes + 1] - lut[codes]) ** 2 / 12).sum(axis=2))
    per_frame = np.maximum(per_frame, step)
    difference = per_frame * np.sqrt(1 / lit_frames + 1 / frames)
    return _BLUR_NOISE * cv2.dilate(
        difference.astype(np.float32), np.ones((3, 3), np.uint8)
    )


def crowded(led_map: LedMap, radius_px: float = 3.0) -> list[Region]:
    """Present regions sitting on another chip's region. Two chips can't share
    a spot, so these are probably something other than an LED (a reflection,
    a screen) answering to more than one channel."""
    present = [region for region in led_map.present() if region.centroid]
    suspects = []
    for region in present:
        assert region.centroid is not None
        x, y = region.centroid
        for other in present:
            assert other.centroid is not None
            same_chip = (other.chain, other.chip) == (region.chain, region.chip)
            if (
                not same_chip
                and np.hypot(other.centroid[0] - x, other.centroid[1] - y) < radius_px
            ):
                suspects.append(region)
                break
    return suspects


def map_leds(
    rig: Rig, level: int = 1024, frames: int = 4, dark_frames: int = 16
) -> tuple[LedMap, np.ndarray]:
    """Light every channel of every chain on its own and locate it. Returns
    the map and a mean image of everything lit at `level`, for annotating."""
    chains = rig.pi.chains()
    rig.pi.fill(0)
    dark, raw = rig.frames(dark_frames)
    noise = noise_map(dark, raw, rig.gamma, frames)
    dark_mean = dark.mean(axis=0)
    logger.info(
        "Dark frames: noise {:.1e} to {:.1e} (linear) across the image",
        float(noise.min()),
        float(noise.max()),
    )

    regions, masks = [], {}
    for chain in chains:
        for chip in range(chain.chips):
            for channel in range(CHANNELS_PER_CHIP):
                rig.pi.light_one(chain.id, chip, channel, level)
                lit, lit_max = rig.mean_image(frames)
                region, mask = locate(
                    (chain.id, chip, channel), lit, dark_mean, noise, lit_max
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
    shape = (dark_mean.shape[0], dark_mean.shape[1])
    return LedMap(shape, level, regions, masks, dark_mean.astype(np.float32)), lit_all


def usable(rig: Rig, led_map: LedMap, level: int) -> list[Key]:
    """The mapped regions that don't saturate with everything at `level`
    (which the caller has already lit)."""
    keys = [region.key for region in led_map.present()]
    if not keys:
        raise RuntimeError("the map has no lit regions; run `neon-rig map` again")
    _, raw_max = rig.mean_image(8)
    clipped = (raw_max >= 250).any(axis=2).ravel()
    saturated = {key for key in keys if clipped[led_map.masks[key][0]].any()}
    if len(saturated) == len(keys):
        raise RuntimeError(
            f"every region saturates at level {level}: lower --level, the "
            "exposure or the gain, or dim the camera with an ND gel"
        )
    if saturated:
        logger.warning(
            "{} of {} regions saturate at level {}; leaving them out",
            len(saturated),
            len(keys),
            level,
        )
    return [key for key in keys if key not in saturated]


@dataclass
class Series:
    """One capture: frame times, each region's brightness, and the Pi's
    timing for the condition that ran (if any)."""

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


def metrics(series: Series, keys: list[Key], capture: int = 0) -> pl.DataFrame:
    """Flicker metrics (see `measure.flicker`) for the regions in `keys`."""
    wanted = set(keys)
    rows = []
    for index, key in enumerate(series.keys):
        if key in wanted:
            chain, chip, channel = key
            result = flicker(series.times, series.values[:, index])
            rows.append(
                {
                    "condition": series.name,
                    "capture": capture,
                    "chain": chain,
                    "chip": chip,
                    "channel": channel,
                    **asdict(result),
                }
            )
    return pl.DataFrame(rows)


def bracketed(
    condition: pl.DataFrame, before: pl.DataFrame, after: pl.DataFrame
) -> pl.DataFrame:
    """A condition's metrics with its brightness and flicker relative to the
    mean of the static captures either side of it, which cancels the drift
    as the LEDs warm up."""
    base = (
        before.select(*KEY_COLUMNS, "mean", "rms")
        .join(
            after.select(*KEY_COLUMNS, "mean", "rms"), on=KEY_COLUMNS, suffix="_after"
        )
        .select(
            *KEY_COLUMNS,
            base_mean=(pl.col("mean") + pl.col("mean_after")) / 2,
            base_rms=(pl.col("rms") + pl.col("rms_after")) / 2,
        )
    )
    return (
        condition.join(base, on=KEY_COLUMNS)
        .with_columns(
            mean_vs_static=pl.col("mean") / pl.col("base_mean"),
            rms_vs_static=pl.col("rms") / pl.col("base_rms"),
        )
        .drop("base_mean", "base_rms")
    )


def summarise(table: pl.DataFrame) -> pl.DataFrame:
    """Per condition and chain: the median, 90th percentile and worst RMS
    flicker and the median deepest dip, as fractions of the mean, and the
    medians of each region's flicker and brightness over the static captures
    either side. The brightness ratio shows light a condition loses without
    flickering."""
    return table.group_by("condition", "chain", maintain_order=True).agg(
        regions=pl.struct("chip", "channel").n_unique(),
        rms_median=pl.col("rms").median(),
        rms_p90=pl.col("rms").quantile(0.9),
        rms_max=pl.col("rms").max(),
        dip_median=pl.col("dip").median(),
        rms_vs_static=pl.col("rms_vs_static").median(),
        mean_vs_static=pl.col("mean_vs_static").median(),
    )


def suite_conditions(
    blank_chains: tuple[str, ...],
) -> list[tuple[str, Condition, tuple[str, ...] | None]]:
    """The suite's conditions, each with the chains it measures (all if
    `None`). BLANK pulsing runs only on chains with a BLANK GPIO."""
    conditions: list[tuple[str, Condition, tuple[str, ...] | None]] = [
        ("relatch 30 Hz", Relatch(30, jitter_ms=jitter_ms(30)), None),
        ("relatch 10 Hz", Relatch(10, jitter_ms=jitter_ms(10)), None),
        ("reshift 30 Hz", Reshift(30, jitter_ms=jitter_ms(30)), None),
    ]
    if blank_chains:
        pulsed = Relatch(30, "blank_pulse", blank_chains, jitter_ms=jitter_ms(30))
        conditions.append(("relatch 30 Hz, BLANK pulsed", pulsed, blank_chains))
    return conditions


@dataclass
class SuiteResult:
    table: pl.DataFrame
    summary: pl.DataFrame
    series: list[Series]
    left_out: list[Key] = field(default_factory=list)


def flicker_suite(
    rig: Rig,
    led_map: LedMap,
    level: int = 4095,
    seconds: float = 10.0,
    warmup_s: float = 20.0,
) -> SuiteResult:
    """Every channel at `level`, measured static, re-latched at 30 and 10 Hz,
    re-shifted at 30 Hz without latching, and re-latched at 30 Hz with BLANK
    pulsed on the chains that have a BLANK GPIO. A static capture before and
    after every condition is its reference.

    A level near full duty keeps the PWM period from beating against the
    exposure, which at mid levels adds frame-to-frame noise the eye doesn't
    see. The warm-up lets the LEDs settle after the jump in brightness."""
    blank_chains = tuple(
        chain.id for chain in rig.pi.chains() if chain.switches.get("blank_gpio")
    )
    rig.pi.fill(level)
    logger.info("Warming up at level {} for {:.0f} s", level, warmup_s)
    rig.clock.sleep(warmup_s)
    keys = usable(rig, led_map, level)

    series = [record(rig, led_map, "static", None, seconds)]
    statics = [metrics(series[0], keys, 0)]
    tables = [statics[0]]
    for name, condition, chains in suite_conditions(blank_chains):
        logger.info(
            "Recording {} for {:.0f} s, with a static capture after", name, seconds
        )
        captured = record(rig, led_map, name, condition, seconds)
        static = record(rig, led_map, "static", None, seconds)
        series += [captured, static]
        measured_keys = [key for key in keys if chains is None or key[0] in chains]
        statics.append(metrics(static, keys, len(series) - 1))
        condition_table = metrics(captured, measured_keys, len(series) - 2)
        tables += [bracketed(condition_table, statics[-2], statics[-1]), statics[-1]]

    table = pl.concat(tables, how="diagonal")
    left_out = [region.key for region in led_map.present() if region.key not in keys]
    return SuiteResult(table, summarise(table), series, left_out)


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
    fps: float
    # What a perfect camera would measure: the Pi updates the level in steps
    # at the wobble's rate, and each exposure averages over its length. This
    # assumes evenly spaced ticks; the calibration's jitter lowers the true
    # figure by about 3%.
    expected_gain: float
    series: tuple[Series, ...] = ()

    @property
    def detected(self) -> bool:
        return self.wobble.snr >= 5 and self.steady.snr < 3

    @property
    def gain(self) -> float:
        """Measured over injected modulation depth."""
        return self.wobble.amplitude / self.depth

    @property
    def residual(self) -> float:
        """Measured gain over the expected one: how far the camera's response
        (its gamma, its black level) is from what the rig assumes."""
        return self.gain / self.expected_gain


def calibrate(
    rig: Rig,
    led_map: LedMap,
    level: int = 4000,
    target: Key | None = None,
    depth: float = 0.01,
    freq_hz: float = 5.0,
    rate_hz: float = 30.0,
    seconds: float = 20.0,
    warmup_s: float = 20.0,
) -> Calibration:
    """The noise floor of a static frame with every channel at `level`. Then,
    with only `target` lit, a lock-in reading at `freq_hz` while the channel
    is re-latched unchanged and while it wobbles by `depth`, both at
    `rate_hz` with the same jitter, so a latch pattern aliasing onto
    `freq_hz` shows up in both. The wobble runs with nothing else lit because
    the camera can't separate the dies of an RGB LED."""
    rig.pi.fill(level)
    rig.clock.sleep(warmup_s)
    keys = usable(rig, led_map, level)
    static = record(rig, led_map, "static", None, seconds)
    floor = metrics(static, keys)

    if target is None:
        regions = {region.key: region for region in led_map.present()}
        target = max(keys, key=lambda key: regions[key].peak)
    chain, chip, channel = target
    rig.pi.light_one(chain, chip, channel, level)
    steady_condition = Relatch(rate_hz, chains=(chain,), jitter_ms=jitter_ms(rate_hz))
    steady = record(rig, led_map, "steady", steady_condition, seconds)
    wobble_condition = Wobble(
        chain, chip, channel, depth, freq_hz, rate_hz, jitter_ms=jitter_ms(rate_hz)
    )
    wobble = record(rig, led_map, "wobble", wobble_condition, seconds)
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
        fps=frame_rate(wobble.times),
        expected_gain=float(
            np.sinc(freq_hz / rate_hz) * np.sinc(freq_hz * rig.camera.exposure_s)
        ),
        series=(static, steady, wobble),
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
