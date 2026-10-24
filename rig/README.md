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
  steady. Cover anything else that glows or changes in view, such as screens and
  status LEDs.

## Running

From this directory. Each command writes to `runs/<time>-<command>/` (including
`series.npz` with every capture, so a run can be analysed again), and when it
finishes hands the chains back to the build.

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
condition for the chains with a BLANK GPIO configured. Switches set with
`configure` last until the Pi restarts. `map` warns about regions that sit on
another chip's, which usually means a reflection or a screen; check
`annotated.png`.

## Reading the results

Brightness is the weighted sum of a channel's pixels after undoing the camera's
gamma. `suite` reports, per condition and chain, the median and spread of each
channel's RMS flicker and deepest dip (as fractions of its mean), and the
medians of each channel's flicker (`rms_vs_static`) and brightness
(`mean_vs_static`) over the static captures taken just before and after that
condition. The brightness ratio catches light a condition loses without
flickering, and bracketing cancels the drift as the LEDs warm up.

`calibrate` reports the measured gain on the injected wobble, the gain a perfect
camera would show (the Pi's level steps at 30 Hz and the exposure averages,
about 0.93), and their ratio, the `residual`. A residual far from 1 means the
camera's response isn't what the rig assumes (its gamma, or a YUYV range
stretch), so absolute flicker figures are off by that factor; ratios between
conditions are not.

Some measurement choices matter:

- **Exposure:** 20 ms covers about 20 PWM periods and two cycles of mains
  flicker.
- **Level:** `suite` lights everything at 4095 and `calibrate` at 4000. Near
  full duty, the PWM period can't beat against the exposure, which at mid levels
  adds noise the eye doesn't see. Both refuse to run if every region saturates;
  lower `--level` or dim the camera.
- **Warm-up:** both wait 20 s after lighting everything before measuring.
- **Jitter:** timed conditions move each tick by up to just under half a period,
  so a disturbance doesn't sit at the same point of every frame, and latching
  can't alias onto the wobble whatever the camera's frame rate. The
  calibration's null run latches the same way as the wobble, so if an alias did
  land there it would show in both.
- **RGB LEDs:** the camera can't separate the three dies of an RGB LED, so those
  channels' regions overlap. That's why `calibrate` wobbles one channel with
  nothing else lit.

## Tests

```sh
uv run ruff check . && uv run ruff format --check . && uvx ty check && uv run pytest
```

The tests run each experiment against a simulated installation (`tests/sim.py`).
It models PWM on-time over the exposure, the light each XLAT latch blanks, BLANK
lines, camera noise in 8-bit codes, and optionally a floating BLANK, LED warm-up
droop and a glowing patch in view.
