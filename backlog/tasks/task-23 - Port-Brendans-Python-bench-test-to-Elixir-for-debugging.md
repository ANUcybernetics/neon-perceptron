---
id: TASK-23
title: Port Brendan's Python bench_test to Elixir for flicker debugging
status: In Progress
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
- [x] #1 `NeonPerceptron.PythonBench.run/0` (spawned in background) blinks chip 0 of `:main` with RGB sweep
- [x] #2 Byte packing verified identical to `brendan-spi-test.py` (4 host-side equivalence tests in `test/python_bench_test.exs`)
- [x] #3 Runs side-by-side with `Chain.ex` on same Pi without conflicting --- driver requires `Supervisor.terminate_child(NeonPerceptron.Supervisor, {NeonPerceptron.Chain, :main})` first to free SPI1 + GPIO 18, then `restart_child` to bring `Chain` back
- [x] #4 Bench test executed on Pi 5 (not Pi 4B as originally written --- the bench currently has Pi 5; Pi 4B retired post-TASK-22) and results documented below
- [ ] #5 Conclusion recorded: flicker is chain-level or Elixir-level (BLOCKED on stock-Pi script comparison --- a Python script on stock Raspbian reportedly drives this same hardware cleanly, undermining the SI-ceiling hypothesis below; need to find the script and compare)
<!-- AC:END -->

## Implementation Notes

### 2026-04-28 bench session (Pi 5, `nerves.local`)

#### Deviations from the original spec

Three intentional deviations from the literal "byte-for-byte port" once
the implementation met the bench:

1. **SPI speed: 1 MHz, not Brendan's 10 MHz.** Match `Chain.ex`'s
   `:main` envelope so PythonBench differs from `Chain.ex` only in
   Elixir-side abstractions (gamma, `Enum.reverse`, chain rendering).
   Diagnostic apples-to-apples.
2. **100 µs busy-wait between `Circuits.SPI.transfer!` and the XLAT
   pulse.** Pi 5's aux SPI (which `:main`/`spidev1.0` uses) returns
   from the kernel ioctl before the TX FIFO has fully drained ---
   without the wait, XLAT fires while bytes are still in flight and
   the chip latches a 36-bit-shifted snapshot. Same fix
   `Chain.ex` adopted in commit 0859213.
3. **Chain padding: 8 chips' worth of zeros prepended.** `:main` is
   a 9-chip chain. Sending only 36 bytes (one chip's worth) puts
   correct data in chip 0 but leaves chips 1--8 each latching a
   shifted snapshot of their upstream neighbour's previous GS
   register --- they strobe random data and visually drown out
   chip 0. Prepending 8 × 36 zero bytes keeps chips 1--8 dark so we
   can observe chip 0 in isolation.

#### Observations

| Configuration | Chip 0 of `:main` |
|---|---|
| 10 MHz, no FIFO drain wait, 36-byte transfer | not actually run --- earlier "0.5 Hz blinking" report was Chain.ex+TestPattern, not PythonBench (misattribution) |
| 1 MHz + 100 µs drain, 36 bytes | chip 0 garbage flickers; chips 1--8 strobe random shifts and dominate visually |
| 1 MHz + 100 µs drain + 8-chip blank padding | chips 1--8 dark; chip 0 RGB pulses smoothly-ish but with residual flicker, more than expected |
| Same as above, with `:input_left` Chain also terminated | residual flicker on chip 0 not noticeably reduced |
| (After power cycle, Chain.ex driving both chains) | chip 0 of `:main` "steadier than all the subsequent ones" |

#### Working hypothesis (not concluded)

A first-pass reading of the data above suggested chain-level signal
integrity (chip 0 steadier than chips 1--8 looks like SI degrading
along the ribbon). But this hypothesis is **not yet supported** ---
Ben recalls that a Python script on the stock Raspbian image drives
this same hardware *without* the residual flicker we see, which
implies the hardware path is capable of clean operation and
something software-side differs.

Candidate software-side differences worth checking before settling
on any conclusion:

- Kernel SPI driver version (Buildroot Nerves vs stock Raspbian)
  and aux-SPI FIFO/DMA handling
- `Circuits.SPI` ioctl flags / completion semantics vs Python
  `spidev`'s `SPI_IOC_MESSAGE`
- `Circuits.GPIO.write` latency and any in-flight scheduler
  preemption between the two XLAT writes vs Python `RPi.GPIO`
- BEAM scheduler activity during the 100 µs busy-wait or between
  frames (other Chains, Phoenix, etc., even with `:input_left`
  Chain terminated)
- CPU governor / clock scaling differences
- 100 µs FIFO drain may be insufficient on Pi 5 aux SPI ---
  worth retrying with 1 ms

#### Next step

Find the stock-Pi Python script that drives `:main` cleanly and
compare line-by-line against `python_bench.ex`. Memory points at
`btraw@raspberrypi.local:/home/btraw/tlc5947_test/bench_test.py` as
a known-good but Ben has indicated there's a separate script worth
tracking down too.

Once the working Python is in hand:

1. Diff its SPI/XLAT/timing setup against PythonBench
2. Apply each difference one-at-a-time to PythonBench until the
   flicker disappears
3. THEN draw the conclusion for AC #5
