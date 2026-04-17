---
id: TASK-23
title: Port Brendan's Python bench_test to Elixir for flicker debugging
status: To Do
assignee: []
created_date: '2026-04-17 10:00'
labels:
  - hardware
  - debugging
dependencies:
  - TASK-22
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
### Motivation

Both Pi 4 and Pi 5 exhibit persistent flicker on the 9-chip `:main`
chain while `:input_left` (2 chips) runs cleanly. Root cause is
unknown --- could be chain-level (ribbon signal integrity, power rail
sag under 9-chip PWM load) or could be a subtle bug in
`NeonPerceptron.Chain` / `NeonPerceptron.Board`.

Brendan's single-chip Python script (`backlog/tasks/brendan-spi-test.py`
and the fuller `bench_test.py` on `btraw@raspberrypi.local:/home/btraw/tlc5947_test/`)
is the known-working reference. If we can reproduce Brendan's exact
SPI + XLAT behaviour from Nerves --- same speed, same packing, same
XLAT dance --- and compare against `Chain.ex`, we can conclusively
answer "is the bug in my Elixir, or in the hardware?"

Running the actual Python on Nerves is expensive (requires forking
`nerves_system_rpi4`/`rpi5`, enabling Buildroot's `PYTHON3` package,
porting `RPi.GPIO` to `libgpiod`, and maintaining the fork). A
byte-for-byte Elixir port of `bench_test.py` gives the same
diagnostic value at far lower cost.

### What to build

A new module `NeonPerceptron.PythonBench` in
`lib/neon_perceptron/python_bench.ex`, independent of the main app
supervision tree. Started manually from IEx.

Key design: match Brendan's Python as literally as possible. No
gamma correction. No `Enum.reverse`. No multi-chip rendering. Just a
single-chip RGB sweep, packed and clocked exactly the way the Python
does it.

Specifically:

- `Circuits.SPI.open("spidev1.0", speed_hz: 10_000_000, mode: 0)`
  --- Brendan's 10 MHz, not `Chain.ex`'s 1 MHz. (Worth trying 1 MHz
  too in a variant.)
- `Circuits.GPIO.open("GPIO18", :output, initial_value: 0)` for
  manual XLAT. Assumes the kernel SPI driver hasn't claimed GPIO 18
  (i.e., `cs0_pin=25` in the overlay or XLAT wire rerouted).
- `set_leds/2` that takes a 24-element integer list (values 0..4095)
  and does the exact byte packing from `brendan-spi-test.py` lines
  44-63:

  ```python
  buffer = [0] * 36
  byte_idx = 35
  for i in range(0, 23, 2):
      val1 = min(led_array[i], 4096)
      val2 = min(led_array[i+1], 4096)
      buffer[byte_idx]   = (val1 & 0xFF)
      buffer[byte_idx-1] = ((val1 >> 8) & 0x0F) | ((val2 << 4) & 0xF0)
      buffer[byte_idx-2] = (val2 >> 4) & 0xFF
      byte_idx -= 3
  ```

- `spi.xfer2(buffer)` → `Circuits.SPI.transfer!/2`.
- Manual XLAT pulse: `write(xlat, 1); :timer.sleep(0); write(xlat, 0)`.
  Brendan uses `time.sleep(0.000001)` (1 µs); BEAM `:timer.sleep(0)`
  yields the scheduler and is effectively ≥1 µs on modern hardware.
- Main loop: RGB PWM values cycling with the exact deltas from
  Brendan's script (`Rpwm_delta=384, Gpwm_delta=221, Bpwm_delta=140`),
  bouncing between 400 and 3700.

Usage:

```elixir
iex> NeonPerceptron.PythonBench.start_link()   # blinks chip 0 of :main
iex> NeonPerceptron.PythonBench.stop()
```

### What this resolves

- **If the port flickers identically to `Chain.ex`:** root cause is
  NOT our Elixir abstraction. Hardware (ribbon SI, power rails,
  chain-end connections) is the problem.
- **If the port is clean but `Chain.ex` flickers:** bug is in one of
  our abstractions. Likely suspects (in order):
  - `Board.encode/1` packing order (we pack `<<val::12>>` left-to-right;
    Python packs into a pre-allocated 36-byte buffer right-to-left).
    These SHOULD produce identical wire bytes but the bit-level trace
    is worth auditing.
  - `channel_values |> Enum.reverse()` in `Chain.render_and_send/2`.
  - Gamma correction in `Board.encode/1` (`^2.8`) --- Brendan's Python
    doesn't gamma-correct. Unlikely to cause flicker but different
    brightness scale.
  - Chain-level state (9 chips × 24 channels = 216 values) vs
    Brendan's single-chip (24 values). If `Chain` is fine for
    1 chip, it should be fine for 9.

### Where it lives in the repo

- `lib/neon_perceptron/python_bench.ex` --- the module.
- NOT in the supervision tree. Started manually from IEx. No
  PubSub subscription, no ticker.
- Runs only on the `:main` chain (SPI1 single-chip test for now).
  An `:input_left` variant (SPI0) is trivial to add later if needed.

### Non-goals

- Not trying to port the *neural network renderer* from Python.
  Brendan's Python doesn't have one --- it's just a PWM sweep.
- Not trying to be "a better Chain" --- this is strictly a
  diagnostic tool.
- Not trying to reach feature parity with `Chain.ex`. The Chain
  abstraction is the right production path; this is a reference
  implementation to compare against.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `NeonPerceptron.PythonBench.start_link/0` blinks chip 0 of `:main` with RGB sweep
- [ ] #2 Byte packing verified identical to `brendan-spi-test.py` (compare hex dump of first buffer)
- [ ] #3 Runs side-by-side with `Chain.ex` on same Pi without conflicting (only one active at a time)
- [ ] #4 Bench test executed on Pi 4B and result (flicker present / absent) documented in this task's notes
- [ ] #5 Conclusion recorded: flicker is chain-level or Elixir-level
<!-- AC:END -->
