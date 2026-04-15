# LED chain diagnostic tooling implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `NeonPerceptron.Diag` + `Chain.push_raw/2` so bench-side LED debugging (static frames, per-channel sweeps, chain propagation tests) is one IEx call away.

**Architecture:** `Chain.push_raw/2` is a synchronous call that bypasses the chain's `render_fn` and writes a flat `[float]` directly to SPI after length validation. `Diag` is a thin set of IEx helpers on top: it builds a zero-filled 24×N list, replaces specific positions, calls `push_raw`, and separately controls the `TestPattern.Ticker` via the supervisor.

**Tech Stack:** Elixir 1.19, Nerves, `Circuits.SPI`, `ExUnit` (tests run on the `:host` target where `Chain` opens in `:simulation` mode and SPI transfers are no-ops).

---

## File structure

- **Modify** `lib/neon_perceptron/chain.ex` — add `push_raw/2` public function, matching `handle_call/3` clause, and a private `chip_count/1` state helper.
- **Create** `lib/neon_perceptron/diag.ex` — new module (~60 lines). Public API: `pause_ticker/0`, `resume_ticker/0`, `chip_count/1`, `dark/1`, `light/4`, `light_all/3`, `light_chip/3`.
- **Modify** `test/chain_test.exs` — add a `describe "push_raw/2"` block with two tests (happy path + length mismatch).
- **Create** `test/diag_test.exs` — single test for `Diag.chip_count/1` against a started chain.

No changes to build configs, mix.exs, or application supervision tree.

---

## Task 1: `Chain.push_raw/2` — happy path

**Files:**
- Modify: `lib/neon_perceptron/chain.ex`
- Test: `test/chain_test.exs`

- [ ] **Step 1: Write the failing happy-path test**

Append inside `test/chain_test.exs` before the closing `end`:

```elixir
  describe "push_raw/2" do
    test "accepts a correctly-sized channel list and returns :ok" do
      config = %{
        id: :push_raw_ok,
        spi_device: "spidev99.99",
        boards: [{"input", 0}, {"input", 1}],
        render_fn: fn _state, _spec -> NeonPerceptron.Board.blank() end,
        render_frame_fn: nil
      }

      start_supervised!({Chain, config}, id: :push_raw_ok)

      values = List.duplicate(0.25, 48)
      assert :ok = Chain.push_raw(:push_raw_ok, values)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/chain_test.exs --only describe:"push_raw/2"`

Expected: FAIL with `undefined function Chain.push_raw/2` (or similar).
If ExUnit doesn't accept `--only describe:`, run the whole file: `mix test test/chain_test.exs`.

- [ ] **Step 3: Implement `push_raw/2` + `handle_call`**

In `lib/neon_perceptron/chain.ex`, add the public function next to `update_sync/2` (around line 105):

```elixir
  @doc """
  Push an arbitrary list of channel values (flat `24 * chip_count` floats)
  directly to SPI, bypassing `render_fn`/`render_frame_fn`.

  Diagnostic only. Use `Diag` helpers instead of calling this directly.

  Returns `:ok` on success, `{:error, :bad_length}` if the list length
  does not equal `24 * chip_count` for the target chain.
  """
  @spec push_raw(atom(), [float()]) :: :ok | {:error, :bad_length}
  def push_raw(chain_id, channel_values) when is_list(channel_values) do
    GenServer.call(via(chain_id), {:push_raw, channel_values})
  end
```

Add a matching `handle_call/3` clause below the existing one (around line 113):

```elixir
  @impl true
  def handle_call({:push_raw, channel_values}, _from, state) do
    expected = length(state.boards) * 24

    if length(channel_values) == expected do
      data = channel_values |> Enum.reverse() |> Board.encode()
      spi_transfer(state.spi, state.mode, data)
      {:reply, :ok, state}
    else
      {:reply, {:error, :bad_length}, state}
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/chain_test.exs`

Expected: PASS (all Chain tests, including the new one).

- [ ] **Step 5: Commit**

```bash
git add lib/neon_perceptron/chain.ex test/chain_test.exs
git commit -m "add Chain.push_raw/2 for diagnostic static frames"
```

---

## Task 2: `Chain.push_raw/2` — length mismatch

**Files:**
- Test: `test/chain_test.exs`

- [ ] **Step 1: Write the failing test**

Inside the existing `describe "push_raw/2"` block in `test/chain_test.exs`, add a second test:

