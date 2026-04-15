# LED chain diagnostic tooling — design

**Date**: 2026-04-15
**Task**: TASK-17 — *Debug LED chain: most chips not rendering + input channel mapping + 30Hz flicker*

## Goal

Add a small diagnostic surface that makes bench-side investigation of the
TLC5947 chains cheap and reproducible. This unblocks three open questions from
TASK-17, in dependency order:

1. Why do only the first two chips of the `:main` chain render under our Elixir
   code, while Brendan's reference Python script lights the full chain?
2. Which TLC5947 channel drives the monochrome big LED on each input board?
3. How much of the residual 30 Hz flicker can we remove without hardware
   changes?

The diagnostic tooling itself is not the end goal — it is the instrument that
lets us answer (1)–(3).

## Scope

In scope:

- A new `NeonPerceptron.Diag` module providing IEx-friendly helpers for
  pushing static frames to a chain and pausing/resuming the `TestPattern`
  ticker.
- A new `Chain.push_raw/2` function that bypasses a chain's `render_fn` and
  pushes a flat `[float]` of length `24 * chip_count` straight to SPI.

Out of scope for this design:

- The *fixes* driven by the findings (encoding changes, SPI-speed tuning,
  `render_node/2` updates). Those will be separate, small changes scoped by
  what the diagnostics surface.
- Automated sweep/test-runner UIs. Manual IEx control is sufficient; an
  auto-cycling build would fight the "dwell on one channel until I've written
  down what I see" workflow.

## Non-goals

- No persistent log of bench findings — captured in the task file.
- No tests for `Diag` itself. Correctness is observed visually; each function
  is a thin wrapper over `Chain.push_raw/2`.

## Design

### `Chain.push_raw/2`

A new `GenServer.call` that pushes arbitrary channel values to a chain,
bypassing its `render_fn`/`render_frame_fn`.

```elixir
@spec push_raw(atom(), [float()]) :: :ok | {:error, :bad_length}
def push_raw(chain_id, channel_values) when is_list(channel_values)

# handle_call({:push_raw, channel_values}, _from, state) ->
#   expected = chip_count(state) * 24
#   if length(channel_values) == expected do
#     data = channel_values |> Enum.reverse() |> Board.encode()
#     spi_transfer(state.spi, state.mode, data)
#     {:reply, :ok, state}
#   else
#     {:reply, {:error, :bad_length}, state}
#   end
```

Rationale for `call` (not `cast`): diagnostics want synchronous back-pressure
so successive IEx commands don't race each other on the SPI bus.

Length validation returns `{:error, :bad_length}` rather than raising — cheaper
to iterate on in IEx.

### `NeonPerceptron.Diag` module

Lives at `lib/neon_perceptron/diag.ex`. Public API:

```elixir
# Ticker control (works with TestPattern.Ticker or any future Ticker the
# supervisor is running; no-op if none present).
@spec pause_ticker() :: :ok | :not_running
@spec resume_ticker() :: :ok | :not_running

# Chain introspection.
@spec chip_count(atom()) :: non_neg_integer()

# Frame helpers — each one blanks the full chain before setting the
# requested channel(s). Deterministic, no hidden state. Return value
# passed through from Chain.push_raw/2.
@spec dark(atom()) :: :ok | {:error, :bad_length}
@spec light(atom(), non_neg_integer(), non_neg_integer(), float()) ::
        :ok | {:error, :bad_length}
@spec light_all(atom(), non_neg_integer(), float()) ::
        :ok | {:error, :bad_length}
@spec light_chip(atom(), non_neg_integer(), float()) ::
        :ok | {:error, :bad_length}
```

Signatures:

- `light(chain_id, chip_index, channel, value \\ 1.0)` — light one channel on
  one chip; every other channel on every chip is zero.
- `light_all(chain_id, channel, value \\ 1.0)` — same channel lit on *every*
  chip; useful for checking channel consistency across boards.
- `light_chip(chain_id, chip_index, value \\ 1.0)` — all 24 channels on one
  chip lit; useful for "is this chip alive and receiving data?" bisection.

### Ticker pause/resume mechanics

`TestPattern.Ticker` is supervised under `NeonPerceptron.Supervisor` with a
fixed child id. `pause_ticker/0` resolves the supervisor by registered name and
calls `Supervisor.terminate_child/2`. `resume_ticker/0` calls
`Supervisor.restart_child/2`. If the child id is unknown (because a different
build is running), return `:not_running` rather than raise.

Child id lookup strategy: iterate `Supervisor.which_children/1`, match on any
id whose string representation ends in `.Ticker`. Keeps the module decoupled
from which specific build is loaded.

### Bench workflow enabled by this

Once `Diag` ships and is uploaded to `nerves.local`:

```elixir
# Answering "why do most :main chips not light?"
Diag.pause_ticker()
Diag.light_all(:main, 20, 1.0)   # front_red lit on every chip — count dark chips
Diag.light_chip(:main, 5, 1.0)   # only chip 5 lit — is it receiving data?
# Vary Chain.@spi_speed_hz, rebuild + upload, repeat.

# Answering "which channel is the mono big LED wired to?"
for chip <- [0, 1], ch <- 18..23 do
  Diag.light(:input_left, chip, ch, 1.0)
  :timer.sleep(3000)  # dwell; observe bench
end
# Repeat for :main at chip_indexes 0 and 1 (the two input chips on :main).

Diag.resume_ticker()
```

### Error handling

- `push_raw/2` with wrong-length input: `{:error, :bad_length}`. No raise.
- `Diag` functions targeting a missing chain: the `GenServer.call` crash
  propagates to IEx — desired, since a typo'd chain id should be loud.
- `pause_ticker/0` / `resume_ticker/0` when no ticker is running: `:not_running`.

### Testing

On `:host` (no SPI hardware), `Chain` already runs in `:simulation` mode and
the SPI transfer is a no-op. Tests:

- Unit test for `Chain.push_raw/2`: length validation (`{:error, :bad_length}`
  on wrong length; `:ok` on correct length in simulation).
- Unit test for `Diag.chip_count/1` against a simulated chain.

No tests for the frame-shape helpers — they are trivial wrappers, and hitting
the bug that matters (wrong channel wired) requires hardware anyway.

## Consequences

- `Chain.push_raw/2` introduces a second entry point for SPI writes alongside
  `update/2` / `update_sync/2`. It is explicitly a diagnostic API, documented
  as such in the function's `@doc`. No runtime code path calls it in
  production.
- `Diag` is always-loaded (in `lib/`, not in test support). Keeps it usable in
  any built firmware and from `iex --sname` against a running node.
- Once (1) and (2) in TASK-17 are answered, `Diag` continues to be useful for
  future hardware debug sessions (cable swaps, board rev changes). Not
  disposable scaffolding.

## What this design does not answer

The fixes for the three underlying questions are downstream of what `Diag`
surfaces. Each will be planned separately:

- Chain-render fix — depends on whether diagnosis points at SPI speed,
  encoding, buffer length, or something else.
- Input-board render adjustment — depends on which channel(s) the bench sweep
  reveals.
- Flicker triage — depends on whether (1)'s fix already improves it.
