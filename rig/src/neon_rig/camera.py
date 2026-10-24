"""The webcam on weddle, with its automatic controls locked.

Brightness measurements only mean something if the camera stops adjusting
itself, so `lock_controls` turns off auto exposure, auto white balance and
autofocus with `v4l2-ctl` (from v4l-utils) and checks they stuck. UVC drivers
name these controls two ways depending on the kernel; both are handled.
"""

import re
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

import cv2
import numpy as np
from loguru import logger


class Clock(Protocol):
    def now(self) -> float: ...
    def sleep(self, seconds: float) -> None: ...


class Camera(Protocol):
    fps: float
    exposure_s: float

    def collect[T](
        self, t_start: float, t_end: float, reduce: Callable[[np.ndarray], T]
    ) -> tuple[np.ndarray, list[T]]:
        """Apply `reduce` to every frame exposed between `t_start` and `t_end`
        on the clock's timeline, returning the frame times and the results.
        Frames are BGR uint8."""
        ...


class MonotonicClock:
    """The real clock. UVC frame timestamps use the same monotonic clock."""

    def now(self) -> float:
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


@dataclass(frozen=True)
class Control:
    name: str
    kind: str
    value: int
    minimum: int | None = None
    maximum: int | None = None
    step: int | None = None


_CONTROL_LINE = re.compile(r"^\s*(\w+)\s+0x[0-9a-f]+\s+\((\w+)\)\s*:\s*(.*)$")
_FIELD = re.compile(r"(\w+)=(-?\d+)")


def parse_controls(listing: str) -> dict[str, Control]:
    """Parse the output of `v4l2-ctl --list-ctrls`."""
    controls = {}
    for line in listing.splitlines():
        if match := _CONTROL_LINE.match(line):
            name, kind, rest = match.groups()
            fields = {key: int(value) for key, value in _FIELD.findall(rest)}
            if "value" in fields:
                controls[name] = Control(
                    name,
                    kind,
                    fields["value"],
                    fields.get("min"),
                    fields.get("max"),
                    fields.get("step"),
                )
    return controls


@dataclass(frozen=True)
class Settings:
    exposure_ms: float = 20.0
    gain: int | None = None
    white_balance_k: int = 4600
    focus: int | None = None


def lock_plan(
    controls: dict[str, Control], settings: Settings
) -> list[tuple[str, int]]:
    """Control values to set, in order: automatic modes off before the manual
    values they would otherwise override. Controls the camera lacks are left
    out."""

    def first(*names: str) -> Control | None:
        return next((controls[name] for name in names if name in controls), None)

    # Values the camera accepts as they are: within range and on a step, so
    # reading them back gives the same number.
    def clamp(control: Control, value: int) -> int:
        low = control.minimum if control.minimum is not None else value
        high = control.maximum if control.maximum is not None else value
        clamped = max(low, min(high, value))
        if control.step and control.step > 1:
            clamped = low + round((clamped - low) / control.step) * control.step
            clamped = min(clamped, high)
        if clamped != value:
            logger.warning("{} set to {} rather than {}", control.name, clamped, value)
        return clamped

    plan: list[tuple[str, int]] = []

    def add(control: Control | None, value: int | None) -> None:
        if control is not None and value is not None:
            plan.append((control.name, clamp(control, value)))

    # Manual exposure is 1 on both naming schemes' menus.
    add(first("auto_exposure", "exposure_auto"), 1)
    add(first("exposure_dynamic_framerate", "exposure_auto_priority"), 0)
    # UVC exposure is in units of 100 us.
    add(
        first("exposure_time_absolute", "exposure_absolute"),
        round(settings.exposure_ms * 10),
    )
    gain = first("gain")
    add(
        gain,
        settings.gain
        if settings.gain is not None
        else (gain.minimum if gain else None),
    )
    add(first("white_balance_automatic", "white_balance_temperature_auto"), 0)
    add(first("white_balance_temperature"), settings.white_balance_k)
    add(first("focus_automatic_continuous", "focus_auto"), 0)
    add(first("focus_absolute"), settings.focus)
    add(first("backlight_compensation"), 0)
    # 50 Hz mains, in case anything still adapts to it.
    add(first("power_line_frequency"), 1)
    return plan


