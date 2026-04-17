---
id: TASK-22
title: Migrate LED driver to RPi 5 with RP1-native SPI
status: To Do
assignee: []
created_date: '2026-04-17 03:00'
labels:
  - hardware
  - nerves
  - enhancement
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
### Context

The V2 installation currently runs the LED driver on a stock Pi 4B (the
`rpi4` Nerves target). Bench testing on 2026-04-17 uncovered two issues
worth noting:

1. **Signal integrity at 25 MHz.** Nerves at 25 MHz SPI drives chips 0--3
   on the 9-chip `:main` chain but leaves chips 4--8 dark. The fix was
   dropping `@spi_speed_hz` to 1 MHz in `lib/neon_perceptron/chain.ex`,
   matching the Python gold standard (`test_spi3_all_on.py`,
   `bench_test.py` on the stock-Pi SD card). At 1 MHz a 9-chip frame
   takes ~2.6 ms, well inside the 33 ms tick, so there's no practical
   penalty on a 9-chip chain. This fix is sufficient for V2.

2. **Manual-XLAT workaround.** On BCM2711 the kernel SPI CS pulse
   doesn't cleanly serve as TLC5947 XLAT, so the Elixir `Chain`
   module pulses XLAT manually on `GPIO 8` (`:input_left`) and
   `GPIO 18` (`:main`) via `Circuits.GPIO`. Those two GPIO pins are
   hardwired into the installation. This works, but ties up two GPIOs
   that a Pi 5 wouldn't need.

### Why move to Pi 5

- RP1's SPI controllers toggle CS as a clean end-of-transfer pulse, so
  `Chain` could latch via kernel CS and we could drop the manual XLAT
  GPIOs (freeing GPIO 8/18 for other use, and shortening the latch
  latency slightly).
- RP1 has cleaner SPI signal integrity at the CPU side --- probably
  doesn't change the cable-side signal-integrity cliff, but removes it
  as a variable when tuning clock speed.
- V3 scale (TASK-20) wants multi-Pi distribution on Pi 5 eventually, so
  getting a single Pi 5 working is a prerequisite.

### Previous attempt (commit 1fdc80d, 2026-04-16)

Scaffolded an `rpi5` target (`nerves_system_rpi5`, `config/rpi5/`).
Found that `spi3-1cs` doesn't create a device on RP1 and parked the
work. **That blocker is now a red herring:** the 2026-04-17 bench
sessions confirmed the physical wiring is **SPI0 + SPI1**
(`input_left` → `spidev0.0`, `main` → `spidev1.0`), matching what
`bench_test.py` drives on the same hardware. Both SPI0 and SPI1 exist
on RP1, so the overlay problem should disappear.

Verify by reading `/home/btraw/tlc5947_test/bench_test.py` on the
stock-Pi SD card --- it's the gold standard.

### Open concerns

- **Circuits.GPIO cdev backend.** Nerves' `Circuits.GPIO` uses the
  kernel cdev interface, which is stricter about pin ownership than
  the classic RPi.GPIO / `/dev/gpiomem` path that the Python bench
  uses. If we decide to keep manual XLAT on Pi 5, confirm
  `Circuits.GPIO.open("GPIO8", ...)` and `("GPIO18", ...)` aren't
  blocked by any kernel driver claim on RP1.
- **Ticker behaviour.** Still-unconfirmed suspicion that the ticker
  pipeline on the Nerves side isn't fully latching per tick even with
  the 1 MHz fix. Worth re-verifying once the 1 MHz firmware is
  running at the bench.

### What needs to happen

1. Update `config/rpi5/config.txt` to enable `spi0-1cs` + `spi1-1cs`
   (drop the `spi3-1cs` line --- that was the red herring).
2. Decide XLAT strategy on Pi 5:
   - **Option A:** keep manual XLAT on GPIO 8/18 (matches the
     installed wiring, minimal code change). Confirm `Circuits.GPIO`
     can claim those pins on RP1.
   - **Option B:** rely on kernel CS as XLAT and disconnect the two
     manual-XLAT wires physically. Bigger install change but cleaner.
