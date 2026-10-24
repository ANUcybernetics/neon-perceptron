defmodule NeonPerceptron.Lab do
  @moduledoc """
  Experiments for the webcam rig (TASK-24), run from weddle over SSH by
  the tool in `rig/`, or by hand at the IEx prompt.

  Every function that drives LEDs holds all chains first (see
  `Chain.hold/1`), so the build's own updates --- TestPattern's ticker,
  the trainer's broadcasts --- can't overwrite what the camera is
  measuring. `release/0` hands them back. Levels are raw 12-bit grayscale
  (0--4095, no gamma), so light output is linear in them.

      Lab.fill(4095)                      # every channel of every chain
      Lab.light_one(:main, 6, 18, 2048)   # one channel, the rest off
      Lab.start(%{kind: :relatch, rate_hz: 30})
      Lab.stop()
      Lab.release()

  ## Conditions

  `start/1` runs one of these until `stop/0`, re-sending the frames set
  up by `fill/1`, `fill/2`, `light_one/4` or `set_frame/2`:

  - `%{kind: :relatch, rate_hz: r}` --- shift and latch the same frames
    at `r` Hz. Add `latch: :blank_pulse` to pulse BLANK around XLAT (the
    chain needs a `:blank_gpio`, see `configure/2`).
  - `%{kind: :reshift, rate_hz: r}` --- shift the same frames at `r` Hz
    without latching. If BLANK and XLAT are behaving, nothing visible
    changes.
  - `%{kind: :wobble, chain: id, chip: c, channel: ch, depth: d,
    freq_hz: f, rate_hz: r}` --- vary one channel's level by a fraction
    `±d` at `f` Hz, latched at `r` Hz. Shows how small a flicker the
    camera can see.

  `:chains` limits `:relatch` and `:reshift` to a list of chains, and
  `:jitter_ms` moves each of their ticks by a random amount up to that
  far either side of its slot (less than half a period). A camera running
  near a multiple of the tick rate sees a regular disturbance at the same
  point of every frame, where it can't tell it from a steady one; jitter
  spreads the disturbances across the frame.

  The rig wraps each call in `reply/1`, whose result inspects as one
  `LAB <json>` line.
  """
  use GenServer

  alias NeonPerceptron.{Board, Chain}

  @channels_per_board 24
  @min_rate_hz 0.01
  @max_rate_hz 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Status of every chain (see `Chain.status/1`).
  """
  def chains, do: Enum.map(chain_ids(), &Chain.status/1)

  @doc """
  The running condition, driven GPIOs and the lit channel count of each
  chain's frame.
  """
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Hold every chain without changing what it shows.
  """
  def hold, do: GenServer.call(__MODULE__, :hold)

  @doc """
  Stop any condition, release driven GPIOs and hand every chain back to
  the build.
  """
  def release, do: GenServer.call(__MODULE__, :release)

  @doc """
  Latch `level` on every channel of every chain, or of one chain (the
  other chains keep their frames).
  """
  def fill(level), do: GenServer.call(__MODULE__, {:fill, :all, level})
  def fill(chain, level), do: GenServer.call(__MODULE__, {:fill, chain, level})

  @doc """
  Latch zero on every channel of every chain.
  """
  def dark, do: fill(0)

  @doc """
  Latch `level` on one channel and zero everywhere else, on every chain.
  """
  def light_one(chain, chip, channel, level),
    do: GenServer.call(__MODULE__, {:light_one, chain, chip, channel, level})

  @doc """
  Latch an arbitrary frame (`24 * chips` levels, chip-major) on one chain.
  """
  def set_frame(chain, levels), do: GenServer.call(__MODULE__, {:set_frame, chain, levels})

  @doc """
  Start a condition (see the moduledoc), replacing any running one.
  """
  def start(condition), do: GenServer.call(__MODULE__, {:start, Map.new(condition)})

  @doc """
  Stop the running condition and return its timing: ticks run, ticks
  skipped because the previous one overran, and the worst lateness.
  Returns `{:error, :not_running}` if nothing is running (the Lab may
  have restarted), and `{:error, {:condition_failed, reason}}` if the
  condition stopped itself because a shift failed.
  """
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc """
  Drive a GPIO (e.g. `"GPIO17"`) to `value` until `release_gpio/1`. For
  finding a chain's BLANK line: if driving a pin high darkens a chain,
  it's that chain's BLANK.
  """
  def probe_gpio(label, value) when is_binary(label) and value in [0, 1],
    do: GenServer.call(__MODULE__, {:probe_gpio, label, value})

  @doc """
  Stop driving a GPIO taken by `probe_gpio/2`, leaving it an input.
  """
  def release_gpio(label) when is_binary(label),
    do: GenServer.call(__MODULE__, {:release_gpio, label})

  @doc """
  Shift `frames` random frames through a chain without latching and
  compare what comes back on MISO with what went in one frame earlier.
  Only meaningful with the last chip's SOUT wired to MISO; without that
  wire MISO floats, and the counts of all-zero and all-ones read-backs
  usually show it.
  """
  def readback(chain, frames \\ 16) when is_integer(frames) and frames in 1..1000,
    do: GenServer.call(__MODULE__, {:readback, chain, frames}, 30_000)

  @doc """
  Change a chain's switches (see `Chain`).
  """
  def configure(chain, switches), do: Chain.configure(chain, switches)

  defmodule Reply do
    @moduledoc false
    defstruct [:json]

    defimpl Inspect do
      def inspect(%{json: json}, _opts), do: "LAB " <> json
    end
  end

  @doc """
  Wrap `result` for the rig: it inspects as one `LAB <json>` line, with
  `{"ok": result}` or `{"error": reason}`. NervesSSH sends back
  `inspect/1` of what a command returns, in a single write. Output
  printed by the command takes another route and can arrive after it.
  """
  def reply({:error, reason}), do: %Reply{json: JSON.encode!(%{error: inspect(reason)})}
  def reply(result), do: %Reply{json: JSON.encode!(%{ok: jsonable(result)})}

  defp jsonable(term) when is_struct(term), do: inspect(term)
  defp jsonable(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()

  defp jsonable(term) when is_binary(term),
    do: if(String.valid?(term), do: term, else: inspect(term))

  defp jsonable(term) when is_number(term) or is_atom(term), do: term
  defp jsonable(term), do: inspect(term)

  @impl true
  def init(nil), do: {:ok, %{frames: %{}, condition: nil, failed: nil, probes: %{}}}

  @impl true
  def handle_call(:status, _from, state) do
    frames = Map.new(state.frames, fn {id, levels} -> {id, Enum.count(levels, &(&1 > 0))} end)
    condition = state.condition && Map.take(state.condition, [:spec, :ticks, :skipped])

    {:reply, %{condition: condition, gpios: Map.keys(state.probes), lit_channels: frames}, state}
  end

  def handle_call(:hold, _from, state) do
    Enum.each(chain_ids(), &Chain.hold/1)
    {:reply, :ok, state}
  end

  def handle_call(:release, _from, state) do
    state = stop_condition(state)
    Enum.each(state.probes, fn {label, gpio} -> float_gpio(label, gpio) end)
    Enum.each(chain_ids(), &Chain.release/1)
    {:reply, :ok, %{state | frames: %{}, probes: %{}, failed: nil}}
  end

  def handle_call({:fill, which, level}, _from, state) do
    with :ok <- check_level(level),
         {:ok, ids} <- targets(which) do
      frames =
        Map.new(ids, fn id ->
          {id, List.duplicate(level, chip_count(id) * @channels_per_board)}
        end)

      latch_frames(state, frames)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:light_one, chain, chip, channel, level}, _from, state) do
    with :ok <- check_level(level),
         {:ok, [^chain]} <- targets(chain),
         :ok <- check_position(chain, chip, channel) do
      frames =
        Map.new(chain_ids(), fn id ->
          blank = List.duplicate(0, chip_count(id) * @channels_per_board)

          if id == chain,
            do: {id, List.replace_at(blank, chip * @channels_per_board + channel, level)},
            else: {id, blank}
        end)

      latch_frames(state, frames)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:set_frame, chain, levels}, _from, state) do
    with {:ok, [^chain]} <- targets(chain),
         true <- is_list(levels) || {:error, :bad_frame},
         :ok <- Enum.reduce_while(levels, :ok, fn l, :ok -> halt_on_error(check_level(l)) end) do
      latch_frames(state, %{chain => levels})
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:start, spec}, _from, state) do
    case validate_condition(spec, state) do
      {:ok, spec} ->
        state = stop_condition(state)
        hold_all()
        period_ms = 1000 / spec.rate_hz
        now = now_ms()

        condition = %{
          spec: spec,
          period_ms: period_ms,
          started_at: now,
          next_at: now + period_ms,
          fire_at: nil,
          ticks: 0,
          skipped: 0,
          max_late_ms: 0,
          ref: make_ref()
        }

        {:reply, :ok, %{state | condition: schedule_tick(condition), failed: nil}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:stop, _from, %{condition: nil, failed: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:stop, _from, %{condition: nil, failed: failed} = state),
    do: {:reply, {:error, {:condition_failed, failed}}, %{state | failed: nil}}

  def handle_call(:stop, _from, %{condition: condition} = state) do
    summary = %{
      kind: condition.spec.kind,
      ticks: condition.ticks,
      skipped: condition.skipped,
      max_late_ms: condition.max_late_ms,
      seconds: (now_ms() - condition.started_at) / 1000
    }

    {:reply, summary, stop_condition(state)}
  end

  def handle_call({:probe_gpio, label, value}, _from, state) do
    case Map.fetch(state.probes, label) do
      {:ok, gpio} ->
        Circuits.GPIO.write(gpio, value)
        {:reply, :ok, state}

      :error ->
        case Circuits.GPIO.open(label, :output, initial_value: value) do
          {:ok, gpio} -> {:reply, :ok, put_in(state, [:probes, label], gpio)}
          error -> {:reply, error, state}
        end
    end
  end

  def handle_call({:release_gpio, label}, _from, state) do
    case Map.pop(state.probes, label) do
      {nil, _probes} ->
        {:reply, {:error, :not_driven}, state}

      {gpio, probes} ->
        float_gpio(label, gpio)
        {:reply, :ok, %{state | probes: probes}}
    end
  end

  def handle_call({:readback, chain, frames}, _from, state) do
    case targets(chain) do
      {:ok, [^chain]} ->
        hold_all()
        {:reply, readback_stats(chain, frames), state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:tick, ref}, %{condition: %{ref: ref} = condition} = state) do
    now = now_ms()

    case run_tick(condition, state.frames, (now - condition.started_at) / 1000) do
      :ok ->
        {:noreply, %{state | condition: next_tick(condition, now)}}

      # A condition that can't shift isn't the condition the camera is
      # recording, so stop it; stop/0 reports why.
      {:error, reason} ->
        {:noreply, %{state | condition: nil, failed: {condition.spec.kind, reason}}}
    end
  end

  def handle_info({:tick, _stale_ref}, state), do: {:noreply, state}

  defp next_tick(condition, now) do
    condition = %{
      condition
      | ticks: condition.ticks + 1,
        max_late_ms: max(condition.max_late_ms, round(now - condition.fire_at)),
        next_at: condition.next_at + condition.period_ms
    }

    # After an overrun, skip any tick that is a whole period overdue
    # rather than firing ticks back to back.
    behind = max(0, floor((now_ms() - condition.next_at) / condition.period_ms))

    condition = %{
      condition
      | next_at: condition.next_at + behind * condition.period_ms,
        skipped: condition.skipped + behind
    }

    schedule_tick(condition)
  end

  defp run_tick(%{spec: %{kind: :relatch} = spec}, frames, _seconds),
    do: shift_each(spec.chains, frames, spec.latch)

  defp run_tick(%{spec: %{kind: :reshift} = spec}, frames, _seconds),
    do: shift_each(spec.chains, frames, :none)

  defp run_tick(%{spec: %{kind: :wobble} = spec}, frames, seconds) do
    index = spec.chip * @channels_per_board + spec.channel
    levels = Map.fetch!(frames, spec.chain)
    base = Enum.at(levels, index)
    level = base * (1 + spec.depth * :math.sin(2 * :math.pi() * spec.freq_hz * seconds))
    level = level |> round() |> max(0) |> min(Board.gs_max())
    shift_each([spec.chain], %{spec.chain => List.replace_at(levels, index, level)}, spec.latch)
  end

  defp shift_each(chains, frames, latch) do
    Enum.find_value(chains, :ok, fn id ->
      case Chain.shift(id, Map.fetch!(frames, id), latch) do
        {:ok, _transfer} -> nil
        error -> error
      end
    end)
  end

  defp validate_condition(%{kind: kind, rate_hz: rate} = spec, state)
       when kind in [:relatch, :reshift] and is_number(rate) and rate >= @min_rate_hz and
              rate <= @max_rate_hz do
    chains = Map.get(spec, :chains, Map.keys(state.frames))
    latch = Map.get(spec, :latch, :xlat)
    jitter = Map.get(spec, :jitter_ms, 0)

    cond do
      not (is_list(chains) and Enum.all?(chains, &is_atom/1)) -> {:error, {:bad_chains, chains}}
      chains == [] -> {:error, :no_frames}
      not Enum.all?(chains, &Map.has_key?(state.frames, &1)) -> {:error, :no_frame_for_chain}
      latch not in [:xlat, :blank_pulse] -> {:error, {:bad_latch, latch}}
      latch == :blank_pulse and not Enum.all?(chains, &blank_gpio?/1) -> {:error, :no_blank_gpio}
      not valid_jitter?(jitter, rate) -> {:error, {:bad_jitter, jitter}}
      true -> {:ok, %{kind: kind, rate_hz: rate, chains: chains, latch: latch, jitter_ms: jitter}}
    end
  end

  defp validate_condition(
         %{kind: :wobble, chain: chain, chip: chip, channel: channel, depth: depth} = spec,
         state
       )
       when is_number(depth) and depth > 0 and depth < 1 do
    freq = Map.get(spec, :freq_hz, 5.0)
    rate = Map.get(spec, :rate_hz, 30.0)
    latch = Map.get(spec, :latch, :xlat)

    with {:ok, levels} <- Map.fetch(state.frames, chain) |> or_error(:no_frame_for_chain),
         :ok <- check_position(chain, chip, channel),
         base = Enum.at(levels, chip * @channels_per_board + channel),
         true <- base > 0 || {:error, :dark_channel},
         true <- base * (1 + depth) <= Board.gs_max() || {:error, :wobble_clips},
         true <- valid_wobble_rates?(freq, rate) || {:error, :bad_rate},
         true <- latch in [:xlat, :blank_pulse] || {:error, {:bad_latch, latch}},
         true <- latch == :xlat || blank_gpio?(chain) || {:error, :no_blank_gpio} do
      {:ok,
       %{
         kind: :wobble,
         chain: chain,
         chip: chip,
         channel: channel,
         depth: depth,
         freq_hz: freq,
         rate_hz: rate,
         latch: latch,
         jitter_ms: 0
       }}
    end
  end

  defp validate_condition(spec, _state), do: {:error, {:bad_condition, spec}}

  defp or_error({:ok, value}, _reason), do: {:ok, value}
  defp or_error(:error, reason), do: {:error, reason}

  # A tick fires up to `jitter_ms` either side of its slot, while the slots
  # themselves stay evenly spaced.
  defp schedule_tick(%{spec: %{jitter_ms: jitter}} = condition) do
    fire_at = condition.next_at + (2 * :rand.uniform() - 1) * jitter
    Process.send_after(self(), {:tick, condition.ref}, round(fire_at), abs: true)
    %{condition | fire_at: fire_at}
  end

  defp valid_jitter?(jitter, rate), do: is_number(jitter) and jitter >= 0 and jitter < 500 / rate

  # The wobble needs at least two updates per cycle.
  defp valid_wobble_rates?(freq, rate) do
    is_number(freq) and is_number(rate) and rate >= @min_rate_hz and rate <= @max_rate_hz and
      freq > 0 and freq <= rate / 2
  end

  defp stop_condition(state), do: %{state | condition: nil}

  defp latch_frames(state, frames) do
    hold_all()

    result =
      Enum.reduce_while(frames, :ok, fn {id, levels}, :ok ->
        case Chain.shift(id, levels, :auto) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    case result do
      :ok -> {:reply, :ok, %{state | frames: Map.merge(state.frames, frames)}}
      error -> {:reply, error, state}
    end
  end

  defp readback_stats(chain, frames) do
    transfers =
      for _ <- 0..frames do
        levels =
          for _ <- 1..(chip_count(chain) * @channels_per_board), do: :rand.uniform(4096) - 1

        {:ok, transfer} = Chain.shift(chain, levels, :none)
        transfer
      end

    pairs = Enum.zip(transfers, tl(transfers))
    errors = Enum.map(pairs, fn {earlier, later} -> bit_errors(earlier.sent, later.received) end)
    received = Enum.map(tl(transfers), & &1.received)

    %{
      frames: frames,
      matched: Enum.count(errors, &(&1 == 0)),
      bit_errors: Enum.sum(errors),
      received_all_zero: Enum.count(received, &(&1 == :binary.copy(<<0>>, byte_size(&1)))),
      received_all_ones: Enum.count(received, &(&1 == :binary.copy(<<255>>, byte_size(&1))))
    }
  end

  defp bit_errors(expected, actual) do
    :crypto.exor(expected, actual)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn byte, acc -> acc + popcount(byte) end)
  end

  defp popcount(0), do: 0
  defp popcount(byte), do: Bitwise.band(byte, 1) + popcount(Bitwise.bsr(byte, 1))

  defp float_gpio(label, gpio) do
    Circuits.GPIO.close(gpio)

    case Circuits.GPIO.open(label, :input) do
      {:ok, input} -> Circuits.GPIO.close(input)
      _error -> :ok
    end
  end

  defp targets(:all), do: {:ok, chain_ids()}

  defp targets(chain) do
    if chain in chain_ids(), do: {:ok, [chain]}, else: {:error, {:unknown_chain, chain}}
  end

  defp check_level(level) when is_integer(level) and level >= 0 and level <= 4095, do: :ok
  defp check_level(level), do: {:error, {:bad_level, level}}

  defp halt_on_error(:ok), do: {:cont, :ok}
  defp halt_on_error(error), do: {:halt, error}

  defp check_position(chain, chip, channel)
       when is_integer(chip) and chip >= 0 and is_integer(channel) and channel >= 0 and
              channel < @channels_per_board do
    if chip < chip_count(chain), do: :ok, else: {:error, {:bad_chip, chip}}
  end

  defp check_position(_chain, chip, channel), do: {:error, {:bad_position, chip, channel}}

  defp hold_all, do: Enum.each(chain_ids(), &Chain.hold/1)

  defp blank_gpio?(id), do: Chain.status(id).switches.blank_gpio != nil

  defp chip_count(id), do: Chain.status(id).chips

  # A chain that has just died can linger in the registry for a moment.
  defp chain_ids do
    NeonPerceptron.ChainRegistry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
    |> Enum.map(fn {id, _pid} -> id end)
    |> Enum.sort()
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