def v4l2_ctl(device: str, *args: str) -> str:
    result = subprocess.run(
        ["v4l2-ctl", "-d", device, *args], capture_output=True, text=True, check=True
    )
    return result.stdout


def lock_controls(device: str, settings: Settings) -> dict[str, int]:
    """Set the lock plan on the camera, then read it back and fail if any value
    didn't stick. Returns the controls as set."""
    plan = lock_plan(parse_controls(v4l2_ctl(device, "--list-ctrls")), settings)
    for name, value in plan:
        v4l2_ctl(device, "-c", f"{name}={value}")
    actual = parse_controls(v4l2_ctl(device, "--list-ctrls"))
    wrong = {
        name: (value, actual[name].value)
        for name, value in plan
        if actual[name].value != value
    }
    if wrong:
        raise RuntimeError(f"camera controls didn't stick (wanted, got): {wrong}")
    logger.info("Camera controls locked: {}", dict(plan))
    return dict(plan)


class V4l2Camera:
    """A UVC webcam read with OpenCV's V4L2 backend."""

    def __init__(
        self,
        device: str = "/dev/video0",
        width: int = 640,
        height: int = 480,
        fps: float = 30.0,
        fourcc: str = "YUYV",
        settings: Settings | None = None,
    ) -> None:
        settings = settings or Settings()
        self.device = device
        self.capture = cv2.VideoCapture(device, cv2.CAP_V4L2)
        if not self.capture.isOpened():
            raise RuntimeError(f"can't open {device}")
        self.capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter.fourcc(*fourcc))
        self.capture.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.capture.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.capture.set(cv2.CAP_PROP_FPS, fps)
        # Streaming has to start before some UVC cameras accept controls.
        self._read()
        self.controls = lock_controls(device, settings)
        reported = self.capture.get(cv2.CAP_PROP_FPS)
        self.fps = reported if reported > 0 else fps
        # The exposure as set, in UVC's units of 100 us, which can differ
        # from the one asked for when the camera's range or step forces it.
        exposure = self.controls.get(
            "exposure_time_absolute", self.controls.get("exposure_absolute")
        )
        self.exposure_s = exposure / 10_000 if exposure else settings.exposure_ms / 1000
        shape = (
            self.capture.get(cv2.CAP_PROP_FRAME_WIDTH),
            self.capture.get(cv2.CAP_PROP_FRAME_HEIGHT),
        )
        if shape != (width, height):
            raise RuntimeError(
                f"camera gave {shape[0]:.0f}x{shape[1]:.0f}, not {width}x{height}"
            )

    def _read(self) -> tuple[float, np.ndarray]:
        ok, frame = self.capture.read()
        if not ok:
            raise RuntimeError(f"no frame from {self.device}")
        now = time.monotonic()
        stamp = self.capture.get(cv2.CAP_PROP_POS_MSEC) / 1000
        # The driver's buffer timestamp is on the monotonic clock; fall back to
        # the read time if this camera doesn't provide one.
        return (stamp if abs(stamp - now) < 1.0 else now), frame

    def collect[T](
        self, t_start: float, t_end: float, reduce: Callable[[np.ndarray], T]
    ) -> tuple[np.ndarray, list[T]]:
        times, results = [], []
        while True:
            stamp, frame = self._read()
            if stamp >= t_end:
                break
            # Frames queued before t_start are stale; skip them.
            if stamp >= t_start:
                times.append(stamp)
                results.append(reduce(frame))
        return np.asarray(times), results

    def close(self) -> None:
        self.capture.release()
