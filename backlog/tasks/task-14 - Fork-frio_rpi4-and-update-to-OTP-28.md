---
id: TASK-14
title: Fork frio_rpi4 and update to OTP 28
status: To Do
assignee: []
created_date: '2026-04-07 07:31'
updated_date: '2026-04-08 01:32'
labels: []
dependencies:
  - TASK-13
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The frio_rpi4 Nerves system (github.com/formrausch/frio_rpi4) provides full hardware support for the reTerminal DM (DSI display, touchscreen, GPIO expander, CAN bus, audio, RTC) but is pinned to OTP 27 / nerves_system_br 1.28.3 (last updated August 2024).

We switched to frio_rpi4 from kiosk_system_rpi4 because the reTerminal DM's DSI display uses a custom ILI9881D panel driver (compatible string `gjx,gjx101c7`) and device tree overlay (`reTerminal-plus`) that aren't in the mainline kernel. The kiosk_system_rpi4 kernel has the mainline `panel-ilitek-ili9881c.ko` but it doesn't match this panel's compatible string, so the DRM pipeline never fully initialises.

## What we know

- the custom panel driver lives in `frio_rpi4/package/mipi-dsi/src/panel-ili9881d.c`
- the device tree overlay is `frio_rpi4/package/reterminal-dm/reTerminal-plus.dts`
- the vc4 driver needs a `modprobe -r vc4 && modprobe vc4` reload after boot for the DSI display to appear (workaround in `Application.start/2`)
- udevd must be started before Weston so that libinput can discover the Goodix touchscreen via udev
- `frio_rpi4` uses the old MBR-swap A/B partition scheme, not the newer tryboot scheme used by `kiosk_system_rpi4` v2.0+. OTA via `mix upload` does not work --- the firmware is written but the device boots back into the old slot. This needs investigating when forking (likely needs an updated `fwup.conf`)
- `frio_rpi4` uses `nerves_system_br` 1.28.3 and `nerves_toolchain_aarch64_nerves_linux_gnu` 13.2.0
- `kiosk_system_rpi4` 2.0.1 uses `nerves_system_br` 1.33.4 with OTP 28
- mise.toml is currently pinned to OTP 27.3.3 / Elixir 1.18.3 to match
- the kernel console (`dmesg`) can take over the display after a vc4 reload; suppress with `dmesg -n 1` before starting Weston

## Steps

- fork formrausch/frio_rpi4 to ANUcybernetics
- update nerves_system_br to ~1.33 and nerves_toolchain to latest
- update the Buildroot/kernel config for OTP 28 compatibility
- update fwup.conf to the tryboot A/B scheme so OTA via `mix upload` works
- check whether the modprobe vc4 reload workaround is still needed (may be fixed in newer kernels)
- check whether udevd can be started earlier in the boot (e.g. via erlinit or init script) rather than in Application.start
- rebuild the system (requires Docker or a Linux build host with Buildroot --- see https://hexdocs.pm/nerves/customizing-systems.html)
- test that all peripherals still work (DSI display, touchscreen, GPIO expander, CAN, audio)
- test OTA firmware updates via `mix upload`
- publish a GitHub release with prebuilt artifacts
- update neon-perceptron mix.exs to point to the forked system
- restore mise.toml to OTP 28+ and Elixir 1.19+

## References

- https://github.com/formrausch/frio_rpi4
- https://hexdocs.pm/nerves/customizing-systems.html
- https://elixirforum.com/t/project-the-grand-kiosk-the-seeed-studio-reterminal-dm-with-nerves/66321
- https://elixirforum.com/t/custom-device-tree-overlay-raspberry-pi/73087
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 frio_rpi4 forked to ANUcybernetics GitHub org
- [ ] #2 nerves_system_br updated to ~1.33 and toolchain to latest
- [ ] #3 System builds successfully with OTP 28
- [ ] #4 DSI display and touchscreen work on reTerminal DM
- [ ] #5 GitHub release published with prebuilt artifacts
- [ ] #6 neon-perceptron updated to use forked system with OTP 28
- [ ] #7 OTA firmware updates via mix upload work correctly
- [ ] #8 udevd starts before Weston (touchscreen works on boot)
<!-- AC:END -->