```elixir
    test "returns {:error, :bad_length} for wrong-sized input" do
      config = %{
        id: :push_raw_bad,
        spi_device: "spidev99.99",
        boards: [{"input", 0}, {"input", 1}],
        render_fn: fn _state, _spec -> NeonPerceptron.Board.blank() end,
        render_frame_fn: nil
      }

      start_supervised!({Chain, config}, id: :push_raw_bad)

      # 2 boards = 48 channels expected; send 47.
      assert {:error, :bad_length} =
               Chain.push_raw(:push_raw_bad, List.duplicate(0.0, 47))
    end
```

- [ ] **Step 2: Run the tests**

Run: `mix test test/chain_test.exs`

Expected: PASS — Task 1's implementation already handles this. If it doesn't, revisit Task 1 Step 3's `if length(channel_values) == expected`.

- [ ] **Step 3: Commit**

```bash
git add test/chain_test.exs
git commit -m "test Chain.push_raw/2 length validation"
```

---

## Task 3: `Diag` module skeleton + `chip_count/1`

**Files:**
- Create: `lib/neon_perceptron/diag.ex`
- Create: `test/diag_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/diag_test.exs`:

```elixir
defmodule NeonPerceptron.DiagTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Chain, Diag}

  setup do
    config = %{
      id: :diag_test,
      spi_device: "spidev99.99",
      boards: [{"input", 0}, {"input", 1}, {"input", 2}],
      render_fn: fn _state, _spec -> NeonPerceptron.Board.blank() end,
      render_frame_fn: nil
    }

    start_supervised!({Chain, config}, id: :diag_test)
    :ok
  end

  describe "chip_count/1" do
    test "returns the number of boards on a running chain" do
      assert Diag.chip_count(:diag_test) == 3
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/diag_test.exs`

Expected: FAIL with `module Diag is not loaded` or similar.

- [ ] **Step 3: Create the `Diag` module**

Create `lib/neon_perceptron/diag.ex`:

```elixir
defmodule NeonPerceptron.Diag do
  @moduledoc """
  Interactive bench-side diagnostics for the LED chains.

  All helpers assume the target chain is running. Frame helpers are
  deterministic: each call blanks the full chain before setting the
  requested channel(s), so there is no hidden state between calls.

  Typical bench workflow:

      Diag.pause_ticker()
      Diag.light(:input_left, 0, 18, 1.0)   # inspect one channel on one chip
      Diag.light_all(:main, 20, 1.0)        # same channel lit on every chip
      Diag.light_chip(:main, 5, 1.0)        # is chip 5 alive?
      Diag.dark(:input_left)
      Diag.resume_ticker()
  """

  alias NeonPerceptron.{Board, Chain}

  @channels_per_board 24

  @doc """
  Return the number of chips (boards) on a running chain.
  """
  @spec chip_count(atom()) :: non_neg_integer()
  def chip_count(chain_id) do
    Chain.via(chain_id)
    |> :sys.get_state()
    |> Map.fetch!(:boards)
    |> length()
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/diag_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/neon_perceptron/diag.ex test/diag_test.exs
git commit -m "add NeonPerceptron.Diag skeleton with chip_count/1"
```

---

## Task 4: `Diag` frame helpers — `dark`, `light`, `light_all`, `light_chip`

**Files:**
- Modify: `lib/neon_perceptron/diag.ex`
- Modify: `test/diag_test.exs`

No per-helper unit tests — these are thin wrappers over `Chain.push_raw/2`, and the bug that matters (wrong channel wired) requires hardware. A single smoke test covers wiring.

- [ ] **Step 1: Write the smoke test**

In `test/diag_test.exs`, add a new `describe` block after the existing one:

```elixir
  describe "frame helpers (smoke, :host simulation)" do
    test "dark, light, light_all, light_chip all return :ok" do
      assert :ok = Diag.dark(:diag_test)
      assert :ok = Diag.light(:diag_test, 0, 18, 1.0)
      assert :ok = Diag.light_all(:diag_test, 20, 0.5)
      assert :ok = Diag.light_chip(:diag_test, 2, 1.0)
    end

    test "light with out-of-range chip_index raises" do
      assert_raise ArgumentError, fn ->
        Diag.light(:diag_test, 99, 18, 1.0)
      end
    end

    test "light with out-of-range channel raises" do
      assert_raise ArgumentError, fn ->
        Diag.light(:diag_test, 0, 24, 1.0)
      end
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/diag_test.exs`

Expected: FAIL — `Diag.dark/1`, `Diag.light/4`, `Diag.light_all/3`, `Diag.light_chip/3` are undefined.

