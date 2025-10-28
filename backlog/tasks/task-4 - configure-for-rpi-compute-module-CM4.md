---
id: task-4
title: configure for rpi compute module CM4
status: To Do
assignee: []
created_date: "2025-10-28 06:04"
labels: []
dependencies: []
---

This is the actual hardware we have - and want to run nerves on:
https://github.com/formrausch/frio_rpi4

## UI approach: Phoenix LiveView with Nerves Web Kiosk

After evaluating the available options for rendering UI on the DSI display,
we'll use Phoenix LiveView with the Nerves Web Kiosk system.

### Implementation plan

1. Set up base Nerves system configuration for RPi CM4

   - use `nerves_system_rpi4` as the base system (CM4 uses same system as RPi4)
   - ensure DSI display support is configured (DSI auto-detect is enabled by
     default)
   - configure display settings in config.txt if needed for the specific
     hardware

2. Add Phoenix LiveView application

   - create poncho-style project structure (separate firmware and Phoenix apps)
   - configure Phoenix to run on Nerves
   - set up minimal web server (likely using Bandit or Cowboy)
   - configure LiveView for local network access

3. Integrate Nerves Web Kiosk

   - add dependency on `kiosk_system_rpi4`
   - configure Cog browser to launch on boot
   - point kiosk to local Phoenix LiveView application URL
   - configure Weston compositor for the DSI display

4. Configure hardware-specific settings
   - review frio_rpi4 repository for any required device tree overlays
   - configure backlight control (GPIO pin 13) if needed
   - test DSI display initialization and troubleshoot vc4 kernel module if
     needed

### Rationale

- actively maintained kiosk systems for RPi4/5 (2024-2025)
- Phoenix LiveView provides full interactive UI capabilities with real-time
  updates
- leverages Elixir ecosystem and existing project structure
- well-documented with multiple examples and community support
- DSI display support confirmed for RPi4 hardware

### Alternative considered

Scenic framework was considered but has limited RPi4/CM4 support due to
framebuffer compatibility issues with the DRM interface used by RPi4.
