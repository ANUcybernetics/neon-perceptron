---
id: TASK-19
title: Get SPI3 chain working on RPi 4 with manual XLAT
status: To Do
assignee: []
created_date: '2026-04-16 04:08'
labels:
  - hardware
  - bug
dependencies:
  - TASK-18
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
### Context

Bench debugging on 2026-04-16 established that the :main chain (11 boards) is physically connected to SPI3 (CN4 connector on the power distribution board, GPIO 2 MOSI / GPIO 3 SCLK / GPIO 0 CE0), not SPI1 as previously assumed. The code and overlays have been updated to use spidev3.0 (commit 568f2a5).

SPI3 is a BCM2711 aux SPI controller, so kernel CE0 on GPIO 0 probably won't toggle reliably at end-of-transfer (same issue as SPI1). Chain.ex already has xlat_gpio infrastructure (commit 1614dc2) for manual XLAT pulsing.

### What needs to happen

1. Confirm spidev3.0 appears on Pi 4 with the spi3-1cs overlay (already in config.txt)
2. Test whether GPIO 0 is openable via Circuits.GPIO when spi3-1cs claims it as CE0 --- if yes, set xlat_gpio: "GPIO0" on the :main chain and it should Just Work
3. If GPIO 0 is not openable (same :already_open issue as GPIO 18 was): Brendan's RPi.GPIO approach bypasses kernel ownership via /dev/mem. Options: (a) find/write an Elixir NIF that does the same, (b) use a different overlay that frees GPIO 0 (cs0_pin= workaround), (c) physically rewire XLAT to a spare GPIO, (d) collapse into a single 13-chip chain on SPI0

### Verification

Both :input_left (SPI0) and :main (SPI3) should blink with TestPattern. Then Diag.dark_all() should darken everything.

### References

- Brendan's test script: backlog/tasks/brendan-spi-test.py (SPI3 LAT_PIN = 0)
- Power distribution board schematic: backlog/tasks/power-distribution-v1.2.pdf (passive parallel breakout, all connectors carry same GPIO signals)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 spidev3.0 appears in /dev on Pi 4 boot
- [ ] #2 :main chain responds to Diag.light and Diag.dark on SPI3
- [ ] #3 TestPattern blinks on both chains simultaneously
<!-- AC:END -->