- [ ] **Step 3: Implement the frame helpers**

Append to `lib/neon_perceptron/diag.ex` inside the `defmodule` block (before the final `end`):

```elixir
  @doc """
  Push an all-zero frame to the chain (blanks every channel on every chip).
  """
  @spec dark(atom()) :: :ok | {:error, :bad_length}
  def dark(chain_id) do
    Chain.push_raw(chain_id, blank_frame(chain_id))
  end

  @doc """
  Light one `channel` on one `chip_index` of `chain_id` to `value`
  (default 1.0). Every other channel on every other chip is zero.
  """
  @spec light(atom(), non_neg_integer(), non_neg_integer(), float()) ::
          :ok | {:error, :bad_length}
  def light(chain_id, chip_index, channel, value \\ 1.0)
      when is_integer(chip_index) and chip_index >= 0 and
             is_integer(channel) and channel >= 0 and channel < @channels_per_board do
    n = chip_count(chain_id)

    if chip_index >= n do
      raise ArgumentError,
            "chip_index #{chip_index} out of range (chain :#{chain_id} has #{n} chips)"
    end

    frame =
      blank_frame_for_count(n)
      |> List.replace_at(chip_index * @channels_per_board + channel, value)

    Chain.push_raw(chain_id, frame)
  end

  def light(_chain_id, _chip_index, channel, _value)
      when not (is_integer(channel) and channel >= 0 and channel < @channels_per_board) do
    raise ArgumentError, "channel must be in 0..23 (got #{inspect(channel)})"
  end

  @doc """
  Light `channel` on *every* chip in the chain to `value` (default 1.0).
  Every other channel is zero. Useful for checking channel consistency
  across boards.
  """
  @spec light_all(atom(), non_neg_integer(), float()) ::
          :ok | {:error, :bad_length}
  def light_all(chain_id, channel, value \\ 1.0)
      when is_integer(channel) and channel >= 0 and channel < @channels_per_board do
    n = chip_count(chain_id)

    frame =
      Enum.flat_map(0..(n - 1), fn _chip ->
        Board.blank() |> List.replace_at(channel, value)
      end)

    Chain.push_raw(chain_id, frame)
  end

  @doc """
  Light every channel on one `chip_index` to `value` (default 1.0). Every
  channel on every other chip is zero. Useful for "is this chip alive?"
  chain-propagation bisection.
  """
  @spec light_chip(atom(), non_neg_integer(), float()) ::
          :ok | {:error, :bad_length}
  def light_chip(chain_id, chip_index, value \\ 1.0)
      when is_integer(chip_index) and chip_index >= 0 do
    n = chip_count(chain_id)

    if chip_index >= n do
      raise ArgumentError,
            "chip_index #{chip_index} out of range (chain :#{chain_id} has #{n} chips)"
    end

    frame =
      Enum.flat_map(0..(n - 1), fn i ->
        if i == chip_index,
          do: List.duplicate(value, @channels_per_board),
          else: Board.blank()
      end)

    Chain.push_raw(chain_id, frame)
  end

  defp blank_frame(chain_id), do: blank_frame_for_count(chip_count(chain_id))

  defp blank_frame_for_count(n) do
    Enum.flat_map(0..(n - 1), fn _ -> Board.blank() end)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/diag_test.exs`

Expected: PASS (all 4 diag tests).

- [ ] **Step 5: Commit**

```bash
git add lib/neon_perceptron/diag.ex test/diag_test.exs
git commit -m "add Diag frame helpers: dark, light, light_all, light_chip"
```

---

## Task 5: `Diag` ticker control — `pause_ticker`, `resume_ticker`

**Files:**
- Modify: `lib/neon_perceptron/diag.ex`

No tests. These operate on the live `NeonPerceptron.Supervisor`, which has build-specific children. On `:host` the `TestPattern.Ticker` isn't started unless the test stands up the whole supervision tree, which is disproportionate for diagnostic helpers. Correctness is observed interactively on device.

- [ ] **Step 1: Implement `pause_ticker/0` and `resume_ticker/0`**

Append to `lib/neon_perceptron/diag.ex` before the final `end`:

