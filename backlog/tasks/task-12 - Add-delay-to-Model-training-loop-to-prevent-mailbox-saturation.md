---
id: task-12
title: Add delay to Model training loop to prevent mailbox saturation
status: To Do
assignee: []
created_date: '2025-10-28 09:20'
labels:
  - brainworms
  - robustness
  - performance
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Model GenServer training loop currently schedules the next training step with 0ms delay (send_after/3 with timeout 0). This can overwhelm the process mailbox and prevent other messages from being processed in a timely manner. Add a small delay between training iterations to allow message interleaving.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Training loop uses Process.send_after with 1ms minimum delay instead of 0ms
- [ ] #2 Other messages (like position updates) can be processed between training steps
- [ ] #3 Training performance remains acceptable with the added delay
- [ ] #4 Alternatively, :hibernate option is considered for longer pauses between training cycles
- [ ] #5 Tests verify message processing is not blocked by continuous training
<!-- AC:END -->
