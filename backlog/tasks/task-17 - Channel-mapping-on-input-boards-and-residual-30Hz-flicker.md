---
id: TASK-17
title: Channel mapping on input boards and residual 30 Hz flicker
status: To Do
assignee: []
created_date: '2026-04-15 10:00'
labels:
  - hardware
  - bug
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

### Context

While bench-testing the stock RPi 4B "LED board" running the Nerves firmware
with the `TestPattern` build (one TLC5947 chain of 2 input chips on
`spidev1.0`), two related issues surfaced that need follow-up.

Through systematic bisection we confirmed:

- **`Board.ex`'s channel mapping is correct per the design**: channels
  18–23 are the two "big LED" RGB triples (front B/G/R = 18/19/20; rear
  B/G/R = 21/22/23), channels 0–17 are the 18 noodle channels. This
  matches `backlog/tasks/v2.0-output-assignments.pdf`. No code change needed
  on that axis.
- **SPI wiring + overlays are correct**: `spidev0.0` and `spidev1.0` come
  up, both chains open in `:hardware` mode, `spi0-1cs` and `spi1-1cs`
  overlays apply, our own `config/rpi4/config.txt` reaches the boot
  partition.
- **SPI speed fix**: bumped `Chain.@spi_speed_hz` from 10 MHz to 25 MHz
  (commit `1598425`). At 10 MHz each 2-chip frame transfer took ~58 µs,
  producing a visible brightness disturbance on the TLC5947 outputs at
  refresh rates above ~10 Hz. At 25 MHz the transfer is ~14 µs and the
  disturbance is far less visible. TLC5947 datasheet max is 30 MHz.

### Open issues

#### 1. Input-board channel population (needs schematic review)

On the SPI1 chain's input boards we observed via per-channel testing (driving
one block of 6 channels at a time to full brightness):

- Channels 0–5: lit 2 noodles per chip
- Channels 6–11: lit 4 different noodles per chip (6 total in 0–11)
- Channels 12–17: **all dark** — no populated noodles
- Channels 18–23: lit the monochrome "big LED" on each chip (one red, one
  white — the two chips have different-coloured physical LED elements)

So input boards physically have 6 of 18 noodle positions populated, and the
big LED is a monochrome element in place of the three-pad RGB. This is
consistent with the V2 spec note that input nodes have no incoming edges to
visualise, and that "all three RGB pads are wired to the same LED element".

**However**, it is not clear *which* of the 6 big-LED channels (18–23) the
monochrome LED is actually wired to on each board. Under `TestPattern` at
30 Hz, chip 0 gets hue 0° (drives only channels 20 and 23 to full; rest to
zero) and chip 1 gets hue 180° (drives 18, 19, 21, 22 to partial). Observation:
**chip 0's big LED stays dark while chip 1's flashes.** This suggests chip 0's
monochrome LED is *not* wired to channels 20 or 23 — possibly wired to
another specific channel in 18–23, or the LED is dim enough at these specific
duty cycles that it doesn't visibly light.

Needs a quick benchtop sweep: drive each of channels 18–23 individually to
full brightness on each chip and record which physical LED element lights.
That fully characterises the input-board wiring and lets us adjust the
render function (or Board constants) to ensure input chip LEDs always light
when the logical activation is non-zero.

Related: the two input chips on the **SPI0 chain** (boards `{input, 1}` and
`{input, 3}` per `Builds.V2.chain_configs/0`) showed as dark during a partial
test while the hidden/output chips in the same chain were lit. Unclear
whether this is the same hue-to-channel issue surfacing again (input 1 and
input 3 get hues 2×360/11 ≈ 65° and 3×360/11 ≈ 98°, both green-biased, which
would drive different channels than hue 0), a power issue, or a ribbon-cable
problem at the input-to-hidden boundary on SPI0. Needs investigation once
SPI1 is fully characterised.

#### 2. Residual flicker during "on" phase at 30 Hz

Even after the 10 → 25 MHz SPI speed bump, Ben reports *some* remaining
flicker on the on-phase of TestPattern at 30 Hz. The bulk of the flicker is
gone — full-intensity static writes at 25 MHz and 30 Hz looked solid during
diagnostic tests — but in the normal render path there is still a faint
artefact.

Hypotheses to check:

- Push SPI clock to 30 MHz (datasheet max) for a final 20% reduction in
  transfer time.
- Consider whether the 33 ms `@frame_interval` in the Ticker / Trainer is
  being jittery under BEAM scheduling; if so, a regularised write cadence
  (timer-driven instead of `Process.sleep`) might help.
- Investigate whether decoupling capacitance on the TLC5947 rail is
  adequate for the instantaneous current swing at the start of each
  transfer. This is a hardware follow-up.
- Render-on-change: only push a frame when the network state actually
  differs from the last pushed frame. Halves or zeros the refresh rate at
  training equilibrium and eliminates spurious XLAT pulses.

### Supporting observations for next session

- The firmware on the LED board currently is:
  `MIX_TARGET=rpi4` (stock `nerves_system_rpi4` 2.0.1), `Builds.TestPattern`,
  hostname `nerves-<serial>.local` (default, not overridden yet — role and
  hostname env-var plumbing per the design spec is still to-do).
- `config/rpi4/fwup.conf` overrides the stock system's fwup.conf to bundle
  `spi0-1cs.dtbo` / `spi1-1cs.dtbo` and to pick up `config/rpi4/config.txt`
  (commit `3014897`).
- Diagnostic helpers used this session:

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
  per_board = List.duplicate(1.0, 24)  # or selectively: replace_at/3
  frame = per_board ++ per_board
  data = frame |> Enum.reverse() |> NeonPerceptron.Board.encode()
  state = :sys.get_state(NeonPerceptron.Chain.via(:input_left))
  Circuits.SPI.transfer!(state.spi, data)
  ```

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] Per-channel sweep on SPI1 input chips (channels 18–23 individually) to
      identify which TLC5947 channel drives the monochrome big LED on each
      chip
- [ ] Document the actual wiring: is it consistent across all input boards,
      or does each board use a different channel for its mono LED?
- [ ] Update `Builds.V2.render_node/2` (or `Board.ex` constants) so that
      input chip LEDs reliably light at non-zero activations, for whatever
      channel(s) the physical LED is wired to
- [ ] Repeat the per-channel sweep on SPI0's two input chips (`{input, 1}`
      and `{input, 3}`) to confirm they have the same wiring and are electrically
      healthy — rule out ribbon / power issues on the SPI0 input segment
- [ ] Decide whether the residual 30 Hz flicker warrants further work (try
      30 MHz SPI, timer-driven cadence, or render-on-change). Acceptable
      outcome: flicker is imperceptible under normal viewing, or documented
      as out-of-scope if imperceptibility is not achievable without hardware
      changes

<!-- AC:END -->
