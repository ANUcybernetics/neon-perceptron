# Webcam rig

Measures the installation's LEDs with a webcam on weddle while driving the LED
Pi over SSH, so experiments run without anyone at the bench (TASK-24). This is
the weddle side; the Pi side is `NeonPerceptron.Lab`.

## Before the first run

- On weddle, install v4l-utils (`sudo apt install v4l-utils`). Claude Code's
  session isn't a desktop login, so it also needs `sudo usermod -aG video ben`
  and a fresh login to open the camera.
- The LED Pi is on wired Ethernet with firmware that includes
  `NeonPerceptron.Lab` (`mise run upload:leds-bench HOST=nerves.local`), and
  `ssh nerves.local` works from weddle.
- The webcam is fixed where it sees both chains, with the room dark or its light
  steady.

## Running

From this directory. Each command writes to `runs/<time>-<command>/`, and when
it finishes hands the chains back to the build.

```sh
uv run neon-rig check         # the Pi, its chains, MISO readback, the camera lock plan
uv run neon-rig camera        # lock the camera and save still.png to check framing
uv run neon-rig map           # light each channel alone: map.json, annotated.png
uv run neon-rig calibrate     # noise floor, and an injected 1% wobble at 5 Hz
uv run neon-rig blank-search  # which of GPIO 22, 24 and 17 blanks which chain
uv run neon-rig suite         # flicker static, re-latched, re-shifted
uv run neon-rig configure main --blank-gpio GPIO17 --blank-pulse
uv run neon-rig release       # stop whatever is running on the Pi
```

`--host` (or `NEON_PI_HOST`) and `--device` (or `NEON_CAMERA`) choose the Pi and
camera, and `--help` on each command lists the rest. `suite` adds a BLANK-pulsed
condition once every chain has a BLANK GPIO configured. Switches set with
`configure` last until the Pi restarts.

## Reading the results

Brightness is the weighted sum of a channel's pixels after undoing the camera's
gamma. `suite` reports, per condition and chain, the median and spread of each
channel's RMS flicker and deepest dip (as fractions of its mean),
`rms_vs_static` (flicker over the static frame's), and `mean_vs_static`
(brightness over the static frame's), which catches light a condition loses
without flickering.

Some measurement choices matter:

- **Exposure:** 20 ms covers about 20 PWM periods and two cycles of mains
  flicker.
- **Level:** `suite` lights everything at 4095 and `calibrate` at 4000. Near
  full duty, the PWM period can't beat against the exposure, which at mid levels
  adds noise the eye doesn't see.
- **Jitter:** the suite's timed conditions jitter their ticks by up to 10 ms, so
  a disturbance doesn't sit at the same point of every frame.
- **RGB LEDs:** the camera can't separate the three dies of an RGB LED, so those
  channels' regions overlap. That's why `calibrate` wobbles one channel with
  nothing else lit.

## Tests

```sh
uv run ruff check . && uv run ruff format --check . && uvx ty check && uv run pytest
```

The tests run each experiment against a simulated installation (`tests/sim.py`).
It models PWM on-time over the exposure, the light each XLAT latch blanks, BLANK
lines, and optionally a floating BLANK.
