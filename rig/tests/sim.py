"""A simulated installation, for testing the rig without hardware.

`SimPi` stands in for `NeonPerceptron.Lab` and `SimCamera` renders what the
webcam would see, both on a shared simulated clock. An LED's light over an
exposure is its PWM on-time, less what XLAT latches blank (the rest of the
current period's on-time) and, on a chain whose BLANK line floats, what each
shift blanks while it's on the wire.
"""

import math
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from neon_rig.pi import ChainInfo, Condition, PiError, Relatch, Reshift, Wobble

type Key = tuple[str, int, int]

CHANNELS = 24
GS_STEPS = 4096
SHIFT_S_PER_CHIP = 288 / 1_000_000


class SimClock:
    def __init__(self) -> None:
        self.t = 100.0

    def now(self) -> float:
        return self.t

    def sleep(self, seconds: float) -> None:
        self.t += seconds

    def advance_to(self, t: float) -> None:
        self.t = max(self.t, t)


@dataclass(frozen=True)
class SimLed:
    key: Key
    position: tuple[float, float]
    image: np.ndarray  # linear BGR at full duty


@dataclass
class Installation:
    chips: dict[str, int]
    leds: list[SimLed]
    # Which GPIO each chain's BLANK line is wired to.
    blank_wiring: dict[str, str] = field(default_factory=dict)
    floating_blank: frozenset[str] = frozenset()
    # LEDs lose up to this fraction of their light as they warm up, with this
    # time constant, after their chain's frame changes.
    droop: float = 0.0
    droop_tau_s: float = 30.0
    seed: int = 1
    levels: dict[str, np.ndarray] = field(init=False)
    switches: dict[str, dict[str, Any]] = field(init=False)
    condition: Condition | None = None
    started_at: float = 0.0
    # Each tick's offset from its slot, in seconds.
    jitter: np.ndarray = field(default_factory=lambda: np.zeros(1))
    driven: dict[str, int] = field(default_factory=dict)
    lit_at: dict[str, float] = field(default_factory=dict)

    def __post_init__(self) -> None:
        rng = np.random.default_rng(self.seed)
        self.levels = {chain: np.zeros(n * CHANNELS) for chain, n in self.chips.items()}
        self.switches = {chain: {"blank_gpio": None} for chain in self.chips}
        pairs = [(chain, chip) for chain, n in self.chips.items() for chip in range(n)]
        # Each TLC5947 runs off its own oscillator, so periods differ.
        self.period = {pair: float(rng.uniform(0.75e-3, 1.25e-3)) for pair in pairs}
        self.phase = {pair: float(rng.uniform(0, 1e-3)) for pair in pairs}

    def duty(self, key: Key, t0: float, t1: float) -> float:
        """Mean duty of one channel over [t0, t1)."""
        chain, chip, channel = key
        if self.driven.get(self.blank_wiring.get(chain, ""), 0) == 1:
            return 0.0
        level = self.levels[chain][chip * CHANNELS + channel]
        condition = self.condition
        if (
            isinstance(condition, Wobble)
            and (condition.chain, condition.chip, condition.channel) == key
        ):
            # Like the Lab, the level steps at each tick, to the sinusoid's
            # value at that tick.
            ticks = [t for t, _ in self._shifts(chain, t0 - 1, (t0 + t1) / 2)]
            if ticks:
                seconds = ticks[-1] - self.started_at
                level *= 1 + condition.depth * math.sin(
                    2 * math.pi * condition.freq_hz * seconds
                )
        if self.droop:
            warm = 1 - math.exp(-(t0 - self.lit_at.get(chain, t0)) / self.droop_tau_s)
            level *= 1 - self.droop * warm
        d = min(level, GS_STEPS - 1) / GS_STEPS
        period, phase = self.period[(chain, chip)], self.phase[(chain, chip)]

        def on_time(x: float) -> float:
            cycles, into = divmod(x - phase, period)
            return cycles * d * period + min(into, d * period)

        def on_between(a: float, b: float) -> float:
            return max(0.0, on_time(b) - on_time(a)) if b > a else 0.0

        lost = 0.0
        for shift, latch in self._shifts(chain, t0 - period, t1):
            if chain in self.floating_blank:
                lost += on_between(
                    max(shift, t0),
                    min(shift + SHIFT_S_PER_CHIP * self.chips[chain], t1),
                )
            if latch == "xlat":
                # XLAT turns the outputs off until the next period starts.
                into = (shift - phase) % period
                lost += on_between(max(shift, t0), min(shift + period - into, t1))
        return max(0.0, on_between(t0, t1) - lost) / (t1 - t0)

    def _shifts(
        self, chain: str, t0: float, t1: float
    ) -> list[tuple[float, str | None]]:
        """(time, latch) of every shift into `chain` during [t0, t1)."""
        condition = self.condition
        match condition:
            case Relatch(rate_hz, latch, chains) if chains is None or chain in chains:
                kind: str | None = latch
            case Reshift(rate_hz, chains) if chains is None or chain in chains:
                kind = None
            case Wobble(chain=wobbled, rate_hz=rate_hz, latch=latch) if (
                wobbled == chain
            ):
                kind = latch
            case _:
                return []
        # Jitter can move a tick up to half a period, so look one slot further
        # either way.
        first = max(1, math.ceil((t0 - self.started_at) * rate_hz) - 1)
        last = math.ceil((t1 - self.started_at) * rate_hz) + 1
        ticks = [
            (self.started_at + k / rate_hz + self.jitter[k % len(self.jitter)], kind)
            for k in range(first, last)
        ]
        return [(t, latch) for t, latch in ticks if t0 <= t < t1]


