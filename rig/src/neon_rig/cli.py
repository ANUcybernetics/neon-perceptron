"""`neon-rig`: run the webcam rig's experiments from weddle."""

import json
import shutil
from collections.abc import Generator
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Annotated

import cv2
import numpy as np
import typer
from loguru import logger

from neon_rig.camera import (
    MonotonicClock,
    Settings,
    V4l2Camera,
    lock_plan,
    parse_controls,
    v4l2_ctl,
)
from neon_rig.experiments import Rig, blank_search, calibrate, flicker_suite, map_leds
from neon_rig.leds import LedMap, annotate
from neon_rig.pi import SshPi

app = typer.Typer(
    help="Webcam rig for unattended LED experiments (TASK-24).", no_args_is_help=True
)

RUNS = Path(__file__).resolve().parents[2] / "runs"

Host = Annotated[str, typer.Option(envvar="NEON_PI_HOST", help="The LED Pi.")]
Device = Annotated[str, typer.Option(envvar="NEON_CAMERA", help="The webcam.")]
Exposure = Annotated[
    float, typer.Option(help="Exposure in ms; keep it a multiple of 10.")
]
Gamma = Annotated[
    float, typer.Option(help="Camera output gamma, undone to get linear light.")
]
Level = Annotated[
    int, typer.Option(min=1, max=4095, help="Grayscale level to light LEDs at.")
]
Seconds = Annotated[float, typer.Option(min=1.0, help="Capture length per condition.")]
MapDir = Annotated[
    Path | None, typer.Option(help="Map run to use (default: the latest).")
]


def run_dir(command: str) -> Path:
    directory = RUNS / f"{datetime.now():%Y%m%d-%H%M%S}-{command}"
    directory.mkdir(parents=True)
    logger.add(directory / "log.txt")
    return directory


def latest_map() -> Path:
    maps = sorted(path.parent for path in RUNS.glob("*-map/map.json"))
    if not maps:
        raise typer.BadParameter("no map yet: run `neon-rig map` first")
    return maps[-1]


def to_8bit(linear: np.ndarray, gamma: float) -> np.ndarray:
    return (np.clip(linear, 0, 1) ** (1 / gamma) * 255).round().astype(np.uint8)


def write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data, indent=2, default=str))


@contextmanager
def rig(host: str, device: str, exposure_ms: float, gamma: float) -> Generator[Rig]:
    """The real rig. Hands the chains back to the build afterwards, so the
    installation doesn't stay frozen on the last test frame."""
    pi = SshPi(host)
    camera = V4l2Camera(device, settings=Settings(exposure_ms=exposure_ms))
    try:
        yield Rig(pi, camera, MonotonicClock(), gamma=gamma)
    finally:
        pi.release()
        camera.close()


@app.command()
def check(host: Host = "nerves.local", device: Device = "/dev/video0") -> None:
    """Reach the Pi, list its chains and read back each one; show what the camera lock would set."""
    pi = SshPi(host)
    for chain in pi.chains():
        logger.info(
            "{}: {} chips, {}, switches {}",
            chain.id,
            chain.chips,
            chain.mode,
            chain.switches,
        )
        logger.info("  readback: {}", pi.readback(chain.id, 8))
    pi.release()
    if shutil.which("v4l2-ctl") is None:
        logger.warning("v4l2-ctl isn't installed (sudo apt install v4l-utils)")
    elif Path(device).exists():
        plan = lock_plan(parse_controls(v4l2_ctl(device, "--list-ctrls")), Settings())
        logger.info("{} lock plan: {}", device, plan)
    else:
        logger.warning("no camera at {}", device)


@app.command()
def camera(
    device: Device = "/dev/video0", exposure_ms: Exposure = 20.0, gamma: Gamma = 2.2
) -> None:
    """Lock the camera's controls and save a still, to check framing, focus and saturation."""
    directory = run_dir("camera")
    webcam = V4l2Camera(device, settings=Settings(exposure_ms=exposure_ms))
    clock = MonotonicClock()
    start = clock.now() + 0.5
    _, frames = webcam.collect(start, start + 0.5, lambda frame: frame)
    webcam.close()
    still = np.max(frames, axis=0)
    cv2.imwrite(str(directory / "still.png"), still)
    clipped = float((still >= 250).any(axis=2).mean())
    write_json(
        directory / "result.json", {"controls": webcam.controls, "clipped": clipped}
    )
    logger.info(
        "Saved {}; {:.2%} of pixels at the top of the range",
        directory / "still.png",
        clipped,
    )


@app.command("map")
def map_command(
    host: Host = "nerves.local",
    device: Device = "/dev/video0",
    exposure_ms: Exposure = 20.0,
    gamma: Gamma = 2.2,
    level: Level = 1024,
    frames: Annotated[
        int, typer.Option(min=1, help="Frames averaged per channel.")
    ] = 4,
) -> None:
    """Light every channel on its own and record where it shows up (AC #3)."""
    directory = run_dir("map")
    with rig(host, device, exposure_ms, gamma) as setup:
        led_map, lit = map_leds(setup, level, frames)
    led_map.save(directory)
    lit_8bit = to_8bit(lit, gamma)
    cv2.imwrite(str(directory / "lit.png"), lit_8bit)
    cv2.imwrite(str(directory / "annotated.png"), annotate(led_map, lit_8bit))
    present = led_map.present()
    for region in present:
        logger.info(
            "{:>16} {:>8} area {:>4} px  snr {:>7.1f}{}",
            region.label,
            region.colour,
            region.area_px,
            region.snr,
            "  SATURATED" if region.saturated_px else "",
        )
    logger.info(
        "{} of {} channels lit something; map in {}",
        len(present),
        len(led_map.regions),
        directory,
    )


