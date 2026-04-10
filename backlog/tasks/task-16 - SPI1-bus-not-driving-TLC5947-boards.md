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
SPI0 (spidev0.0, spidev0.1) drives TLC5947 boards correctly --- LEDs blink as expected from the test pattern. SPI1 (spidev1.0, spidev1.1, spidev1.2) does not --- boards show solid random colours (uninitialised PWM registers), meaning data is either not reaching the shift registers or XLAT is never latching.

Test setup: bench wiring (not full Build.V2) with 3 daisy-chained boards on spidev0.0, 1 board each on spidev0.1, spidev1.0, spidev1.1, spidev1.2. Running TestPattern build (1 Hz blink, distinct hue per column).

Results:
- spidev0.0 (SPI0): 3 boards, blinking red --- correct
- spidev0.1 (SPI1): 1 board, flashing green with fast sub-strobe artefact
- spidev1.0 (SPI3): 1 board, solid random colours, no response to data
- spidev1.1 (SPI4): 1 board, solid random colours, no response to data
- spidev1.2 (SPI5): 1 board, solid random colours, no response to data

RULED OUT:
- SPI devices not present: all five /dev/spidev devices exist and Circuits.SPI.open/1 succeeds
- Simulation fallback: no warnings in RingLogger, all columns opened real SPI handles
- Column processes not running: all 5 Column GenServers alive and receiving Ticker updates
- GPIO conflict with Knob module: Knob (V1) was claiming GPIO 17/18 (SPI1 CE0/CE1) as input with pull-ups. Removing it changed spidev1.1 from random to blank (= registers cleared), confirming data reaches shift register. But non-zero patterns still don't show. Knob removed in 43145d9
- Board count mismatch: test pattern counts updated to match physical wiring, same result
- SPI speed: manually tested with explicit speed_hz: 1_000_000, no change
- Manual all-on test: sent 36 bytes of 0xFF to spidev1.1 with Ticker stopped --- board remained blank. Data enters shift register (cleared from random on boot) but non-zero patterns don't take effect

ROOT CAUSE (probable):
The power distribution board (v1.2) uses 32-pin connectors (CNJMA2006WR-2X16P-9T) to connect the RPi 40-pin header to node boards. The 32-pin connectors can carry at most 32 of the 40 header signals. SPI1 MOSI (GPIO 20, header pin 38) and SPI1 SCLK (GPIO 21, header pin 40) are on the highest-numbered pins of the 40-pin header --- beyond what the 32-pin connectors carry.

This means SPI1 data/clock signals never physically reach any node board. All boards share SPI0 MOSI/SCLK (GPIO 10/11, header pins 19/23) for data. The SPI1 CS pins (GPIO 17/18, header pins 11/12) ARE on the connectors and serve as XLAT lines.

Evidence supporting this:
- SPI0 CE0 works: MOSI/SCLK/CE0 all within pins 1--32
- SPI1 boards: TLC5947 shift registers get no data (random power-on state); CS/XLAT may still toggle but latches garbage
- "Cleared from random" on spidev1.1 after Knob removal: TLC5947 shift register powers up all-zeros; first XLAT pulse (from GPIO 17 state transition) latched zeros into PWM registers

spidev0.1 sub-strobe: likely caused by SPI0 bus contention --- Column GenServers were firing asynchronously, so spidev0.0 transfers could interleave with spidev0.1 transfers, causing spurious partial-data XLATs on the shared bus.

VERIFICATION NEEDED:
- Continuity check: probe GPIO 20 (header pin 38) to the SIN pad on a node board plugged into CN4/CN5/CN6. If no continuity, this confirms the root cause.
- Alternatively: probe GPIO 10 (header pin 19) to the same SIN pad. If there IS continuity, all boards share SPI0 MOSI.

FIX (implemented):
Software workaround using SPI0 for all data + SPI1 dummy transfers for XLAT:
- SPI1 columns (hidden_front, hidden_rear, output) send data via spidev0.0 (SPI0 MOSI/SCLK), then a 1-byte dummy transfer on spidev1.x toggles CS/XLAT
- Transfers are ordered: SPI1 columns first, then spidev0.1, then spidev0.0 last (so input_left re-latches correct data after spurious CE0 XLATs)
- Ticker/FrameCoordinator uses synchronous calls to guarantee ordering
- See Column.xlat_spi_device option and FrameCoordinator module

FUTURE: if confirmed, the power distribution board v1.3 should route GPIO 20/21 (SPI1 MOSI/SCLK) to CN4/CN5/CN6, replacing the current pass-through of pins 38/40. This would allow direct SPI1 transfers and eliminate the shared-bus workaround.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All 5 SPI columns drive TLC5947 boards correctly (test pattern blinks on all)
- [ ] #2 Root cause identified and documented
<!-- AC:END -->
