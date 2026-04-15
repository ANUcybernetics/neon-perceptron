---
id: TASK-17
title: >-
  Debug LED chain: most chips not rendering + input channel mapping + 30Hz
  flicker
status: To Do
assignee: []
created_date: '2026-04-15 10:00'
updated_date: '2026-04-15 05:57'
labels:
  - hardware
  - bug
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
### Context

Bench-testing the stock RPi 4B "LED board" running the Nerves firmware with
the `TestPattern` build surfaced a chain of issues, which this task now tracks
together. Earlier framing assumed only the two SPI1 input chips were
misbehaving; we now know the problem is broader.

### Current observations (2026-04-15 bench session)

With all 13 TLC5947 boards wired in per `Builds.V2.chain_configs/0` and
`TestPattern` running (hue-varying 1 Hz pulse across every chip):

- **SPI1 `:input_left` (2 input chips)**: both big LEDs pulse; chip 1's rear
  LED behaves like a real RGB (unexpected for an input board).
- **SPI0 `:main` (11 chips)**: only the first two chips' big LEDs pulse.
  Chips 2--10 (hidden front+rear and output) stay dark.
- **Residual fine flicker** is visible during the "on" portion of the pulse on
  every lit chip. Distinct from the 1 Hz blink --- driven by the 30 Hz SPI
  refresh cadence.

Running Brendan's reference Python script
(`backlog/tasks/brendan-spi-test.py`, unmodified) on the same wiring lights
**every chip** in the chain. The script only emits 36 bytes per frame, so it
lights the chain progressively as data shifts through successive transfers ---
but that still proves all 13 chips are electrically alive, accepting SPI data,
and latching.

So the problem is in our Elixir pipeline (TestPattern / Chain / Board.encode /
SPI configuration), not the hardware.

### What we've confirmed so far

- `Board.ex`'s channel mapping matches `v2.0-output-assignments.pdf`:
  ch 18--20 = front B/G/R, ch 21--23 = rear B/G/R, ch 0--17 = noodles.
- SPI wiring + overlays are correct: `spidev0.0`/`spidev1.0` come up, both
  chains open in `:hardware` mode, `spi0-1cs`/`spi1-1cs` overlays apply,
  `config/rpi4/config.txt` reaches the boot partition.
- Earlier SPI clock bump 10 MHz → 25 MHz (commit `1598425`) reduced but did
  not eliminate the on-phase flicker. Brendan's working script runs at
  10 MHz, so SPI speed is a candidate for the missing-chips issue too.
- Earlier "SPI0 input chips appear dark" observation was a TestPattern
  hue-coverage artefact (hues 33° and 65° have zero blue component, so mono
  LEDs wired to ch 18 or 21 would stay dark). Those chips are alive.

### Open issues, in dependency order

#### 1. Most `:main` chain chips not rendering under our code

Highest-priority unknown. Chips 2--10 of `:main` never light under
`TestPattern` / V2 render, but they do under Brendan's script. Plausible
causes:

- SPI clock rate (25 MHz vs Brendan's 10 MHz) is corrupting bits past the
  first few chips in the long daisy chain.
- A buffer-length or encoding bug in our Elixir path that truncates or
  reorders data specifically on multi-chip chains.
- A latch-timing issue with the `spiN-1cs` overlay that only manifests past
  chip 1 or 2 (less likely --- the overlay pulses CE0 once per transfer,
  all chips share XLAT).

We need `Diag` helpers to bisect this cheaply: push known static frames,
vary SPI speed, confirm which chip indices respond.

#### 2. Input-board channel population

Each input board has only 6 of 18 noodle positions populated (channels
0--11 light partial LEDs; 12--17 dark), and the "big LED" is a monochrome
element replacing the three-pad RGB. It is not yet clear *which* of the
six big-LED channels (18--23) the mono LED is actually wired to on each
board. A per-channel sweep will pin this down. Findings will drive a
change in `Builds.V2.render_node/2` (or `Board.ex`) so input chips light
reliably at non-zero activations regardless of which channel is wired.

#### 3. Residual flicker during "on" phase at 30 Hz

Still present after the 25 MHz bump. Hypotheses to check after (1) and
(2) resolve:

- Push SPI clock to 30 MHz (datasheet max) --- only if (1) doesn't push us
  *lower*.
- Consider BEAM scheduler jitter of the 33 ms `@frame_interval` (timer-driven
  cadence vs `Process.send_after`).
- Render-on-change: only push a frame when `NetworkState` differs from the
  last pushed frame. Halves or zeros refresh at training equilibrium and
  eliminates spurious XLAT pulses.
- Decoupling capacitance review on the TLC5947 rail (hardware follow-up).

### Supporting observations / tooling

- Current firmware on the LED board:
  `MIX_TARGET=rpi4` (stock `nerves_system_rpi4` 2.0.1), `Builds.TestPattern`,
  hostname `nerves.local` (default).
- `config/rpi4/fwup.conf` overrides the stock system's fwup.conf to bundle
  `spi0-1cs.dtbo`/`spi1-1cs.dtbo` and pick up `config/rpi4/config.txt`
  (commit `3014897`).
- Diagnostic helpers used this session (soon to be replaced by `Diag`):

  ```elixir
  # Kill the Ticker (supervisor-level so it stays dead)
  sup = Process.whereis(NeonPerceptron.Supervisor)
  {id, _, _, _} = Supervisor.which_children(sup) |> Enum.find(fn {id, _, _, _} ->
    id == NeonPerceptron.Builds.TestPattern.Ticker
  end)
  Supervisor.terminate_child(sup, id)

  # Restart it
  Supervisor.restart_child(sup, NeonPerceptron.Builds.TestPattern.Ticker)

  # Push one static frame manually
  per_board = List.duplicate(1.0, 24)
  frame = per_board ++ per_board
  data = frame |> Enum.reverse() |> NeonPerceptron.Board.encode()
  state = :sys.get_state(NeonPerceptron.Chain.via(:input_left))
  Circuits.SPI.transfer!(state.spi, data)
  ```
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Build `NeonPerceptron.Diag` helpers (pause/resume Ticker; dark/light/light_all; chip_count) and `Chain.push_raw/2` to support all bench diagnostics
      identify which TLC5947 channel drives the monochrome big LED on each
      chip
- [ ] #2 Identify root cause of chips 2--10 of `:main` not rendering under our code while Brendan reference script lights the full chain; apply fix so all 11 `:main` chips render correctly under TestPattern
      or does each board use a different channel for its mono LED?
- [ ] #3 Per-channel sweep across all 4 input chips (2 on SPI1, 2 on SPI0) driving channels 18--23 individually; record which channel(s) drive the mono big LED on each board
      input chip LEDs reliably light at non-zero activations, for whatever
      channel(s) the physical LED is wired to
- [ ] #4 Update `Builds.V2.render_node/2` (or `Board.ex`) so input chip LEDs reliably light at non-zero activations regardless of which big-LED channel is wired
      and `{input, 3}`) to confirm they have the same wiring and are electrically
      healthy — rule out ribbon / power issues on the SPI0 input segment
- [ ] #5 Decide on residual 30 Hz flicker: either further work lands (30 MHz SPI / render-on-change / timer cadence) to make it imperceptible, or it is documented as out-of-scope
      30 MHz SPI, timer-driven cadence, or render-on-change). Acceptable
      outcome: flicker is imperceptible under normal viewing, or documented
      as out-of-scope if imperceptibility is not achievable without hardware
      changes
<!-- AC:END -->
