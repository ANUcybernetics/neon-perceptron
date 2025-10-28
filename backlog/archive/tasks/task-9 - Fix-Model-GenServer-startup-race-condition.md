---
id: task-9
title: Fix Model GenServer startup race condition
status: To Do
assignee: []
created_date: '2025-10-28 09:20'
updated_date: '2025-10-28 09:32'
labels:
  - brainworms
  - robustness
  - genserver
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Model GenServer immediately schedules training in init/1, which calls Knob.position() before the Knob GenServer may be fully initialized. This creates a race condition where the Model may crash if it tries to read the knob position before Knob is ready.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Model uses handle_continue/2 to defer training start until after initialization
- [x] #2 Training is only scheduled after all dependencies are confirmed available
- [x] #3 No race condition occurs during application startup
- [x] #4 Tests verify training doesn't start until handle_continue executes
<!-- AC:END -->
