---
id: TASK-16
title: SPI1 bus not driving TLC5947 boards
status: To Do
assignee: []
created_date: '2026-04-10 04:25'
labels:
  - bug
  - hardware
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Bench setup: power-distribution-v1.2 board with one TLC5947 node board on each of the 5 silk-screen-labelled positions (SPI0..SPI5, mapping: SPI0=spidev0.0 with 3 daisy-chained boards, SPI1=spidev0.1, SPI3=spidev1.0, SPI4=spidev1.1, SPI5=spidev1.2). TestPattern build with the per-tick Ticker disabled for diagnostics (extra_children returns []).

The TestPattern Ticker is currently DISABLED in code so the bench can be exercised manually via SSH iex without anything overwriting state. Re-enable in `lib/neon_perceptron/builds/test_pattern.ex` `extra_children/0` when done.

## Verified facts (from diagnostic session 2026-04-10)

Tests done with the Ticker removed and `Circuits.SPI.transfer!/2` called directly via SSH iex. Each test starts from a known blanked state (108 bytes of 0x00 sent via spidev0.0).

1. **CE0 (spidev0.0) drives XLAT for the SP0 daisy chain.**
   - 108 bytes of 0xFF → all 3 SP0 boards latch all-white (one CE0 toggle latches the whole chain).
   - 36 bytes of 0xFF → only board 1 (closest to MCU) lights up; boards 2 and 3 keep their previous data. This is correct daisy-chain shift-register behaviour.
   - 108 bytes of 0x00 → all 3 SP0 boards go dark.

2. **CE1 (spidev0.1) does NOT visibly latch anything.**
   - 36 bytes of 0xFF via spidev0.1 → no visible change anywhere (SP1, SP0, SPI3-5 all unchanged).
   - In the previous firmware build (before this diagnostic session), spidev0.1 was producing a flashing green with sub-strobe on SP1. Something has changed --- possibly never reliable in the first place, or possibly disturbed by the spi1-3cs overlay or rapid bus switching.

3. **SPI1 dummy transfers (spidev1.0/1.1) do NOT visibly latch anything.**
   - With 0xFF data sitting in the shift register (loaded via spidev0.0), pulsing spidev1.0 (GPIO 18) → no visible change.
   - Same for spidev1.1 (GPIO 17) → no visible change.
   - spidev1.2 (GPIO 16, 40-pin header pin 36) NOT yet directly tested in this session, but theoretically pin 36 is beyond the 32-pin connector range so unlikely to reach anything.

4. **SPI3-5 boards remain in their power-on random PWM state.** None of the transfers tested have visibly changed them, which means their XLAT lines aren't being driven by anything we're toggling from software.

5. **SP0 board 1 sometimes "flashes" instead of going solid.** Observed multiple times --- behaviour is independent of any Ticker (which has been removed). Possible causes: TLC5947 board defect, GSCLK/oscillator issue on that specific board, or signal-integrity noise on its CS line. Not blocking other diagnostics.

## Ruled out (from earlier sessions)

- SPI devices not present: all 5 /dev/spidev devices exist and `Circuits.SPI.open/1` returns `{:ok, _}`.
- Simulation fallback: no `:access_denied` or `unavailable` warnings in RingLogger.
- Column processes not running: all 5 Column GenServers alive.
- Knob (V1) GPIO conflict: removed in 43145d9. Behaviour unchanged.
- SPI speed: manually tested with `speed_hz: 1_000_000`, no change.

## Hypotheses still on the table

H1. **Pins 33-40 of the RPi header are not on the 32-pin output connectors.** The CNJMA2006WR-2X16P-9T connectors have only 32 pins. If they map directly to header pins 1-32, then GPIO 16 (pin 36), GPIO 19 (pin 35), GPIO 20 (pin 38), GPIO 21 (pin 40), GPIO 26 (pin 37) all fail to reach the node boards. SPI1 MOSI/SCLK would be invisible to all node boards, explaining why direct SPI1 transfers do nothing. **Falsifiable by**: continuity check from header pin 38 (GPIO 20) to the SIN pad of any node board on a CN4/CN5/CN6 connector.

H2. **Each connector has different XLAT routing and the node board's XLAT pin isn't on the same connector pin we think it is.** If the power distribution board cleverly routes a different GPIO to the same physical connector pin position on different connectors, we might be pulsing the wrong GPIO entirely. **Falsifiable by**: probing the XLAT pad on each node board with a scope while toggling each candidate CS pin in turn.

H3. **CE1 (GPIO 7) has been claimed by something else in the device tree.** The reTerminal-dm-base overlay or similar might be holding GPIO 7 in a state that prevents the SPI driver from toggling it cleanly. **Falsifiable by**: checking `/sys/kernel/debug/gpio` or `/sys/class/gpio/` for GPIO 7 ownership; or scoping pin 26 of the 40-pin header during a spidev0.1 transfer.

