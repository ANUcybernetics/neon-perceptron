---
id: TASK-20
title: Redesign power distribution / node boards for RPi 5 and V3
status: To Do
assignee: []
created_date: '2026-04-16 04:09'
labels:
  - hardware
  - enhancement
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
### Context

The V2 power distribution board (v1.2) was designed for a 5-bus SPI scheme on BCM2711 (SPI0/1/3/4/5). It's a passive parallel breakout that fans the Pi 40-pin header to 5 identical 32-pin connectors. Each node board is hardwired to one specific SPI bus's GPIO pins.

This design has two problems for the future:

1. **RPi 5 (RP1) doesn't support SPI3--5.** The spi3-1cs overlay (BCM2711-era) doesn't create a device on Pi 5. Getting multiple SPI chains on Pi 5 requires using SPI buses that RP1 natively supports (SPI0, SPI1, and possibly SPI2).

2. **V3 scale (25-8-10 MLP = 43+ boards)** exceeds what a single Pi can drive. Need multi-Pi distribution with each Pi driving a subset of boards on its own SPI bus(es).

### Design considerations

- Dedicated XLAT GPIO (not piggybacking on CE0) is the correct approach --- avoids per-SPI-controller CS behaviour variations
- Node boards should either support jumper-selectable SPI bus, or use a standard pinout (e.g. always SPI0 pins) with the distribution board doing the bus routing
- Power distribution board may need active routing (muxing) rather than passive pass-through
- Consider whether the ribbon cable daisy-chain topology (SOUT → SIN) should be preserved or replaced with star topology per SPI bus
- Document which GPIO pins each connector actually routes to, and which SPI bus each connector is designed for

### Out of scope

This task is design/planning only. Physical board fabrication is a separate effort.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 SPI bus and XLAT pin assignment documented for RPi 5
- [ ] #2 Node board schematic updated or new board designed for RPi 5 SPI compatibility
- [ ] #3 Power distribution board schematic updated for V3 scale (43+ boards)
<!-- AC:END -->
