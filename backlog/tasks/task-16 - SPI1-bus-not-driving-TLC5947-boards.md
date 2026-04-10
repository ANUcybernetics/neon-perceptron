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

OPEN HYPOTHESES:
1. XLAT wiring: TLC5947 latches on XLAT rising edge. If XLAT is wired to CS, RPi auxiliary SPI1 may handle CS deassertion differently from SPI0. Check with oscilloscope whether CE pins on SPI1 actually toggle during transfers.
2. SPI1 MOSI/SCLK wiring: SPI0 uses GPIO 10/11, SPI1 uses GPIO 20/21 --- entirely different physical pins. If boards are wired to SPI0 pins instead of SPI1, they would never see data. Verify wiring matches correct GPIO pins for each bus.
3. CS-as-XLAT polarity/timing: even if CS toggles, the TLC5947 needs a clean rising edge on XLAT after all 288 bits are clocked in. The spi1-3cs device tree overlay may behave differently from SPI0 native CS handling.
4. spidev0.1 sub-strobe artefact may be a related clue --- possibly a CS timing issue on SPI0 CE1 as well.

SUGGESTED NEXT STEPS:
- Probe SPI1 MOSI (GPIO 20), SCLK (GPIO 21), and CE0 (GPIO 18) with oscilloscope to confirm signals are present and CS toggles
- Verify physical wiring: confirm TLC5947 SIN/SCLK/XLAT pins on SPI1 boards connect to GPIO 20/21 and the correct CE pin
- If CS is not toggling or has wrong timing, consider using a separate GPIO for XLAT (pulse manually after each SPI transfer)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All 5 SPI columns drive TLC5947 boards correctly (test pattern blinks on all)
- [ ] #2 Root cause identified and documented
<!-- AC:END -->