3. Build and upload the `rpi5` firmware. If the prebuilt
   `nerves_system_rpi5` artifact works, no Buildroot rebuild needed;
   otherwise rebuild the system with the overlay patched in.
4. Re-run the `Diag.light_all` / `Diag.flood_oversize` smoke tests.
   Then sweep SPI clock (1, 5, 10, 25 MHz) to see if RP1 + ribbon
   chain holds at a higher rate than BCM2711 did. Update
   `@spi_speed_hz` to the highest reliable value.
5. Revisit TASK-21 (per-channel characterisation) on Pi 5 if anything
   about the SPI-to-chip mapping changes.

### References

- `config/rpi5/config.txt` (existing scaffold)
- `lib/neon_perceptron/chain.ex` (`@spi_speed_hz`, `open_xlat/1`)
- commit 1fdc80d (previous attempt)
- `bench_test.py` on the stock-Pi SD card (gold-standard wiring proof)
- TASK-20 (multi-Pi power-distribution redesign, depends on this)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `rpi5` Nerves target boots and runs the V2 build end-to-end
- [ ] #2 Both `:input_left` and `:main` chains drive all chips correctly at 1 MHz
- [ ] #3 XLAT strategy decided and documented (manual GPIO vs. kernel CS)
- [ ] #4 SPI clock speed tuned on RP1 and the working value committed
- [ ] #5 `config/rpi5/config.txt` updated; `spi3-1cs` overlay removed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
### 2026-04-17 bench session findings

Attempted migration. `rpi5` firmware builds and boots. `:input_left`
(SPI0) works cleanly, but `:main` has a chain-end anomaly we couldn't
resolve. Parked with scaffolding committed (commit 6993b9f).

**Important:** the original "Pi 4 works, migrate to Pi 5 for cleanliness"
framing turned out to be wrong. Pi 4B *also* has persistent flicker on
`:main` (and in fact the Pi-5 swap was motivated by wanting to fix
that flicker, not just tidy code). Both Pi 4 and Pi 5 exhibit flicker
on `:main` but none on `:input_left` --- so the flicker is almost
certainly a chain-level issue (power, ribbon, signal integrity) not
an SPI-controller issue. Pi 5 on top adds its own chain-end data
anomaly. There is no "working option" right now; both targets have
problems.

#### Correct re-framing of task-22's original premise

Original notes assumed "SPI1 exists on RP1, so the overlay problem
should disappear." That was wrong. RP1's device-tree aliases expose
`spi0`, `spi2`, `spi3`, `spi5` --- but **no `spi1` alias via stock
overlays**. The `spi1-1cs` overlay silently produces no device on Pi 5.

However, RP1 *does* have an internal `spi1` controller (labelled in
`bcm2712-rpi.dtsi`), with pinmux function `rp1_spi1_gpio19` fixed to
GPIO 19/20/21 for MISO/MOSI/SCLK (exactly the pins V2's `:main` chain
is wired to). It just lacks a shipped overlay. We wrote a custom one:
`config/rpi5/overlays/spi1-1cs-pi5.dts`. After compiling it via a
pre-firmware mise task and shipping it in the boot partition (via
custom `fwup.conf` + `${NERVES_APP}` path), `/dev/spidev1.0` shows up
on Pi 5 and `Circuits.SPI.open/2` succeeds.

#### Unresolved anomaly on :main

With both kernel-CS-as-XLAT (original plan) and manual XLAT on
GPIO 8/18 (the Pi 4 approach ported to Pi 5), the `:main` chain shows
the same pattern:

- `Diag.dark_all()` works --- all chips go dark.
- `Diag.flood_oversize(:main, 3, 1.0)` lights every chip on the chain,
  **but with persistent frame-to-frame flicker** not seen on Pi 4.
- `Diag.light_chip(:main, N, 1.0)` for N in 0..6 works correctly.
- `Diag.light_chip(:main, 7, 1.0)` partially lights chip 7 (RGBs + one
  noodle pair) and unexpectedly also lights bits of chip 8.
