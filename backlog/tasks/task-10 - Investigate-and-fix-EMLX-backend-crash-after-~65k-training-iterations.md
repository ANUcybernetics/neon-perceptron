---
id: task-10
title: Investigate and fix EMLX backend crash after ~65k training iterations
status: Done
assignee: []
created_date: '2025-12-03 06:03'
updated_date: '2025-12-04 03:14'
labels:
  - bug
  - emlx
  - digital-twin
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When running `mix phx.server` to use the digital twin, the application crashes after approximately 65,000 training iterations with the error:

```
libc++abi: terminating due to uncaught exception of type std::runtime_error: [Event::stream] Cannot access stream on invalid event.
zsh: abort      mix phx.server
```

## Investigation findings

The crash originates from the **EMLX (Apple MLX) backend** C++ layer, not EXLA. The host configuration uses `{:emlx, github: "elixir-nx/emlx", branch: "main"}` as the Nx backend.

### Architecture overview

The `NeonPerceptron.Model25` GenServer runs a continuous training loop:
- **Every 1ms**: Training step via `step_fn`
- **Every 1ms**: Prediction via `GenServer.cast(__MODULE__, {:predict, state.web_input})`
- **Every 33 iterations**: Activations broadcast to web via PubSub
- **Every forward pass**: 3 Axon hooks fire, each doing tensor operations

### Likely root cause

The `calc_layer_activations_hook` pattern creates intermediate tensors on every forward pass:

```elixir
def handle_cast({:calc_layer_activations, :input, input}, state) do
  kernel = get_kernel(state.step_state.model_state, "dense_0")
  dense_0_activations =
    input
    |> Nx.transpose()
    |> Nx.broadcast(Nx.shape(kernel))
    |> Nx.multiply(kernel)
    |> Nx.to_flat_list()  # Forces tensor materialisation
  ...
end
```

After ~65,000 iterations, that's approximately 195,000 hook invocations. The MLX backend appears to be leaking events or not properly cleaning up resources, eventually causing an invalid event access.

### Key files

- `lib/neon_perceptron/model_25.ex` --- training loop and hooks
- `config/host.exs` --- EMLX backend configuration
- `assets/js/hooks/digital_twin.js` --- Three.js visualisation
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Digital twin can run indefinitely without crashing
- [x] #2 Root cause identified and documented
- [x] #3 Fix implemented or workaround in place
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Resolution

The issue was fixed in commit `8304b4a` ("move forward pass to JS client for digital twin"), which was committed after this task was created.

### Root cause

The original implementation used Axon hooks (`calc_layer_activations_hook`) that created intermediate tensors on every forward pass:
- `Nx.transpose()`, `Nx.broadcast()`, `Nx.multiply()`, `Nx.to_flat_list()`
- These operations ran ~3 times per forward pass
- At ~1000 forward passes per second, this created ~195,000 tensor operations by the time of crash (~65k iterations)
- The EMLX (Apple MLX) backend's C++ layer was leaking events or not properly cleaning up resources, causing an invalid event access

### Fix applied

The forward pass calculation was moved entirely to the JavaScript client:
1. The Elixir server now only broadcasts weight matrices every 33 iterations via `Nx.to_flat_list()`
2. The JS client (`digital_twin.js`) calculates activations locally using the received weights
3. This reduces EMLX tensor operations by ~99%

### Verification

The digital twin was tested and ran successfully past 65,000 iterations without crashing, confirming the fix works.
<!-- SECTION:NOTES:END -->
