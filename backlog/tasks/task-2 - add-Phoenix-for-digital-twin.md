---
id: task-2
title: add Phoenix for digital twin
status: To Do
assignee: []
created_date: "2025-10-28 06:03"
labels: []
dependencies: []
---

Digital twin should be in webgl.

- first phase: just use the standard node + edge ANN diagram, but light it up
- second phase: make it 3D

The current plan is to have the input->hidden layer have:

- an initial taut run (to a 5x5 grid of 3x3 holes)
- then the "messy ends" all squidged together

The hidden layer neurons will be full RGB "half-domes" on both sides of that
board, so it's easy for that state to be seen by everyone.

Then, the final outputs will each be a 7-segment display that we use PWM to
drive (based on activation).