class SimPi:
    def __init__(
        self, installation: Installation, clock: SimClock, latency_s: float = 0.03
    ) -> None:
        self.installation = installation
        self.clock = clock
        self.latency_s = latency_s
        self.rng = np.random.default_rng(3)

    def _call(self) -> Installation:
        self.clock.sleep(self.latency_s)
        return self.installation

    def chains(self) -> list[ChainInfo]:
        site = self._call()
        return [
            ChainInfo(
                id=chain,
                chips=n,
                mode="hardware",
                held=True,
                switches=dict(site.switches[chain]),
            )
            for chain, n in site.chips.items()
        ]

    def fill(self, level: int, chain: str | None = None) -> None:
        site = self._call()
        for name in [chain] if chain else site.chips:
            site.levels[name][:] = level
            site.lit_at[name] = self.clock.now()

    def light_one(self, chain: str, chip: int, channel: int, level: int) -> None:
        site = self._call()
        for name, levels in site.levels.items():
            levels[:] = 0
            site.lit_at[name] = self.clock.now()
        site.levels[chain][chip * CHANNELS + channel] = level

    def start(self, condition: Condition) -> None:
        site = self._call()
        chains = getattr(condition, "chains", None) or site.chips
        if getattr(condition, "latch", "xlat") == "blank_pulse" and not all(
            site.switches[chain]["blank_gpio"] for chain in chains
        ):
            raise PiError("Lab returned an error: :no_blank_gpio")
        jitter_s = getattr(condition, "jitter_ms", 0.0) / 1000
        if jitter_s * condition.rate_hz >= 0.5:
            raise PiError(f"Lab returned an error: {{:bad_jitter, {jitter_s * 1000}}}")
        site.condition = condition
        site.started_at = self.clock.now()
        site.jitter = self.rng.uniform(-jitter_s, jitter_s, 100_000)

    def stop(self) -> dict[str, Any]:
        site = self._call()
        site.condition = None
        return {"ticks": 0}

    def probe_gpio(self, label: str, value: int) -> None:
        self._call().driven[label] = value

    def release_gpio(self, label: str) -> None:
        del self._call().driven[label]

    def configure(self, chain: str, **switches: Any) -> None:
        self._call().switches[chain].update(switches)

    def readback(self, chain: str, frames: int) -> dict[str, Any]:
        self._call()
        return {"frames": frames, "matched": frames, "bit_errors": 0}

    def release(self) -> None:
        site = self._call()
        site.condition = None
        site.driven.clear()


