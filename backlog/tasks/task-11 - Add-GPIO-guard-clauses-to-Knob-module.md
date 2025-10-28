---
id: task-11
title: Add GPIO guard clauses to Knob module
status: To Do
assignee: []
created_date: '2025-10-28 09:20'
labels:
  - brainworms
  - robustness
  - gpio
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When GPIO initialization fails in Knob module, the GenServer state contains nil pin references. However, handle_info callbacks still receive GPIO interrupt messages and attempt to read from these nil pins, causing crashes. Add guard clauses to handle missing hardware gracefully.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 handle_info callbacks check for nil pins before attempting GPIO reads
- [ ] #2 Knob operates safely when GPIO initialization fails
- [ ] #3 Appropriate warnings are logged when hardware operations are skipped
- [ ] #4 Module returns safe default values when hardware unavailable
- [ ] #5 Tests verify graceful handling of missing GPIO hardware
<!-- AC:END -->
