---
id: TASK-15
title: Investigate Cog/WPE touch event forwarding on DSI display
status: Done
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

## Current approach: synthetic PointerEvents (working)

Touch is handled server-side: evdev -> InputEvent (Elixir) -> Touch GenServer -> PubSub -> LiveView push_event -> browser. This bypasses Cog entirely for touch input.

As of 2026-04-08, the LiveView hook dispatches synthetic `PointerEvent` objects (pointerdown/pointermove/pointerup) on the correct DOM target, so standard JS touch/pointer handling works despite Cog not forwarding native events. This is sufficient for our current UI needs.

## Investigated alternatives

### Cog `--platform=drm` (tested 2026-04-08, failed)

Cog supports a DRM platform backend that bypasses Weston and uses libinput directly for input. This would likely fix touch since it reads evdev directly. However, the current `reterminal_dm` system (v2.0.0) does not compile Cog with DRM platform support --- Cog exits with SIGABRT (status 134) when launched with `--platform=drm`.

**To try this in future:** add `BR2_PACKAGE_COG_PLATFORM_DRM=y` to the `reterminal_dm` nerves_defconfig and rebuild the system. Dependencies (Mesa3D, libinput) are already present.

### webengine_kiosk / Qt WebEngine (not viable)

Initially looked promising, but:

- webengine_kiosk is **archived** (Dec 2021, last release v0.3.0 targeting Qt5)
- current Buildroot ships Qt6, so the C++ shim would need porting
- kiosk_system_rpi4 does NOT use Qt WebEngine --- it uses the same Cog/WPE/Weston stack
- would require adding ~20 Buildroot Qt6 packages and +150MB to rootfs

### meta-wpe virtualinput fix (not applicable)

The fix in [meta-wpe#224](https://github.com/WebPlatformForEmbedded/meta-wpe/issues/224) is for `wpebackend-rdk`, not the standard Cog Wayland platform (`--platform=wl`) that we use.

### Known Cog touch issues for reference

- [igalia/cog#213](https://github.com/Igalia/cog/issues/213) --- multitouch broken (drag acts as pinch-to-zoom)
- [igalia/cog#709](https://github.com/Igalia/cog/issues/709) --- long-press not working
- Cog PR #701 added safety guards for touch/pointer events on the Wayland platform
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Determine root cause of Cog touch event forwarding failure
- [x] #2 Either fix Cog touch or confirm server-side path is sufficient long-term
<!-- AC:END -->
