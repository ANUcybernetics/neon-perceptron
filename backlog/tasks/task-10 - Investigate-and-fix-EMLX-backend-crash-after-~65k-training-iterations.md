---
id: task-10
title: Investigate and fix EMLX backend crash after ~65k training iterations
status: To Do
assignee: []
created_date: '2025-12-03 06:03'
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
- [ ] #1 Digital twin can run indefinitely without crashing
- [ ] #2 Root cause identified and documented
- [ ] #3 Fix implemented or workaround in place
<!-- AC:END -->