H4. **The SPI1 CS pins are toggling but too fast for the TLC5947 to latch.** TLC5947 datasheet specifies 20ns minimum XLAT pulse width; software-managed CS via spi-bcm2835aux should easily exceed this, but a buggy driver could produce a glitch. **Falsifiable by**: scoping pin 11/12 (GPIO 17/18) during spidev1.x dummy transfers and measuring CS pulse width.

H5. **SP1 board has a hardware defect.** Possible but doesn't explain why SPI3-5 don't latch either. **Falsifiable by**: physically swapping the SP1 node board with a known-good one (e.g. one of the SP0 chain).

## Systematic test plan (vary one thing at a time)

Run these in order. Each test starts from a fresh ssh into iex on `nerves.local`. The Ticker is currently disabled so nothing competes for SPI.

### Phase 1: hardware continuity (no software needed)

T1. **Continuity check, header pin 38 (GPIO 20) → CN4/CN5/CN6.** Multimeter in continuity mode. If no beep, H1 is confirmed and SPI1 MOSI/SCLK simply aren't on the connectors. This is the highest-leverage test --- run it first.

T2. **Continuity check, header pin 40 (GPIO 21) → CN4/CN5/CN6.** Same as T1 for SPI1 SCLK.

T3. **Continuity check, header pin 19 (GPIO 10) → CN4/CN5/CN6.** Confirms whether SPI0 MOSI reaches the SPI1 connector positions (which would mean all boards share the SPI0 data bus).

T4. **Continuity check, header pin 23 (GPIO 11) → CN4/CN5/CN6.** Same for SPI0 SCLK.

T5. **Continuity check, every CS pin to the XLAT pad of the corresponding node board.** Check pins 11 (GPIO 17), 12 (GPIO 18), 24 (GPIO 8), 26 (GPIO 7), 36 (GPIO 16) → XLAT on the CN board they're supposed to drive. Identify the actual XLAT routing.

### Phase 2: confirm software CS toggling

T6. **Scope the CS line during a spidev1.0 transfer.** Boot the device, ssh in, and run:
```elixir
{:ok, spi} = Circuits.SPI.open("spidev1.0")
for _ <- 1..1000, do: Circuits.SPI.transfer!(spi, <<0xAA>>)
```
While that loop runs, scope GPIO 18 (pin 12). Confirm CS toggles, measure low pulse width and rising edge. If CS does NOT toggle, the spi1-3cs overlay or driver is broken --- skip to T9.

T7. Same for spidev1.1 (GPIO 17, pin 11) and spidev1.2 (GPIO 16, pin 36).

T8. Same for spidev0.0 (GPIO 8, pin 24) and spidev0.1 (GPIO 7, pin 26). Verify the working CE0 looks identical to the non-working CE1.

### Phase 3: in-software pin verification

T9. **Read GPIO ownership from sysfs.** SSH in and check `cat /sys/kernel/debug/gpio | head -50` (might need to enable debugfs). Identify which GPIOs are owned by the SPI subsystems vs free.

T10. **Try toggling a candidate XLAT GPIO via Circuits.GPIO directly** (after stopping any Column GenServer that might own it). If the SP1 board responds to a manual GPIO toggle, we know exactly which GPIO is its XLAT.

### Phase 4: data path verification

T11. **Send a unique pattern via spidev0.0** and physically observe the output channels: e.g. `Circuits.SPI.transfer!(spi00, <<0xF0, 0x00, 0x00, ...>>)` → only some channels should light. This confirms the SP0 boards interpret the data correctly.

T12. **Send the same pattern via spidev0.1.** If CE1 ever latches anywhere, we'll see the same channel pattern light up on whichever board CE1 controls.

## Notes for tomorrow

- The Ticker in TestPattern is disabled (`extra_children/0` returns `[]`). Re-enable when diagnostics are done.
- The xlat_spi_device + FrameCoordinator software workaround was implemented in commit 58b2a2c but **does not actually drive the SP1 or SPI3-5 boards** --- the SPI1 dummy transfers don't visibly latch anything. The fix needs to be revisited once we understand the actual XLAT routing.
- The schematic PDFs are at `backlog/tasks/power-distribution-v1.2.pdf` and `backlog/tasks/v2.0-output-assignments.pdf`. The latter shows TLC5947 channel assignments but not the connector pinout.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All 5 SPI columns drive TLC5947 boards correctly (test pattern blinks on all)
- [ ] #2 Root cause identified and documented
<!-- AC:END -->
