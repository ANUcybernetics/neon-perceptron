---
id: TASK-12
title: SPI and GPIO plan for mini XOR perceptron build
status: To Do
assignee: []
created_date: '2026-03-26 21:57'
labels:
  - hardware
  - mini-perceptron
dependencies: []
references:
  - lib/neon_perceptron/display.ex
  - 'https://wiki.seeedstudio.com/reterminal-dm-hardware-guide/'
  - 'https://files.seeedstudio.com/wiki/reTerminalDM/reTerminalDM_datasheet.pdf'
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Hardware plan for mini XOR perceptron (2×2 → 3 → 2)

Plan for the SPI bus and GPIO allocation on the reTerminal DM for the mini physical build using Brendan Traw's custom node boards (SPI, daisy-chained).

### Device tree overlays to disable

| Overlay | GPIOs freed | Reason |
|---------|------------|--------|
| MCP251XFD CAN controller | GPIO 8 (CE0), 12 (CAN_INT) | Not using CAN bus |
| LoRa module (if fitted) | GPIO 7 (CE1) | Not using LoRa |
| TLV320AIC3104 audio codec | GPIO 18, 19, 20, 21 (I2S/PCM) | Not using audio; frees pins for SPI1 |

### SPI allocation

**SPI0** (GPIO 8 CE0, 9 MISO, 10 MOSI, 11 SCLK) --- reclaimed from CAN

- CE0 (GPIO 8): available
- CE1 (GPIO 7): available (reclaimed from LoRa)

**SPI1** (GPIO 19 MISO, 20 MOSI, 21 SCLK) --- reclaimed from audio codec

- CE0 (GPIO 18): available
- CE1 (GPIO 17): available (reclaimed from DI2)
- CE2 (GPIO 16): available (reclaimed from DI1)

**Total: 5 hardware chip selects across 2 SPI buses.** Custom node boards are daisy-chained, so the actual number of physical CS lines needed depends on how the boards are grouped (e.g. per layer or per bus).

### Network topology

- Input layer: 4 nodes (2×2 grid) --- capacitive touch digitiser
- Hidden layer: 3 nodes
- Output layer: 2 nodes
- Total node boards: 9 (7 nodes + edges TBD)

### Still to decide

- How to group the daisy-chained boards across the available CS lines (per layer? per bus?)
- Capacitive touch controller IC and interface for the 2×2 input digitiser
- Whether to reclaim the DI/DO GPIOs (16, 17, 22–26) for additional CS lines or other uses (note: these go through optocouplers on the reTerminal DM carrier board)
- Whether SPI1 CE1/CE2 on GPIO 17/16 will work cleanly given the optocoupler circuitry on those DI pins

### References

- Current SPI code: `lib/neon_perceptron/display.ex` (uses `spidev0.0` with 3× TLC5947 daisy-chained)
- reTerminal DM datasheet: https://files.seeedstudio.com/wiki/reTerminalDM/reTerminalDM_datasheet.pdf
- reTerminal DM hardware guide: https://wiki.seeedstudio.com/reterminal-dm-hardware-guide/
- Device tree overlay source: https://github.com/Seeed-Studio/seeed-linux-dtoverlays
<!-- SECTION:DESCRIPTION:END -->
