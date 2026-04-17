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
