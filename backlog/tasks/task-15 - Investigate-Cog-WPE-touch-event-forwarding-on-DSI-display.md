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

Touch is handled server-side: evdev -> InputEvent (Elixir) -> Touch GenServer -> PubSub -> LiveView push_event -> browser. This bypasses Cog entirely for touch input.

As of 2026-04-08, the LiveView hook also dispatches synthetic `PointerEvent` objects (pointerdown/pointermove/pointerup) on the correct DOM target, so standard JS touch/pointer handling works despite Cog not forwarding native events.

## Possible next step: switch from Cog/WPE to webengine_kiosk (Qt WebEngine)

The cleanest long-term fix is to replace Cog/WPE with [webengine_kiosk](https://github.com/nerves-web-kiosk/webengine_kiosk), which wraps Qt WebEngine (Chromium-based). Qt manages input directly from `/dev/input`, bypassing Wayland entirely --- so native browser touch events just work without the synthetic event workaround.

### Why webengine_kiosk

- touch input works natively (Qt reads evdev directly, no Wayland touch forwarding needed)
- Chromium rendering engine has better web compatibility than WPE
- was the original Nerves kiosk solution, so Elixir integration is mature
- the CM4 has 8GB RAM, so the larger footprint (~150MB vs ~28MB for WPE) is not a concern

### What switching would involve

1. add `webengine_kiosk` to mix deps and remove `wpe_kiosk`/Cog references
2. rebuild the custom `reterminal_dm` Nerves system with Qt WebEngine instead of WPE/Cog/Weston (Buildroot config changes)
3. update application startup to launch `webengine_kiosk` instead of Weston + Cog
4. verify native touch events reach the browser, then remove the synthetic PointerEvent dispatch and the server-side Touch GenServer (or keep the GenServer for non-browser touch uses)

### Known Cog touch issues for reference

- [igalia/cog#213](https://github.com/Igalia/cog/issues/213) --- multitouch broken (drag acts as pinch-to-zoom)
- [igalia/cog#709](https://github.com/Igalia/cog/issues/709) --- long-press not working
- [meta-wpe#224](https://github.com/WebPlatformForEmbedded/meta-wpe/issues/224) --- removing `virtualinput` from WPEBackend PACKAGECONFIG fixed touch on RPi
- Cog PR #701 added safety guards for touch/pointer events on the Wayland platform
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Determine root cause of Cog touch event forwarding failure
- [ ] #2 Either fix Cog touch or confirm server-side path is sufficient long-term
<!-- AC:END -->
