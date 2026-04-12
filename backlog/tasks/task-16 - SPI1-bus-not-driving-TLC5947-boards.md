---
id: TASK-16
title: SPI1 bus not driving TLC5947 boards
status: To Do
assignee: []
created_date: '2026-04-10 04:25'
updated_date: '2026-04-13 09:40'
labels:
  - bug
  - hardware
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

### Status (2026-04-13)

Brendan verified on the bench that all 5 SPI ports on the power distribution
board are wired correctly and working end-to-end. His test files are checked
in alongside this task: `backlog/tasks/brendan-config.txt` and
`backlog/tasks/brendan-spi-test.py`. This invalidates most of the earlier
debugging narrative (preserved in the "Superseded diagnostic notes" section
below for context). The remaining work is a software rewrite.

The five columns each sit on their own dedicated SPI bus (not a shared
SPI0/SPI1 data bus with per-column CS as we previously assumed). SPI3/4/5 are
BCM2711 auxiliary peripherals available on both the Pi 4 and CM4. The
reTerminal DM carrier exposes GPIO 0--27 on the same 40-pin header pinout, so
Brendan's bench configuration maps onto our hardware 1:1 --- assuming no
reTerminal-DM overlay silently claims any of the pins involved.

### Target configuration

| Column        | SPI bus | spidev     | MOSI | SCLK | XLAT (CE0) | Header pin (XLAT) |
| ------------- | ------- | ---------- | ---- | ---- | ---------- | ----------------- |
| input_left    | SPI0    | spidev0.0  | 10   | 11   | GPIO 8     | 24                |
| input_right   | SPI1    | spidev1.0  | 20   | 21   | GPIO 18    | 12                |
| hidden_front  | SPI3    | spidev3.0  | 2    | 3    | GPIO 0     | 27                |
| hidden_rear   | SPI4    | spidev4.0  | 6    | 7    | GPIO 4     | 7                 |
| output        | SPI5    | spidev5.0  | 14   | 15   | GPIO 12    | 32                |

(The column-to-bus assignment is arbitrary until we confirm the silkscreen
labelling on the power-dist board --- verify physically before locking it in.)

### XLAT handling: two options to evaluate

With `spiN-1cs` overlays, the kernel SPI driver owns CE0 and toggles it
automatically per transfer. TLC5947 latches on the rising edge of XLAT, and
CS returns HIGH at the end of each SPI transfer --- so in principle the
kernel-managed CS *is* a valid XLAT. Brendan's Python, however, also manually
pulses the pin via `RPi.GPIO` after `spi.xfer2`. Two interpretations:

- **A:** the kernel CS toggle is sufficient and his manual pulse is redundant
  (or the two are racing, and it happens to work).
- **B:** the kernel driver leaves CS in some non-toggling state with this
  overlay and the manual pulse is genuinely required.

First approach to try: **let Circuits.SPI handle XLAT via CS alone**, and
only add a manual `Circuits.GPIO` pulse if TLC5947 boards fail to latch. This
matches the simpler `spiN-1cs` + no extra GPIO code path and avoids fighting
the kernel driver.

### Resolution plan

#### 1. Software: overlays

Edit `config/rpi4/config.txt`:

- remove `dtoverlay=spi1-3cs`
- replace with:
  ```
  dtoverlay=spi0-1cs
  dtoverlay=spi1-1cs
  dtoverlay=spi3-1cs
  dtoverlay=spi4-1cs
  dtoverlay=spi5-1cs
  ```
- confirm `dtparam=spi=on` stays
- audio/I2S stay disabled (I2S on GPIO 18--21 would collide with SPI1/SPI6)

#### 2. Software: revert the 58b2a2c workaround

Commit 58b2a2c added the shared-SPI0-data-bus + XLAT-via-spidev1.x-dummy-transfer
hack. That architecture was wrong. Revert the parts of that commit that
touched `NeonPerceptron.Column` (remove `xlat_spi`, `xlat_spi_device`,
`xlat_mode`, the `pulse_xlat/2` helpers, the `:update` sync path added for
transfer ordering). `update_sync/2` can stay if other callers rely on it ---
check before removing.

#### 3. Software: column_configs in TestPattern

Rewrite `lib/neon_perceptron/builds/test_pattern.ex` `column_configs/0` to
use the per-column spidev devices from the table above (no `xlat_spi_device`).
Also re-enable the `Ticker` in `extra_children/0` for the blink test.

Equivalent rewrite needed in `lib/neon_perceptron/builds/v2.ex` (the
production build) once TestPattern is verified.

#### 4. Software: optional Circuits.GPIO XLAT path

