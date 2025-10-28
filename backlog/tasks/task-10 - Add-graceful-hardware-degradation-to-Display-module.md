---
id: task-10
title: Add graceful hardware degradation to Display module
status: To Do
assignee: []
created_date: '2025-10-28 09:20'
labels:
  - brainworms
  - robustness
  - hardware
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Display module currently crashes when SPI hardware is unavailable, preventing development on host machines. The module should detect hardware availability at startup and operate in simulation mode on host (logging display updates) or hardware mode on target devices.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Display detects SPI hardware availability during initialization
- [ ] #2 Display runs in simulation mode when hardware unavailable (logs instead of actual SPI writes)
- [ ] #3 Display runs in hardware mode when SPI available
- [ ] #4 Mode selection is automatic based on hardware detection
- [ ] #5 Application starts successfully on both host and target
- [ ] #6 Tests verify both simulation and hardware modes work correctly
<!-- AC:END -->
