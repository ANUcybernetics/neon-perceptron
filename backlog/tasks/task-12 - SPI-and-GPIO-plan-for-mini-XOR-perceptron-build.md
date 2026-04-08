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

Plan for the SPI bus and GPIO allocation on the reTerminal DM for the mini physical build using Brendan Traw's custom node boards.

### Node boards (V2.0, designed by Brendan Traw)

Each board has one TLC5947 (24-channel, 12-bit PWM):

- Channels 0--17: 18 individual LEDs
- Channels 18--20: "Big LED" front (B, G, R)
- Channels 21--23: "Big LED" rear (B, G, R)

Connectors: CN1 (4-pin power), CN2/CN3/CN4 (32-pin, carry PWM output signals to LEDs + power/ground). Boards can be daisy-chained with jumpers but we're running them as straight columns instead.

### Physical layout

Three columns, no daisy-chaining. Hidden layer boards are mounted back-to-back (connectors hidden in the sandwich), so the big LED front/rear faces outward on both sides.

- **Input column**: 4 boards, single layer, front-facing
- **Hidden column**: 3 boards × 2 layers (front + rear, back-to-back) = 6 boards
- **Output column**: 2 boards, single layer, front-facing
- **Total: 12 boards**

Hidden rear boards display the same activations as the front (for now).

### Power distribution board (V1.2, designed by Brendan Traw)

Central hub connecting the CM4 40-pin header to the node board columns:

- LM2940KTT 3.3V LDO for logic power
- 5 × 32-pin output connectors (CN2--CN6), one per SPI chip select
- Decoupling caps per output
- 4-pin power input (CN1)

### Device tree overlays to disable

| Overlay | GPIOs freed | Reason |
|---------|------------|--------|
| MCP251XFD CAN controller | GPIO 8 (CE0), 12 (CAN_INT) | Not using CAN bus |
| LoRa module (if fitted) | GPIO 7 (CE1) | Not using LoRa |
| TLV320AIC3104 audio codec | GPIO 18, 19, 20, 21 (I2S/PCM) | Not using audio; frees pins for SPI1 |

### SPI allocation (4 chip selects, one per column)

**SPI0** (GPIO 9 MISO, 10 MOSI, 11 SCLK)

| CS line | GPIO | Column | Boards | Transfer size |
|---------|------|--------|--------|---------------|
| CE0 | 8 | Input | 4 | 4 × 24 × 12 = 1,152 bits |
| CE1 | 7 | Hidden front | 3 | 3 × 24 × 12 = 864 bits |

**SPI1** (GPIO 19 MISO, 20 MOSI, 21 SCLK)

| CS line | GPIO | Column | Boards | Transfer size |
|---------|------|--------|--------|---------------|
| CE0 | 18 | Hidden rear | 3 | 3 × 24 × 12 = 864 bits |
| CE1 | 17 | Output | 2 | 2 × 24 × 12 = 576 bits |

SPI1 CE2 (GPIO 16) is spare.

### Network topology

- Input layer: 4 nodes (2×2 grid) --- capacitive touch digitiser
- Hidden layer: 3 nodes
- Output layer: 2 nodes
- Total: 9 nodes, 12 boards

### Still to decide

- Capacitive touch controller IC and interface for the 2×2 input digitiser
- Whether SPI1 CE1 on GPIO 17 works cleanly given the optocoupler circuitry on that DI pin
- LED mapping: which of the 18 individual LEDs + big LED RGB channels represent what (activation, weights, bias, etc.)

### References

- Current SPI code: `lib/neon_perceptron/display.ex` (uses `spidev0.0` with 3× TLC5947 daisy-chained)
- Node board schematic: `v2.0-output-assignments.pdf`
- Power distribution schematic: `power-distribution-v1.2.pdf`
- reTerminal DM datasheet: https://files.seeedstudio.com/wiki/reTerminalDM/reTerminalDM_datasheet.pdf
- reTerminal DM hardware guide: https://wiki.seeedstudio.com/reterminal-dm-hardware-guide/
- Device tree overlay source: https://github.com/Seeed-Studio/seeed-linux-dtoverlays
<!-- SECTION:DESCRIPTION:END -->
