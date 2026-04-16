---
id: TASK-16
title: SPI1 bus not driving TLC5947 boards
status: To Do
assignee: []
created_date: '2026-04-10 04:25'
updated_date: '2026-04-16 04:09'
labels:
  - bug
  - hardware
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
### Status (2026-04-13)

Brendan verified on the bench that all 5 SPI ports on the power distribution
board are wired correctly and working end-to-end (test files checked in
alongside this task: `backlog/tasks/brendan-config.txt` and
`backlog/tasks/brendan-spi-test.py`). That rules out a board-level bug.

However, Brendan's 5-dedicated-SPI-bus scheme **cannot coexist with the
reTerminal DM display**. SPI3 requires GPIO 2/3 (ALT4); the reTerminal DM
carrier already uses GPIO 2/3 as i2c1 for the PCF857x GPIO expander, which
the DSI panel driver references for reset and LCD power-enable. The two alt
functions are mutually exclusive at the pin mux level. GPIO 2/3 cannot be
both. Keeping the display means SPI3 is not available.

Rather than fight the pin mux (which would require forking
`reTerminal-dm-base.dts` to move PCF857x onto a bit-banged i2c bus and a
full Nerves system rebuild), the new plan exploits the fact that the
TLC5947 is designed for long daisy chains. **One SPI bus can drive all 13
boards.** One XLAT pulse latches the whole display atomically.

This is architecturally simpler than the 5-bus scheme *and* avoids the
GPIO conflicts. The cost is a physical ribbon-cable path threading SOUT of
the last chip in one column into SIN of the first chip in the next.

### Target architecture: single daisy chain

One SPI bus, one XLAT, 13 TLC5947 boards in series:

```
SPI0.MOSI (GPIO 10) → board 1 SIN → board 2 SIN → ... → board 13 SIN
SPI0.SCLK (GPIO 11) → shared SCLK to all 13 boards
SPI0.CE0  (GPIO  8) → shared XLAT to all 13 boards
```

Chain order (fold hidden_front and output into the middle rather than the
ends to keep cable runs short; final order depends on the physical layout
of the columns and which way the ribbon cable naturally routes):

| chain offset | logical column | board count |
| ------------ | --------------- | ----------- |
| 0             | input_left     | 2           |
| 2             | hidden_front   | 3           |
| 5             | output         | 3           |
| 8             | hidden_rear    | 3           |
| 11            | input_right    | 2           |

(Adjust to match the actual ribbon routing once laid out on the structure.)

Per-frame update: build one 312-byte buffer (`13 × 24 bytes`), one
`Circuits.SPI.transfer/2`, one XLAT pulse. At 10 MHz SPI, ~250 µs per
frame. At 60 fps frame pacing that's ~1.5% of the budget.

All 13 boards latch simultaneously --- actually better than the 5-bus
scheme, which risks inter-column tearing if XLATs don't fire in the same
tick.

### Fallback: two chains on SPI0 + SPI1

