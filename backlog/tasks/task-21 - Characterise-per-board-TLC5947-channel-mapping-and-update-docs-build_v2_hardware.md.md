---
id: TASK-21
title: >-
  Characterise per-board TLC5947 channel mapping and update
  docs/build_v2_hardware.md
status: To Do
assignee: []
created_date: '2026-04-17 01:42'
labels:
  - hardware
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
### Context

Bench characterisation on 2026-04-17 confirmed that the big-LED vs noodle channel assignments in Board.ex / Builds.V2 don't match the actual physical wiring on at least one board role (input). On :input_left chip 0 the sweep revealed channels 0, 1, 9 drive red/blue noodles (not generic noodle pad positions as Board.ex describes), and channels 18-23 may not drive the big-LED RGB triples the way V2.render_node assumes.

### What needs to happen

Fill out the per-role channel tables in docs/build_v2_hardware.md by systematically walking every board in the installation with Diag.light/4. Four distinct board roles to characterise:

- **Input boards** (:input_left chips 0, 1 and :main chips 0, 1) --- outgoing-edge noodles + big LED
- **Hidden boards, front** (:main chips 2, 3) --- single RGB big LED, no noodles
- **Hidden boards, rear** (:main chips 4, 5) --- single RGB big LED, no noodles
- **Output boards** (:main chips 6, 7, 8) --- incoming-edge noodles + front/rear RGB big LEDs

For each role, pick one representative chip, sweep channels 0-23 with Diag.light/4, and record which LED/noodle lights up (including polarity for noodle pairs and R/G/B for big LEDs). Then spot-check the other chips of the same role to confirm they match.

### Outputs

1. Fully populated tables in docs/build_v2_hardware.md (one per role)
2. Updated Board.ex constants if any are wrong
3. Updated Builds.V2.render_node/2 so big LEDs and noodles render correctly at runtime

### References

- docs/build_v2_hardware.md (WIP, current tables)
- brendan-spi-test.py / test0.py in backlog/tasks/ (historical channel names: filament=17, BFLa=12, BFLb=13)
- NeonPerceptron.Diag.light/4 for the bench sweep
<!-- SECTION:DESCRIPTION:END -->