class SimCamera:
    def __init__(
        self,
        installation: Installation,
        clock: SimClock,
        fps: float = 30.0,
        exposure_s: float = 0.02,
        shape: tuple[int, int] = (120, 160),
        dark: float = 0.004,
        noise: float = 0.0005,
        code_noise: float = 0.8,
        glow: tuple[int, int, int, float] | None = None,
        seed: int = 2,
    ) -> None:
        """`noise` is in linear light and `code_noise` in 8-bit codes, where a
        real camera's mostly is. `glow` is a steady bright square, such as a
        status LED or a screen: (x, y, size, linear level)."""
        self.installation = installation
        self.clock = clock
        self.fps = fps
        self.exposure_s = exposure_s
        self.shape = shape
        self.dark = dark
        self.noise = noise
        self.code_noise = code_noise
        self.glow = glow
        self.rng = np.random.default_rng(seed)
        self.offset = 0.0123

    def collect[T](
        self, t_start: float, t_end: float, reduce: Any
    ) -> tuple[np.ndarray, list[T]]:
        times, results = [], []
        frame_number = math.ceil((t_start - self.offset) * self.fps)
        while (t := self.offset + frame_number / self.fps) < t_end:
            times.append(t)
            results.append(reduce(self.render(t)))
            frame_number += 1
        self.clock.advance_to(t_end)
        return np.asarray(times), results

    def render(self, t: float) -> np.ndarray:
        linear = np.full((*self.shape, 3), self.dark)
        if self.glow:
            x, y, size, level = self.glow
            linear[y : y + size, x : x + size] = level
        for led in self.installation.leds:
            duty = self.installation.duty(led.key, t, t + self.exposure_s)
            if duty > 0:
                linear += duty * led.image
        linear += self.rng.normal(0, self.noise, linear.shape)
        codes = np.clip(linear, 0, 1) ** (1 / 2.2) * 255
        codes += self.rng.normal(0, self.code_noise, codes.shape)
        return np.clip(codes.round(), 0, 255).astype(np.uint8)


BLUE = (0.5, 0.08, 0.02)
GREEN = (0.08, 0.5, 0.08)
RED = (0.02, 0.06, 0.5)


def layout(
    chips: dict[str, int], shape: tuple[int, int] = (120, 160)
) -> tuple[list[SimLed], dict[Key, str]]:
    """Per chip, two RGB LEDs on channels 18--20 and 21--23 and a red and a
    blue noodle on channels 0 and 1; the other channels unpopulated. Returns
    the LEDs and each one's colour name."""
    ys, xs = np.mgrid[0 : shape[0], 0 : shape[1]].astype(float)

    def blob(cx: float, cy: float) -> np.ndarray:
        return np.exp(-((xs - cx) ** 2 + (ys - cy) ** 2) / (2 * 1.6**2))

    def line(x0: float, x1: float, y: float) -> np.ndarray:
        dx = np.clip(xs, x0, x1) - xs
        return np.exp(-(dx**2 + (ys - y) ** 2) / (2 * 0.8**2))

    leds, colours = [], {}
    for row, (chain, count) in enumerate(chips.items()):
        for chip in range(count):
            cx, cy = 20 + 30 * chip, 25 + 55 * row
            parts = [
                (18, (cx, cy), blob(cx, cy), BLUE, "blue"),
                (19, (cx, cy), blob(cx, cy), GREEN, "green"),
                (20, (cx, cy), blob(cx, cy), RED, "red"),
                (21, (cx, cy + 20), blob(cx, cy + 20), BLUE, "blue"),
                (22, (cx, cy + 20), blob(cx, cy + 20), GREEN, "green"),
                (23, (cx, cy + 20), blob(cx, cy + 20), RED, "red"),
                (
                    0,
                    (cx, cy + 8),
                    line(cx - 8, cx + 8, cy + 8),
                    (0.02, 0.05, 0.3),
                    "red",
                ),
                (
                    1,
                    (cx, cy + 11),
                    line(cx - 8, cx + 8, cy + 11),
                    (0.3, 0.06, 0.02),
                    "blue",
                ),
            ]
            for channel, position, shape_image, bgr, name in parts:
                image = shape_image[..., None] * np.asarray(bgr)
                leds.append(SimLed((chain, chip, channel), position, image))
                colours[(chain, chip, channel)] = name
    return leds, colours
