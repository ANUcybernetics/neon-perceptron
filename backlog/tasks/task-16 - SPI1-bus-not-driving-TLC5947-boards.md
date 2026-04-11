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

## Schematic analysis (2026-04-11)

Rendered `power-distribution-v1.2.pdf` at 600 dpi and walked every pin of the 40-pin RPi header symbol U1.

**GPIO16 (header pin 36) is marked NC (green X) on the schematic.** That is the CE2 line `dtoverlay=spi1-3cs` uses for `spidev1.2`, i.e. the Output column on CN6. Consequence: **no software fix can make spidev1.2 drive CN6** --- the XLAT line for that column is not physically routed. The Output column needs a hardware bodge (wire from header pin 36 to CN6 XLAT pad), remapping to a different spare GPIO driven via `Circuits.GPIO`, or a revised power-distribution board.

Other NC pins on the header symbol: 1 (3.3V), 7 (GPIO4), 13 (GPIO27), 15 (GPIO22), 16 (GPIO23), 17 (3.3V), 21 (GPIO9), 27/28 (DNC), 29 (GPIO5), 33 (GPIO13), 35 (GPIO19). None of these affect the SPI plan except GPIO19 which is SPI1 MISO --- irrelevant since TLC5947 is write-only.

**All other SPI signals do appear wired** on the header symbol (no X):

- GPIO 7/8 --- SPI0 CE1/CE0
- GPIO 10/11 --- SPI0 MOSI/SCLK
- GPIO 17/18 --- SPI1 CE1/CE0
- GPIO 20/21 --- SPI1 MOSI/SCLK

### Implication for the 58b2a2c workaround

The workaround (send data via spidev0.0, pulse XLAT via a dummy spidev1.x transfer) only works if SPI0 MOSI/SCLK fan out to CN4/CN5/CN6 as a shared data bus. If they did, pulsing any spidev1.x CS after a spidev0.0 transfer would latch *something* --- even garbage --- into the corresponding board's outputs. The empirical observation that SP3--5 boards "remain in their power-on random PWM state" is only consistent with **the SPI0 data bus not reaching those connectors**. The most likely routing is: CN2/CN3 on the SPI0 data bus (GPIO10/11), CN4/CN5/CN6 on the SPI1 data bus (GPIO20/21).

The workaround is therefore architecturally wrong for CN4/CN5 and should be reverted. The correct approach is to send real data via `spidev1.0` / `spidev1.1` and let the CE lines latch naturally. CN6 can't be fixed this way regardless (GPIO16 is NC).

### Gap: node board pinout is undocumented

`v2.0-output-assignments.pdf` only documents the LED channel map (0--17 noodles + 18--23 Big LED front/rear). It does **not** show which pins of CN1/CN2/CN3/CN4 carry SIN/SCLK/XLAT/GSCLK/BLANK. The node boards are custom designs with three 32-pin connectors intended for daisy-chain, so the signal pinout might differ between CN2/CN3/CN4 on the board itself, and a node-board-side bug (miswired trace, swapped connector, non-uniform assembly) cannot yet be ruled out. Producing this pinout map is a deliverable of Phase 1 below.

## Ruled out (from earlier sessions)

- SPI devices not present: all 5 /dev/spidev devices exist and `Circuits.SPI.open/1` returns `{:ok, _}`.
- Simulation fallback: no `:access_denied` or `unavailable` warnings in RingLogger.
- Column processes not running: all 5 Column GenServers alive.
- Knob (V1) GPIO conflict: removed in 43145d9. Behaviour unchanged.
- SPI speed: manually tested with `speed_hz: 1_000_000`, no change.

## Hypotheses still on the table

H1. **CONFIRMED (partial): GPIO16 (pin 36) is NC on the power distribution board.** See Schematic analysis above. The Output column cannot be driven via `spidev1.2` regardless of software. Pins 38 (GPIO20) and 40 (GPIO21), however, *do* have wires leaving the header --- SPI1 MOSI/SCLK are routed somewhere, most plausibly CN4/CN5/CN6. **Still to confirm physically**: continuity from pins 38/40 to CN4--CN6 (T1, T2 below), and the T5 open-circuit check on pin 36.

H2. **Each connector has different XLAT routing and the node board's XLAT pin isn't on the same connector pin we think it is.** If the power distribution board routes a different GPIO to the same physical connector pin position on different connectors, we might be pulsing the wrong GPIO entirely. **Falsifiable by**: probing the XLAT pad on each node board with a scope while toggling each candidate CS pin in turn.