@app.command()
def suite(
    host: Host = "nerves.local",
    device: Device = "/dev/video0",
    exposure_ms: Exposure = 20.0,
    gamma: Gamma = 2.2,
    level: Level = 4095,
    seconds: Seconds = 10.0,
    map_dir: MapDir = None,
) -> None:
    """Flicker of every channel: static, re-latched at 30 and 10 Hz, re-shifted at 30 Hz, and BLANK-pulsed if BLANK is configured (AC #6)."""
    led_map = LedMap.load(map_dir or latest_map())
    directory = run_dir("suite")
    with rig(host, device, exposure_ms, gamma) as setup:
        result = flicker_suite(setup, led_map, level, seconds)
    result.table.write_parquet(directory / "regions.parquet")
    result.summary.write_csv(directory / "summary.csv")
    logger.info("Summary (rms and dip are fractions of the mean):\n{}", result.summary)


@app.command("calibrate")
def calibrate_command(
    host: Host = "nerves.local",
    device: Device = "/dev/video0",
    exposure_ms: Exposure = 20.0,
    gamma: Gamma = 2.2,
    level: Level = 4000,
    target: Annotated[
        str | None, typer.Option(help="chain/chip/channel to wobble.")
    ] = None,
    depth: Annotated[float, typer.Option(min=0.001, max=0.5)] = 0.01,
    freq_hz: Annotated[float, typer.Option(min=0.5, max=14.0)] = 5.0,
    seconds: Seconds = 10.0,
    map_dir: MapDir = None,
) -> None:
    """The noise floor of a static frame, and whether a small injected wobble on one channel shows up (AC #4)."""
    led_map = LedMap.load(map_dir or latest_map())
    key = None
    if target:
        chain, chip, channel = target.split("/")
        key = (chain, int(chip), int(channel))
    directory = run_dir("calibrate")
    with rig(host, device, exposure_ms, gamma) as setup:
        result = calibrate(setup, led_map, level, key, depth, freq_hz, seconds)
    write_json(
        directory / "result.json",
        {
            "target": result.target,
            "level": result.level,
            "depth": result.depth,
            "freq_hz": result.freq_hz,
            "floor_rms_median": result.floor_rms_median,
            "floor_rms_p90": result.floor_rms_p90,
            "steady": {"amplitude": result.steady.amplitude, "snr": result.steady.snr},
            "wobble": {"amplitude": result.wobble.amplitude, "snr": result.wobble.snr},
            "gain": result.gain,
            "detected": result.detected,
        },
    )
    logger.info(
        "Static floor: median rms {:.3%}, 90th percentile {:.3%}",
        result.floor_rms_median,
        result.floor_rms_p90,
    )
    logger.info(
        "{} wobble at {} Hz on {}: measured {:.3%} (snr {:.1f}; {:.3%} with none), {}",
        f"{result.depth:.1%}",
        result.freq_hz,
        "/".join(map(str, result.target)),
        result.wobble.amplitude,
        result.wobble.snr,
        result.steady.amplitude,
        "detected" if result.detected else "NOT detected",
    )


@app.command("blank-search")
def blank_search_command(
    host: Host = "nerves.local",
    device: Device = "/dev/video0",
    exposure_ms: Exposure = 20.0,
    gamma: Gamma = 2.2,
    level: Level = 2048,
    gpio: Annotated[
        list[str] | None, typer.Option(help="Candidate GPIO; repeat for more.")
    ] = None,
    map_dir: MapDir = None,
) -> None:
    """Drive candidate GPIOs high and low to find each chain's BLANK (AC #5)."""
    led_map = LedMap.load(map_dir or latest_map())
    gpios = tuple(gpio or ["GPIO22", "GPIO24", "GPIO17"])
    directory = run_dir("blank-search")
    with rig(host, device, exposure_ms, gamma) as setup:
        found, ratios = blank_search(setup, led_map, gpios, level)
    write_json(directory / "result.json", {"found": found, "ratios": ratios})
    logger.info("BLANK lines found: {}", found or "none")


@app.command()
def configure(
    chain: Annotated[str, typer.Argument(help="Chain id, e.g. main.")],
    host: Host = "nerves.local",
    blank_gpio: Annotated[
        str | None, typer.Option(help="BLANK GPIO label, or none.")
    ] = None,
    blank_pulse: Annotated[
        bool | None, typer.Option("--blank-pulse/--no-blank-pulse")
    ] = None,
    send_on_change: Annotated[
        bool | None, typer.Option("--send-on-change/--no-send-on-change")
    ] = None,
    max_rate_hz: Annotated[float | None, typer.Option(help="0 for no cap.")] = None,
    refresh_ms: Annotated[int | None, typer.Option(help="0 for no refresh.")] = None,
) -> None:
    """Change a chain's switches (see NeonPerceptron.Chain) until the Pi restarts."""
    given = {
        "blank_gpio": blank_gpio,
        "blank_pulse": blank_pulse,
        "send_on_change": send_on_change,
        "max_rate_hz": max_rate_hz,
        "refresh_ms": refresh_ms,
    }
    off = {"blank_gpio": "none", "max_rate_hz": 0, "refresh_ms": 0}
    changes = {
        name: None if name in off and value == off[name] else value
        for name, value in given.items()
        if value is not None
    }
    pi = SshPi(host)
    pi.configure(chain, **changes)
    logger.info(
        "{} switches: {}", chain, next(c for c in pi.chains() if c.id == chain).switches
    )


@app.command()
def release(host: Host = "nerves.local") -> None:
    """Stop any experiment and hand the chains back to the build."""
    SshPi(host).release()


def main() -> None:
    app()