- `Diag.light_chip(:main, 8, 1.0)` lights *nothing* --- chip 8 won't
  accept targeted data.
- `Diag.light_chip(:main, 6, 1.0)` cleanly lights chip 6 but also
  persistently lights chip 7's 4 noodle channels.

That manual-XLAT and kernel-CS give identical results rules out
XLAT-edge timing (which was the bug on Pi 4). The flicker under
flood_oversize (where every bit is `1` and no specific ordering matters)
rules out a simple K-bit truncation or shift theory --- the instability
is in the base SPI-to-chain transport, not pattern-dependent.

#### Candidate root causes (ordered by likelihood)

1. **Physical ribbon / chain-end continuity issue specific to the last
   1-2 chips.** Pi 4's BCM2711 SPI may be more forgiving of marginal
   signal integrity than RP1. Worth physically inspecting the SOUT→SIN
   connections between chips 7, 8, and 9 on V2, and scope-probing MOSI
   at each chip position during a transfer.
2. **RP1 SPI1 signal integrity at the end of long transfers.** RP1's
   SPI controllers drive differently than BCM2711; edge rates, pull
   strength, or DMA chunking behaviour could cause marginal bits at
   the tail end of transfers to corrupt. Try dropping SPI clock from
   1 MHz to 500 kHz or 250 kHz.
3. **Custom overlay subtlety.** The overlay might be missing a
   property (e.g. `spi-cpol`, `spi-cpha`, `spi-max-frequency` per-device
   vs per-bus, `cs-setup-delay-ns`) that causes RP1 to behave subtly
   differently from BCM2711 on SPI1. Compare against a known-working
   Pi-5 SPI1 setup (e.g. from Brendan's `bench_test.py` if that runs
   on a Pi 5 rather than Pi 4).

#### What was committed

- `config/rpi5/overlays/spi1-1cs-pi5.dts` (custom overlay source)
- `mise.toml`: `compile:rpi5-overlays` pre-task
- `config/rpi5/config.txt`: `spi0-1cs,cs0_pin=26` + `spi1-1cs-pi5,cs0_pin=25`
  (manual XLAT config, mirrors Pi 4)
- `config/rpi5/fwup.conf`: overlay baked into boot partition via
  `${NERVES_APP}` path

All Elixir code (`Chain`, `Builds.V2`, `Builds.TestPattern`) is target-
agnostic --- same source compiles for `rpi4` and `rpi5`.

#### Next-session suggested path

Given both Pi 4 and Pi 5 flicker on `:main`, the chain-level
investigation is the higher-value next step, not more SPI-controller
hacking:

1. **Scope-probe MOSI and SCLK at the last ribbon connector** (input at
   chip 9) during a full-frame transfer. Compare edge quality against
   the same signals at chip 1. If signal integrity degrades across the
   ribbon, that's the flicker root cause regardless of Pi model.
2. **Scope the power rails on the output column boards** (chips 6-8)
   during a frame update. Large current swings from 9 chips × 24 PWM
   channels could be causing brown-outs on the distribution board.
3. **Physically inspect the SOUT→SIN connections between chips 7, 8,
   and 9.** Ribbon seating, solder joints, continuity check. Any
   marginal connection would be our first hypothesis.
4. Run the per-code-chip sweep
   (`for i <- 0..8 do dark_all(); light_chip(:main, i, 20, 1.0)`)
   on both Pi 4 and Pi 5 and record which *physical* chip lights for
   each code index. Confirms whether the ribbon routing matches
   `Chain.boards` config.
5. **Only after ruling out chain/power/hardware:** drop `@spi_speed_hz`
   from 1 MHz to 250 kHz on both targets and see whether flicker
   changes. If not, SPI controller itself is clean.
6. If chain-side investigation points at Pi-5-specific controller
   differences, dig into RP1 SPI1 driver internals / try a different
   custom overlay configuration.
<!-- SECTION:NOTES:END -->