H3. **CE1 (GPIO 7) has been claimed by something else in the device tree.** The reTerminal-dm-base overlay only claims GPIO 6, 13, 27 --- not GPIO 7. With CAN and audio overlays omitted, GPIO 7 should be free. Worth checking `/sys/kernel/debug/gpio` anyway to rule out a silent claimant, since spidev0.1 used to partially work and now doesn't.

H4. **The SPI1 CS pins are toggling but too fast for the TLC5947 to latch.** TLC5947 datasheet specifies 20ns minimum XLAT pulse width; software-managed CS via spi-bcm2835aux should easily exceed this, but a buggy driver could produce a glitch. **Falsifiable by**: scoping pin 11/12 (GPIO 17/18) during spidev1.x dummy transfers and measuring CS pulse width.

H5. **SP1 board has a hardware defect.** Possible but doesn't explain why SPI3-5 don't latch either. **Falsifiable by**: physically swapping the SP1 node board with a known-good one (e.g. one of the SP0 chain).

H6. **Node board CN2/CN3/CN4 signal pinouts are not identical.** The three 32-pin connectors on each node board are nominally for daisy-chain, so all three *should* expose SIN/SCLK/XLAT on the same pin positions. If they don't --- or if one connector is an "output" (SOUT) rather than "input" (SIN) --- the SP3/4/5 bench positions might be plugged into a connector that doesn't receive data. SP0 would still work because its chain happens to use the "correct" connector. **Falsifiable by**: rotating which CN on the node board is used as the input (T0b) and by the node-board continuity map (T7).

