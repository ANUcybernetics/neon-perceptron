---
id: TASK-18
title: Characterise per-board TLC5947 channel-to-LED mapping for V2 installation
status: To Do
assignee: []
created_date: '2026-04-15 23:56'
labels:
  - hardware
  - bug
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
### Context

The 2026-04-15 bench session on TASK-17 surfaced a much bigger software/hardware
mismatch than the original scope. The `Diag` helpers and
`Chain.push_raw/2` shipped in that task work well, and a "pause the Ticker,
drive one channel at a time, walk to the bench and observe" workflow proved
to be the right instrument for characterising the actual wiring.

This task is the methodical per-board channel-to-LED mapping pass that the
software needs to reflect the hardware. Once the map is complete, the
`Builds.V2` render path gets rewritten to match.

### What we already know (from 2026-04-15 bench)

Confirmed hardware realities that the current code does NOT model correctly:

- **Hidden-layer physical dim is 2, not 3.** `Builds.V2.@topology`
  currently says `%{input => 4, hidden_0 => 3, output => 3}` --- the
  `hidden_0 => 3` is wrong for the V2 installation as wired.
- **Noodles are driven from the input/output ends of the wire**, not from
  the hidden board. The hidden-side end of each noodle is voltage reference
  only. Hidden boards drive a single RGB big LED and nothing else.
- **PCB pad number (per `v2.0-output-assignments.pdf`) is not the same as
  TLC5947 channel number.** The pad-to-channel map is a non-trivial
  permutation that varies per board.
- **Per-board channel mapping is not uniform** across input / hidden / output
  roles. Even within a role, individual boards may differ.
- **SPI + latch work fine at 25 MHz** --- the original "only 2 chips light
  under our code" symptom was *not* a signal-integrity issue. It was the
  combination of (a) wrong channels being driven for the big LEDs on
  hidden/output boards and (b) noodles being driven from the wrong board.
  A static all-ones push lights every chip correctly.

Partial map for chip 0 of `:main` (= `{input, 1}`) from last session:

| Channel | Physical LED                             |
|---------|------------------------------------------|
| 0       | red noodle (pair 1)                      |
| 1       | blue noodle (pair 1)                     |
| 9       | a blue noodle --- pad position TBD        |
| 11      | blue noodle at PDF pad "9"               |
| 12      | a red noodle --- pad position TBD         |
| 2--8, 10, 13--17 | nothing                         |
| 18--23  | not yet swept on this chip               |

Asymmetry noted (3 blues + 2 reds) suggests either ch 9 and ch 11 drive the
same physical noodle or one of them drives the front RGB LED component. To
resolve at next sweep.

### LED inventory (from `Builds.V2` moduledoc)

- 4 monochrome white big LEDs (one on back of each input board).
- 14 RGB big LEDs: 4 on front of inputs, 4 across the two hidden columns,
  6 on the output boards (front + back).
- N noodle pairs across input-to-hidden and hidden-to-output segments
  (exact count depends on resolved hidden dim).

### Methodology (what worked in prior session)

Bench sweep via `Diag`:

1. `Diag.pause_ticker()` --- once per session.
2. `Diag.dark(chain_id)` --- clean baseline.
3. `Diag.light(chain_id, chip_index, channel, 1.0)` --- set one state,
   persists indefinitely until the next push.
4. Walk to the bench, record which physical LED (big LED colour / noodle
   position / big RGB component / nothing) lights.
5. Repeat for every channel of every chip whose mapping is not yet known.

Batch-drive multiple channels (e.g. `Chain.push_raw` with several 1.0
positions) is useful for "is this range populated at all?" binary-search
steps, then single-channel drive nails the specific channel.

### Deliverable

A per-board, per-channel map. Suggested shape in code: a new
`NeonPerceptron.BoardMap` (or similar) module exporting a lookup
`channel_role(board_role, board_index, channel) :: {:noodle, edge_spec} |
{:big_led, :mono | {:rgb, :r | :g | :b}, :front | :back} | :unused`. The
exact shape is a design decision for this task, not pre-determined.

### Out of scope

- 30 Hz flicker triage (original TASK-17 AC #5) --- still open, separate
  follow-up.
- Hardware rework: if some physical LEDs turn out to be broken or unwired
  during the sweep, they get documented but not repaired here.

### Bench tips for future sessions

- SSH in from a phone/tablet next to the bench so the operator can set
  states without walking between desk and installation.
- Record observations in a plain text file per board as you go; easier to
  transfer into the eventual `BoardMap` than to reconstruct from chat.
- Start from `Diag.dark` between channels --- afterimage and observation
  noise is real.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Channel-to-LED map captured for every board in the V2 installation (4 input + hidden columns + 3 output boards), covering all 24 TLC5947 channels per chip --- documented in code (e.g. a `BoardMap` module) or in a structured reference file
- [ ] #2 Builds.V2 topology corrected to match hardware hidden-layer dim (2, not 3)
- [ ] #3 Builds.V2.render_node/2 rewritten so that: input boards drive their outgoing-edge noodles on the correct channels; output boards drive their incoming-edge noodles on the correct channels; hidden boards drive only their RGB big LED on the correct channels; mono and RGB big LEDs are driven on whatever channel they are actually wired to
- [ ] #4 TestPattern build updated (or replaced) to exercise every populated LED in the installation so a visual smoke test confirms the mapping
- [ ] #5 Resolve the "extra blue" observation for chip 0 of :main (ch 9 vs ch 11 both reading as blue) during the full sweep --- one of them is either the same physical noodle or a front RGB component
<!-- AC:END -->