Only if option A above fails: add an optional `:xlat_gpio` field to the
Column config that, when set, opens a `Circuits.GPIO` handle and pulses it
HIGH then LOW after each SPI transfer. Mirrors Brendan's Python. Don't build
this speculatively --- only if the simpler path doesn't latch.

#### 5. Hardware verification on device

1. SSH into `nerves.local` and run `cat /sys/kernel/debug/gpio` (debugfs may
   need enabling). Confirm none of GPIO 0, 4, 8, 12, 18 are claimed by
   reTerminal-DM-base or any other active overlay.
2. Confirm all 5 `/dev/spidev*.0` devices exist after the overlay change.
3. Run the TestPattern build with the Ticker re-enabled. Expected: each of
   the 5 positions blinks in a distinct hue.
4. If any column fails, scope its CS pin (header pin from the table above)
   while running a transfer loop --- confirm the kernel-managed CS is
   actually toggling. If it's static, switch to the Circuits.GPIO XLAT path
   (step 4).
5. Once all 5 columns blink, restore v2-accurate board counts (2/2/3/3/3 per
   Build.V2) in TestPattern and re-verify.
6. Switch the running build to Build.V2 and confirm the actual perceptron
   visualisation renders across all columns.

### Deliverables

- [ ] #1 `config/rpi4/config.txt` uses five `spiN-1cs` overlays
- [ ] #2 `NeonPerceptron.Column` and TestPattern no longer reference
      `xlat_spi_device` / shared-bus workaround
- [ ] #3 All 5 columns blink in TestPattern on real hardware
- [ ] #4 Root cause captured in commit message / task notes
- [ ] #5 Node-board pin pinout map saved next to `v2.0-output-assignments.pdf`
      (deferred --- still useful documentation but no longer blocking)

### Notes for the session with the device connected

- The device isn't attached right now. When it is, start with step 5.1
  (GPIO-ownership check on the current firmware) before making code changes
  --- quick confirmation that none of the XLAT pins are already claimed.
- OTA upload path: `mise exec -- env MIX_TARGET=rpi4 MIX_ENV=prod mix upload nerves.local`.
- Brendan's Python uses SPI mode 0, 10 MHz. `Circuits.SPI.open/2` defaults to
  mode 0; speed defaults to 1 MHz but can go higher. Start at the default
  and raise if needed.
- The `spidev0.1 → flashing green` regression noted earlier is moot ---
  spidev0.1 isn't used in the new scheme.

---

## Superseded diagnostic notes (2026-04-10 / 2026-04-11)

Kept for context. The architecture these notes assumed (shared SPI0 data
bus, shared SPI1 data bus, multi-CS overlays) is wrong; Brendan's bench
verification supersedes them. Skip this section unless you need the history.

### Original bench setup

power-distribution-v1.2 board with one TLC5947 node board on each of the 5
silk-screen-labelled positions. Previous overlay scheme: `spi0-2cs` +
`spi1-3cs`, mapping SPI0=spidev0.0 (3 daisy-chained), SPI1=spidev0.1,
SPI3=spidev1.0, SPI4=spidev1.1, SPI5=spidev1.2.

### Verified facts (from diagnostic session 2026-04-10)

1. CE0 (spidev0.0) drove XLAT for the SPI0 daisy chain correctly.
2. CE1 (spidev0.1) did not visibly latch anything.
3. SPI1 dummy transfers (spidev1.0/1.1) did not visibly latch anything.
4. SP3--5 boards remained in their power-on random PWM state.
5. SP0 board 1 sometimes "flashed" instead of going solid --- possible
   hardware issue with that specific board. Not blocking.

### Schematic analysis (2026-04-11)

From `power-distribution-v1.2.pdf`: GPIO16 (header pin 36) is marked NC on
the schematic, which would make `spidev1.2` under the `spi1-3cs` overlay
unable to drive CN6. In the new scheme spidev1.2 is not used, so this
finding is no longer blocking --- but still worth remembering if anyone ever
re-attempts the shared-bus approach.

### Hypothesis outcomes

- H1 (GPIO16 NC): confirmed at schematic level, now moot.
- H2--H8 (CE routing, driver timing, board defects, node-board pinout
  confusion, cabling inconsistency, assembly drift): all rendered moot by
  Brendan's 5-bus verification. Documented node-board pinout map (T7) is
  still a useful deliverable but no longer blocking.

### Commit 58b2a2c workaround

"Route SPI1 columns through SPI0 data bus with per-column XLAT" ---
architecturally wrong. Revert per the resolution plan above.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All 5 SPI columns drive TLC5947 boards correctly (test pattern blinks on all)
- [ ] #2 Root cause identified and documented
<!-- AC:END -->