H7. **Bench cabling inconsistency.** If SP0 boards are plugged into node-board CN2 but SP3--5 are plugged into CN3 or CN4 (easy to mix up on a rat's nest), and H6 holds, we'd see the observed failure. **Falsifiable by**: visually auditing which connector each power-dist cable lands on across all node boards in the bench.

H8. **Node board assembly or layout drift.** If a subset of node boards were assembled from a different revision, or hand-soldered with errors, that subset won't work regardless of the bus. **Falsifiable by**: the swap test T0 below --- move a known-good SP0 board into the SP3 position.

## Systematic test plan (vary one thing at a time)

Run these in order. Each test starts from a fresh ssh into iex on `nerves.local`. The Ticker is currently disabled so nothing competes for SPI.

### Phase 0: physical disambiguation (no scope, no code changes)

T0. **Board swap test.** Physically move one of the known-working SP0 chain boards into the SP3 (CN4) position, keeping the same cable and connector orientation. With the existing firmware running, re-run the spidev1.0 test.
- If SP3 now lights up → the node board in that position was the problem (H6/H8). Next step: audit the SP3/4/5 node boards and cabling.
- If SP3 still doesn't light up → the power-dist CN4 socket isn't delivering a working signal set. The problem is upstream of the node board (H1/H2).

This single test splits the problem space in half. Run it first.

T0b. **Connector rotation on one non-working node board.** Unplug an SP3 board and try each of its three 32-pin connectors (CN2/CN3/CN4) in turn against the same power-dist CN4 socket. If one position lights up, that's the "correct" input connector on the node board --- document it and re-plug the rest of the bench to match. Falsifies H6.

### Phase 1: hardware continuity (no software needed)

T1. **Continuity check, header pin 38 (GPIO 20) → CN4/CN5/CN6.** Multimeter in continuity mode. Expectation: beeps to the signal pin on each of CN4/CN5/CN6 (SPI1 MOSI data bus). If no beep, something is very different from my schematic read.

T2. **Continuity check, header pin 40 (GPIO 21) → CN4/CN5/CN6.** Same as T1 for SPI1 SCLK.

T3. **Continuity check, header pin 19 (GPIO 10) → CN2/CN3 vs CN4/CN5/CN6.** Expectation: beeps on CN2/CN3 (SPI0 MOSI), silent on CN4/CN5/CN6. If it *does* beep to CN4--6 the 58b2a2c workaround architecture was correct and something else is wrong.

T4. **Continuity check, header pin 23 (GPIO 11) → CN2/CN3 vs CN4/CN5/CN6.** Same for SPI0 SCLK.

T5. **Continuity check, header pin 36 (GPIO 16) → anywhere.** Expectation: open circuit. Confirms the schematic-level NC finding on the actual PCB.

T6. **Continuity check, every CS pin to the XLAT pad of the corresponding node board.** Check pins 11 (GPIO 17), 12 (GPIO 18), 24 (GPIO 8), 26 (GPIO 7) → XLAT on the CN they're supposed to drive. Identify the actual XLAT routing.

T7. **Node-board pinout map (document-as-you-go).** For one node board, ring out the TLC5947's SIN, SCLK, XLAT, GSCLK and BLANK pads (IC1 on the PCB photo) to every pin of CN2/CN3/CN4. Save the result as a markdown table next to `v2.0-output-assignments.pdf` --- this is the missing documentation artefact that would prevent a repeat of this bug.

### Phase 2: confirm software CS toggling (scope)

T8. **Scope the CS line during a spidev1.0 transfer.** Boot the device, ssh in, and run:
```elixir
{:ok, spi} = Circuits.SPI.open("spidev1.0")
for _ <- 1..1000, do: Circuits.SPI.transfer!(spi, <<0xAA>>)
```
While that loop runs, scope GPIO 18 (pin 12). Confirm CS toggles, measure low pulse width and rising edge. If CS does NOT toggle, the spi1-3cs overlay or driver is broken --- skip to T11.

T9. Same for spidev1.1 (GPIO 17, pin 11). Skip spidev1.2 --- GPIO 16 is NC on the board regardless, but scoping at the header pin will at least confirm the driver is producing the signal.

T10. Same for spidev0.0 (GPIO 8, pin 24) and spidev0.1 (GPIO 7, pin 26). Verify the working CE0 looks identical to the non-working CE1.

T10b. **Scope SIN and SCLK at the TLC5947 input pins of an SP3 board** while running spidev1.0 transfers.
- If signals present at the chip → node board and cable are fine; problem is elsewhere (timing, XLAT, pulse width).
- If present at the connector but not the chip → on-board trace/routing issue.
- If absent at the connector too → power-dist socket or cable issue.

### Phase 3: in-software pin verification

T11. **Read GPIO ownership from sysfs.** SSH in and check `cat /sys/kernel/debug/gpio | head -50` (might need to enable debugfs). Identify which GPIOs are owned by the SPI subsystems vs free. Look specifically for silent claimants on GPIO 7, 17, 18.

T12. **Try toggling a candidate XLAT GPIO via Circuits.GPIO directly** (after stopping any Column GenServer that owns it). If an SP3/4/5 board responds to a manual GPIO toggle, we know exactly which GPIO is its XLAT.

### Phase 4: data path verification

T13. **Send a unique pattern via spidev0.0** and physically observe the output channels: e.g. `Circuits.SPI.transfer!(spi00, <<0xF0, 0x00, 0x00, ...>>)` → only some channels should light. This confirms the SP0 boards interpret the data correctly.

T14. **Send the same pattern via spidev0.1.** If CE1 ever latches anywhere, we'll see the same channel pattern light up on whichever board CE1 controls.

## Notes for tomorrow

- The Ticker in TestPattern is disabled (`extra_children/0` returns `[]`). Re-enable when diagnostics are done.
- **Commit 58b2a2c's "data on spidev0.0 + pulse XLAT via spidev1.x" workaround is architecturally wrong for CN4/CN5/CN6.** The data bus on those connectors is almost certainly SPI1 MOSI/SCLK (GPIO20/21), not SPI0. When fixing, revert to sending real data via `spidev1.0` and `spidev1.1` and let the CE lines latch naturally. T3/T4 will confirm.
- **GPIO16 (pin 36) is NC on the power distribution board v1.2.** The Output column cannot be driven via `spidev1.2` regardless of software. Options: bodge wire from pin 36 to CN6 XLAT pad, remap to a spare GPIO driven via `Circuits.GPIO`, or respin the power-dist board.
- **The spidev0.1 regression (flashing green on SP1 → now nothing) is a separate issue from the SPI1 story.** GPIO 7 is wired on the schematic and shouldn't be claimed by anything in the current device tree; most likely cause is the write-ordering changes in 58b2a2c rather than wiring. Debug independently once SPI1 is sorted.
- Node board signal-pin pinout is **undocumented**. T7 in Phase 1 should produce a node-board pinout map as a deliverable, saved next to `v2.0-output-assignments.pdf`.
- The schematic PDFs are at `backlog/tasks/power-distribution-v1.2.pdf` and `backlog/tasks/v2.0-output-assignments.pdf`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All 5 SPI columns drive TLC5947 boards correctly (test pattern blinks on all)
- [ ] #2 Root cause identified and documented
<!-- AC:END -->