If the physical ribbon path for a single 13-board chain is awkward (e.g.,
the two "input" columns are on opposite sides of the structure and the
cable run doesn't want to thread through the middle), split into two
chains:

- **SPI0** (GPIO 10/11/8): upper row
- **SPI1** (GPIO 20/21/18): lower row

Exact column-to-bus assignment decided by physical layout. Still no
GPIO 2/3 conflict, still no system rebuild, still native TLC5947
daisy-chaining.

### What this rules out

- The commit 58b2a2c workaround (shared SPI0 data + dummy-transfer XLAT on
  spidev1.x) --- revert.
- Independent per-column latching --- the renderer pushes all columns per
  frame anyway, so this is fine.
- `xlat_spi_device`, `xlat_spi`, `xlat_mode` in `NeonPerceptron.Column` ---
  remove.

### Resolution plan

#### 1. Software: overlays

Edit `config/rpi4/config.txt`:

- remove `dtoverlay=spi1-3cs`
- add `dtoverlay=spi0-1cs` (and `dtoverlay=spi1-1cs` only if falling back
  to 2 chains)
- confirm `dtparam=spi=on` stays
- leave `reTerminal-dm-base`, `enable_uart=1`, i2c1/i2c3 overlays untouched

#### 2. Software: collapse Column into a single chain driver

The `NeonPerceptron.Column` GenServer currently models one column = one SPI
device. Either:

- **(a)** rename to `NeonPerceptron.Chain`, parameterise with total board
  count and a `column_offsets` map (`%{input_left: 0, hidden_front: 2, ...}`).
  One process, one SPI device, one XLAT. Cleaner.
- **(b)** keep the `Column` name but have only one instance with
  `board_count: 13` and an offsets map.

(a) is the honest rename. Do it.

Remove `xlat_spi`, `xlat_spi_device`, `xlat_mode`, `pulse_xlat/2`, and the
`:update` sync path from commit 58b2a2c. Check whether `update_sync/2` has
other callers before removing.

#### 3. Software: renderer

Wherever the renderer currently builds 5 separate per-column buffers,
concatenate into one 312-byte buffer in chain order using the offsets map.
One `Chain.update/1` call per frame.

#### 4. Software: builds

Rewrite `lib/neon_perceptron/builds/test_pattern.ex` and
`lib/neon_perceptron/builds/v2.ex` to start a single `Chain` child instead
of five `Column` children. Re-enable the `Ticker` in
`TestPattern.extra_children/0` for the blink test.

#### 5. Software: XLAT handling

With `spi0-1cs`, the kernel SPI driver owns CE0 and toggles it
automatically per transfer. TLC5947 latches on the rising edge of XLAT,
and CS returns HIGH at transfer end --- so the kernel-managed CS should be
a valid XLAT. Brendan's Python also manually pulses the pin via
`RPi.GPIO`; may be redundant, may be genuinely required.

First approach: let `Circuits.SPI` handle XLAT via CS alone. If boards
fail to latch, add an optional `Circuits.GPIO` pulse on GPIO 8 after each
transfer. Don't build the GPIO path speculatively.

#### 6. Hardware verification on device

1. SSH to `nerves.local` and `cat /sys/kernel/debug/gpio`. Confirm GPIO 8,
   10, 11 are free / claimed only by the spi0 controller. Confirm the
   PCF857x / DSI / touch claims on GPIO 2, 3, 6, 13, 27 are intact.
2. Confirm `/dev/spidev0.0` exists. Confirm the DSI display still comes
   up. Confirm touch still works.
3. Run the TestPattern build with Ticker re-enabled. Expected: all 13
   boards blink in a distinct hue per logical column.
4. If latching fails, scope GPIO 8 during a transfer loop. If CS toggles
   correctly but TLC5947s don't latch, add the manual GPIO pulse (step 5
   fallback).
5. Once TestPattern blinks cleanly, switch the active build to
   `Build.V2` and confirm the perceptron visualisation renders correctly
   across all columns.

### Deliverables

- [ ] #1 `config/rpi4/config.txt` uses `spi0-1cs` (drop `spi1-3cs`)
- [ ] #2 `NeonPerceptron.Column` replaced by `NeonPerceptron.Chain`; 58b2a2c
      workaround reverted
- [ ] #3 All 13 boards blink in TestPattern on real hardware
- [ ] #4 `Build.V2` renders correctly across all 5 logical columns
- [ ] #5 DSI display + Goodix touch still working alongside the SPI chain

### Notes for the session with the device connected

- The device isn't attached right now. When it is, start with step 6.1
  (GPIO-ownership check on the current firmware) before making code
  changes.
- OTA upload path:
  `mise exec -- env MIX_TARGET=rpi4 MIX_ENV=prod mix upload nerves.local`.
- Brendan's Python uses SPI mode 0, 10 MHz. `Circuits.SPI.open/2` defaults
  to mode 0; speed defaults to 1 MHz. Raise to 10 MHz if the default
  latches OK and the chain length is fine, otherwise stay at 1--5 MHz.
- Signal integrity: 13 chips at 10 MHz across ribbon cables should be
  fine but not guaranteed. If it flakes, drop to 5 MHz --- still ~500 µs
  per frame, still irrelevant.
- A single bad solder joint or connector anywhere in the chain kills the
  whole display. Flip side: walking a single non-zero byte through the
  chain instantly identifies which chip-position is broken.

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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
### 2026-04-16 bench findings

The :main chain is physically on SPI3 (CN4 connector, GPIO 2/3/0), not SPI1
as previously assumed. This was discovered by reading the power distribution
board schematic (v1.2) and Brendan's test script (LAT_PIN assignments per
SPI bus). The distribution board is a passive parallel breakout --- all 5
connectors carry the same GPIO signals, and the node board PCB determines
which SPI bus it listens to.

SPI1 (GPIO 20/21 for MOSI/SCLK) isn't even carried by the 32-pin connectors
(those pins are on header positions 35--40, beyond the connector's 32 pins).

The "SPI1 not driving boards" symptom was never an SPI1 problem --- it was
the wrong bus entirely. TASK-19 tracks getting SPI3 working properly.
<!-- SECTION:NOTES:END -->