```elixir
  @doc """
  Terminate any supervised child whose id ends in `.Ticker` (e.g.
  `NeonPerceptron.Builds.TestPattern.Ticker`) so bench diagnostics aren't
  overwritten 30 times per second.

  Returns `:ok` if a ticker was terminated, `:not_running` otherwise.
  """
  @spec pause_ticker() :: :ok | :not_running
  def pause_ticker do
    case find_ticker() do
      nil ->
        :not_running

      {sup, id} ->
        case Supervisor.terminate_child(sup, id) do
          :ok -> :ok
          {:error, :not_found} -> :not_running
        end
    end
  end

  @doc """
  Restart the ticker child previously paused by `pause_ticker/0`.

  Returns `:ok` on success, `:not_running` if no ticker child is known.
  """
  @spec resume_ticker() :: :ok | :not_running
  def resume_ticker do
    case find_ticker() do
      nil ->
        :not_running

      {sup, id} ->
        case Supervisor.restart_child(sup, id) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, :already_present} -> :ok
          {:error, _other} -> :not_running
        end
    end
  end

  defp find_ticker do
    case Process.whereis(NeonPerceptron.Supervisor) do
      nil ->
        nil

      sup ->
        sup
        |> Supervisor.which_children()
        |> Enum.find_value(fn {id, _, _, _} ->
          if is_atom(id) and String.ends_with?(Atom.to_string(id), ".Ticker") do
            {sup, id}
          end
        end)
    end
  end
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile --warnings-as-errors`

Expected: clean compile, no warnings.

- [ ] **Step 3: Run the full test suite**

Run: `mix test`

Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/neon_perceptron/diag.ex
git commit -m "add Diag.pause_ticker/0 and resume_ticker/0"
```

---

## Task 6: Deploy to `nerves.local` and smoke-test on device

This is a manual hardware verification step — no automation, no commit. It confirms the `Diag` helpers work against real SPI chains before Ben starts the actual bench investigation (which lives in TASK-17's remaining ACs, not in this plan).

- [ ] **Step 1: Build and upload the LED-board firmware**

Run: `mise run upload:leds-bench HOST=nerves.local`

Expected: firmware builds for `MIX_TARGET=rpi4`, OTA-pushes to the board, and the board reboots. OTA validates and commits (no rollback).

- [ ] **Step 2: SSH in and verify Diag is loaded**

Run:

```bash
ssh nerves.local 'Code.ensure_loaded?(NeonPerceptron.Diag) |> IO.inspect(label: :diag_loaded); NeonPerceptron.Diag.chip_count(:main) |> IO.inspect(label: :main_chips); NeonPerceptron.Diag.chip_count(:input_left) |> IO.inspect(label: :input_left_chips)'
```

Expected output:
```
diag_loaded: true
main_chips: 11
input_left_chips: 2
```

- [ ] **Step 3: Smoke-test pause + push_raw + resume**

Run:

```bash
ssh nerves.local 'NeonPerceptron.Diag.pause_ticker() |> IO.inspect(label: :pause); NeonPerceptron.Diag.light_all(:main, 20, 1.0) |> IO.inspect(label: :light_all); :timer.sleep(3000); NeonPerceptron.Diag.dark(:main) |> IO.inspect(label: :dark); NeonPerceptron.Diag.resume_ticker() |> IO.inspect(label: :resume)'
```

Expected output:
```
pause: :ok
light_all: :ok
dark: :ok
resume: :ok
```

During the 3-second `light_all`: observe how many chips on the `:main` chain actually light their front_red. Note the count — this is the first real data point for the chain-rendering diagnosis (TASK-17 AC #2). Record the observation in the task file.

- [ ] **Step 4: Hand off to TASK-17 bench investigation**

No further steps in this plan. From here, TASK-17 AC #2 (diagnose missing chips) and AC #3 (per-channel sweep) are driven interactively from IEx using the helpers this plan just shipped.

---

## Self-review summary

- **Spec coverage**: `Chain.push_raw/2` (Tasks 1–2), `Diag.chip_count/1` (Task 3), `Diag` frame helpers (Task 4), `Diag` ticker control (Task 5), deployment smoke test (Task 6). All spec items covered.
- **No placeholders**: every code block is complete Elixir. Every command has expected output. No "TODO" or "similar to earlier".
- **Type consistency**: `chip_count/1` returns `non_neg_integer()` in both the module and usage in helpers. `push_raw/2` returns `:ok | {:error, :bad_length}` in Chain and is passed through by Diag helpers. `light/light_all/light_chip` all take `chain_id :: atom()` and return the pass-through. Names match across tasks.
- **Out-of-scope flag**: Task 6 Step 3 deliberately notes the missing-chips observation as a data point for TASK-17 AC #2, not for this plan.
