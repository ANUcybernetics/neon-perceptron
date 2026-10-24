---
id: TASK-24
title: Build a closed-loop webcam rig for unattended LED experiments
status: To Do
assignee: []
created_date: '2026-10-24T00:59:00Z'
due_date: '2026-10-26'
labels:
  - hardware
  - debugging
  - tooling
dependencies: []
references:
  - docs/build_v2_hardware.md
  - backlog/tasks/power-distribution-v1.2.pdf
  - lib/neon_perceptron/chain.ex
  - lib/neon_perceptron/diag.ex
  - https://www.ti.com/lit/ds/symlink/tlc5947.pdf
priority: high
type: task
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Every LED diagnosis so far has depended on Ben standing at the installation and reporting what he saw, and he flagged those reports as unreliable himself (2026-04-15). Conclusions flip-flopped as a result: 25 MHz "fixing" flicker, the aux-SPI "36-bit shift", Python versus Elixir. The installation will sit beside weddle (the workstation Claude runs on), close enough for one standard USB webcam on weddle to see it. With the LED Pi on the LAN, Claude can flash and drive the Pi, record the LEDs and measure them, so bench sessions become repeatable experiments with numbers and Ben doesn't have to be there.

## Findings these experiments should test

From a deep dive on 2026-10-24 (session logs, schematic, TLC5947 datasheet SBVS114B, kernel source). Not yet recorded anywhere else in the repo.

- Every XLAT rising edge forces all TLC5947 outputs off until the next PWM period (4096 ticks of a 2.4--5.6 MHz internal oscillator, so 0.7--1.7 ms), and the counter isn't reset. Re-latching at 30 Hz costs bright channels 0--3% of each frame's light at random, independently per chip. The 2026-04-15 rate test (identical bytes, flicker rising with refresh rate, solid with no writes) fits this. Pulsing BLANK around XLAT restarts the period.
- Tracing the schematic's vectors shows each 32-pin connector on the distribution board is its own bus with the same pinout: pin 17 data, 20 clock, 16 latch, 14 one spare GPIO per bus (GPIO 22 on the SPI0 connector, GPIO 24 on the SPI3 connector, GPIO 17 on the SPI1 connector). Pin 14 is very probably BLANK and the firmware never drives it. Pins 1--10 are VCC, 23--32 GND. It is not a passive parallel breakout, as some older notes claim.
- Brendan cut the board down to the SPI0 and SPI3 connectors and soldered the SPI3 one so it carries SPI1. Which pads, and whether the old SPI3 traces (GPIO 0/2/3/24) were cut, is unrecorded. The worst flicker followed that connector across chain lengths, latch methods and Pi models (2026-04-14 to 04-17).
- Chip 6 on `:main` (the first output board) strobed at about 2 Hz, roughly 75% on, on static full-on frames on both the Pi 4 and the Pi 5. Probably thermal or power on that board.
- Signal margins are thin. VIH is 0.7 x VCC (3.5 V if the node boards run the chips at 5 V) against the Pi's 3.3 V, there are no pull resistors anywhere (TLC5947 inputs leak only +/-1 uA), the clock and latch run unterminated through nine boards of ribbon, and the Pi 5 base device tree drives its SPI pins at 12 mA with fast slew.
- The Python comparisons were never like-for-like (`bench_test.py` blinks all-on/all-off twice a second, which hides both bit errors and latch blanking), and the "aux SPI returns before the last bits are out" theory isn't supported by the spi-bcm2835aux source.

## Measurement constraints

The camera must integrate many PWM periods, as the eye does. Use an exposure of about 20 ms: roughly 20 PWM periods, and a whole number of periods of the 100 Hz light flicker from 50 Hz mains. Short exposures alias the PWM into flicker that isn't there. Lock exposure, gain, white balance and focus; avoid saturated LEDs (lowest gain, slight defocus, ND gel or moderate test brightness); mount the camera rigidly; keep the room dark or the lighting stable. At 30 fps the camera resolves flicker up to 15 Hz, which covers the visible band.

## Setup

Ben provides the installation beside weddle, the LED Pi (a Pi 4 is preferred) on wired Ethernet reachable from weddle as `nerves.local` or a fixed IP, and one USB webcam on weddle framing both chains, including chips 6--8 of `:main` and some noodles. Optional extras: a smart plug on the LED supply (and ideally the Pi) so Claude can power-cycle remotely, and a readback wire from the last chip's SOUT to the Pi's MISO (through a divider if VCC is 5 V), which gives bit-exact error counts for every transfer.

On weddle (2026-10-24): `v4l-utils` isn't installed (`v4l2-ctl` is needed to lock camera controls); ffmpeg, gstreamer and uv are present; ben isn't in the `video` group, which only matters if Claude Code runs outside the desktop session; `nerves.local` didn't resolve from weddle in May.

Related: TASK-17 (flicker), TASK-21 (channel map, which the rig can produce automatically), TASK-23 (PythonBench).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 From weddle, Claude can OTA-flash the LED Pi and run IEx commands on it with nobody at the bench
- [ ] #2 Webcam frames of the installation are captured on weddle with exposure, gain, white balance and focus locked, and no LED region saturates at test brightness
- [ ] #3 Every LED in frame has a located image region mapped to its chain, chip and channel (including colour and noodle polarity), produced by lighting channels one at a time
- [ ] #4 The pipeline reports its noise floor on a static frame and detects a deliberately injected 1% brightness wobble at 5 Hz on a single LED
- [ ] #5 Each chain's BLANK line is identified by driving candidate GPIOs 22, 24 and 17 high, or ruled out
- [ ] #6 Flicker metrics are recorded for both chains for a static frame, the same frame re-latched at 30 Hz and at 10 Hz, the same frame re-shifted at 30 Hz without latching, and (if BLANK is found) re-latched with BLANK pulsed around XLAT
- [ ] #7 Ben's judgement of visible flicker is compared once against the camera metric and the threshold is recorded in the task notes
<!-- AC:END -->
