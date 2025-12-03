---
id: task-2
title: add Phoenix for digital twin
status: Done
assignee: []
created_date: '2025-10-28 06:03'
updated_date: '2025-12-03 00:45'
labels: []
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Digital twin should be in WebGL using Three.js.

## Summary

Add a Phoenix LiveView web interface (host target only) that visualises the neural network in real-time 3D. The visualisation shows nodes as spheres and edges as lines, with colours and brightness representing activation values and weights. Fullscreen Three.js canvas, no other UI elements.

## Key Design Decisions

- **Host-only**: Phoenix runs only on `:host` target for development
- **Three.js + LiveView**: LiveView streams data via WebSocket; Three.js JS hook renders 3D scene
- **PubSub for activations**: Model broadcasts activations + weights via Phoenix.PubSub, throttled to ~30fps
- **25-input only**: Single input mode --- 5×5 pixel grid (drawable in browser). No 7-segment mode.
- **Fullscreen canvas**: No UI chrome, just the 3D visualisation with OrbitControls
- **Static topology**: Hidden layer size fixed at startup; changing requires page refresh
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Phase 1: Phoenix infrastructure (host-only)

1. Add Phoenix dependencies to `mix.exs` (host target only)
2. Create endpoint, router, basic LiveView
3. Add PubSub for activation broadcasting
4. Update Application to start Phoenix on host

### Phase 2: Three.js visualisation

5. Set up Three.js scene with OrbitControls
6. Create network geometry (nodes as spheres, edges as lines)
7. Implement activation/weight visualisation (colours and brightness)

### Phase 3: Interactive input

8. Implement 5×5 grid input via raycasting on input layer nodes
9. Wire input changes to Model

### Data Flow

```
Model (every ~1ms) → Display.update() [LEDs]
                   → PubSub broadcast (throttled ~30fps)
                   → LiveView → push_event → Three.js hook
```

### Acceptance Criteria

- [ ] Phoenix starts on host target at localhost:4000
- [ ] Fullscreen 3D network visualisation
- [ ] Nodes light up based on real-time activations
- [ ] Edges: green (positive) / red (negative), brightness for magnitude
- [ ] OrbitControls for camera
- [ ] Click input nodes to toggle 5×5 grid pixels
- [ ] Input affects Model inference
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Notes (2025-12-03)

Completed initial Phoenix digital twin implementation:

### Files created:
- `lib/neon_perceptron_web.ex` - Phoenix helpers module
- `lib/neon_perceptron_web/endpoint.ex` - HTTP endpoint
- `lib/neon_perceptron_web/router.ex` - Routes
- `lib/neon_perceptron_web/error_html.ex` - Error handling
- `lib/neon_perceptron_web/components/layouts.ex` - Layout components
- `lib/neon_perceptron_web/components/layouts/root.html.heex` - Root HTML template
- `lib/neon_perceptron_web/components/layouts/app.html.heex` - App layout
- `lib/neon_perceptron_web/live/digital_twin_live.ex` - LiveView for digital twin
- `assets/js/app.js` - JS entry point
- `assets/js/hooks/digital_twin.js` - Three.js visualisation hook
- `assets/package.json` - npm dependencies

### Model changes:
- Added `@web_broadcast_interval` for throttled PubSub updates (~30fps)
- Added `web_input` state field for web-controlled input
- Added `set_web_input/1` public API
- Added `broadcast_to_web/1` to send activations + weights via PubSub
- Added `pubsub_available?/0` helper to gracefully handle missing PubSub
- Added `extract_weights/1` to get kernel weights for edge visualisation

### Configuration:
- Phoenix endpoint configured in `config/host.exs`
- Runs on port 4000
- PubSub added to supervision tree (host only)

### Usage:
```bash
# Start the app
iex -S mix

# Open browser to http://localhost:4000
```

### Known limitations:
- Current model uses 7 inputs (7-segment), but digital twin expects 25 (5×5 grid)
- Need to create a separate 25-input model variant for the digital twin
- The web input currently sends 25 values but model expects 7

## Model25 Added (2025-12-03)

Created `NeonPerceptron.Model25` module:
- 25 inputs (5×5 pixel grid) → configurable hidden layer → 10 outputs
- Synthetic training data with hand-drawn 5×5 digit patterns
- Broadcasts activations + weights via PubSub for digital twin
- Does NOT update physical Display (different activation sizes)

Application changes:
- Host target now starts Model25 instead of Model
- Device target continues to use original 7-input Model
- LiveView updated to call Model25.set_web_input/1

To run:
```bash
iex -S mix
# Open http://localhost:4000
# Click on input nodes (left side) to toggle pixels
# Watch activations flow through the network
```
<!-- SECTION:NOTES:END -->

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
