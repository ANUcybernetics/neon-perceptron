---
id: TASK-15
title: Investigate Cog/WPE touch event forwarding on DSI display
status: To Do
assignee: []
created_date: '2026-04-08 07:29'
labels:
  - bug
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cog 0.18.5 / WPE WebKit 2.48.3 does not forward Wayland touch events to the browser on the reTerminal DM's DSI display (ILI9881D panel, Goodix GT9271 capacitive touchscreen).

## What we know

- the Goodix touchscreen works at the kernel evdev level (`/dev/input/event0` delivers events)
- Weston (14.0.2) correctly enumerates the touchscreen via libinput and associates it with the DSI-1 output
- Weston has the `/dev/input/event0` fd open and epoll is watching it
- seatd is required for Weston to open input devices (built-in launcher with `SEATD_VTBOUND=0`)
- no touch/pointer/click events reach the browser (tested with document-level listeners on pointerdown, touchstart, mousedown, click)
- the display is native portrait 800x1280 (no Weston transform applied)

## Current workaround

Touch is handled server-side: evdev -> InputEvent (Elixir) -> Touch GenServer -> PubSub -> LiveView assigns -> browser DOM diff. This bypasses Cog entirely for touch input and works well for our use case.

## Possible next steps

- file a bug with Igalia/cog with the Weston log showing the touch association
- test with the Cog 0.19.x pre-release (which may have fixes)
- test whether mouse events (via a USB mouse) work through Cog to isolate whether it's touch-specific or all input
- check if Cog's `--platform=wl` correctly handles the wl_touch Wayland protocol
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Determine root cause of Cog touch event forwarding failure
- [ ] #2 Either fix Cog touch or confirm server-side path is sufficient long-term
<!-- AC:END -->
