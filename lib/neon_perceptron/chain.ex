defmodule NeonPerceptron.Chain do
  @moduledoc """
  GenServer driving one SPI chain of daisy-chained TLC5947 boards.

  Each Chain subscribes to PubSub for `NetworkState` updates, calls the
  build's render function to produce PWM data for each chip in the chain,
  concatenates into one buffer, and sends it over SPI, and then pulses the
  `:xlat_gpio` manually to latch all chips simultaneously. The switches
  below decide which updates get sent, and how they are latched.

  ## Config

  A chain config map has these keys:

  - `:id` --- atom identifying this chain (e.g. `:input_left`, `:main`).
  - `:spi_device` --- spidev path (e.g. `"spidev0.0"`).
  - `:boards` --- ordered list of chips from MOSI-side to chain end. Each
    entry is a tuple `{layer, node_index}` naming the logical node that
    chip visualises. Repeating a node means "another physical chip for
    the same node" (e.g. front + rear copies of a hidden node).
  - `:render_fn` --- `(NetworkState.t(), {layer, index}) -> [float()]`
    returning 24 channel values for one chip.
  - `:render_frame_fn` --- alternative:
    `(NetworkState.t()) -> [float()]` returning all `N*24` values for
    the whole chain at once. Used by V1 where the pin mapping doesn't
    follow one-chip-per-node.
  - `:xlat_gpio` --- GPIO label (e.g. `"GPIO8"`) to pulse as XLAT after
    each SPI transfer. On BCM2711 (Pi 4), kernel CE0 does not toggle
    reliably enough to latch the TLC5947 on any SPI bus, so manual XLAT
    is required. The overlay must be configured to NOT claim this pin
    --- e.g. `dtoverlay=spi0-1cs,cs0_pin=26` redirects kernel CE0 to
    unused GPIO 26, freeing GPIO 8 for userspace control. When `nil`,
    relies on the kernel CS pulse as XLAT (untested on Pi 4).

  Exactly one of `:render_fn` or `:render_frame_fn` must be provided.

  ## Switches

  Every XLAT rising edge turns a TLC5947's outputs off until its next PWM
  period starts, so each latch loses up to one period (0.7--1.7 ms) of
  light at a random point. These keys change how often the chain latches,
  and how. Set them in the chain config, or at runtime with `configure/2`.
  The defaults latch every update straight away, as in the April bench
  sessions.

  - `:send_on_change` --- skip an update whose frame matches the one
    latched or queued. Default `false`.
  - `:max_rate_hz` --- latch at most this often. An update that arrives
    sooner waits for its slot, and a newer one replaces it. Default `nil`
    (no cap).
  - `:refresh_ms` --- re-send the latched frame when nothing has been
    latched for this long, to recover from a corrupted transfer. Default
    `nil` (off).
  - `:blank_gpio` --- GPIO label of the chain's BLANK line. BLANK is held
    high (outputs off) from start-up until the first latch, then low.
    Default `nil` (not driven).
  - `:blank_pulse` --- with `:blank_gpio`, raise BLANK around every XLAT
    pulse. That resets the PWM counter, so the new frame starts a fresh
    period instead of the latch cutting the current one short. Default
    `false`.

  `hold/1` makes the chain ignore updates until `release/1`, so an
  experiment can drive it with `shift/3` without the build overwriting
  its frames.
  """
  use GenServer

  require Logger

  alias NeonPerceptron.Board

  @typedoc """
  Opaque per-chip descriptor. Chain passes this unchanged to the
  build's `render_fn`. Builds define their own shape --- V2 uses
  `%{node: {layer, index}, noodles: [...]}`, TestPattern uses a
  placeholder tuple.
  """
  @type board_spec :: term()

  @typedoc """
  The config map, which may also carry any of the `t:switches/0` keys.
  """
  @type config :: %{
          id: atom(),
          spi_device: String.t(),
          boards: [board_spec()],
          render_fn: (NeonPerceptron.NetworkState.t(), board_spec() -> [float()]) | nil,
          render_frame_fn: (NeonPerceptron.NetworkState.t() -> [float()]) | nil,
          xlat_gpio: String.t() | nil
        }

  @type switches :: %{
          send_on_change: boolean(),
          max_rate_hz: number() | nil,
          refresh_ms: pos_integer() | nil,
          blank_gpio: String.t() | nil,
          blank_pulse: boolean()
        }

  @typedoc """
  How `shift/3` latches: `:xlat`, `:blank_pulse` (BLANK high, pulse XLAT,
  BLANK low), `:none` (shift only), or `:auto` (`:blank_pulse` when that
  switch is on, otherwise `:xlat`).
  """
  @type latch :: :auto | :xlat | :blank_pulse | :none

  @switch_defaults %{
    send_on_change: false,
    max_rate_hz: nil,
    refresh_ms: nil,
    blank_gpio: nil,
    blank_pulse: false
  }

  def child_spec(config) do
    %{
      id: {__MODULE__, config.id},
      start: {__MODULE__, :start_link, [config]}
    }
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via(config.id))
  end

  @doc """
  Registry-based name for a chain process.
  """
  def via(id), do: {:via, Registry, {NeonPerceptron.ChainRegistry, id}}

  @impl true
  def init(config) do
    unless config[:pubsub_subscribe] == false do
      if pubsub_available?() do
        Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "network_state")
      end
    end

    switches =
      case config |> Map.take(Map.keys(@switch_defaults)) |> validate_switches() do
        {:ok, changes} -> Map.merge(@switch_defaults, changes)
        {:error, reason} -> raise ArgumentError, "bad chain switch: #{inspect(reason)}"
      end

    {spi, mode} = open_spi(config.spi_device)
    xlat = open_xlat(config[:xlat_gpio])

    # A BLANK line that won't open is reported as not driven.
    {blank, switches} =
      case open_blank(switches.blank_gpio, 1) do
        {:ok, blank} -> {blank, switches}
        {:error, _reason} -> {nil, %{switches | blank_gpio: nil}}
      end

    state = %{
      id: config.id,
      spi_device: config.spi_device,
      spi: spi,
      mode: mode,
      xlat: xlat,
      blank: blank,
      blanked: blank != nil,
      boards: config[:boards] || [],
      render_fn: config[:render_fn],
      render_frame_fn: config[:render_frame_fn],
      switches: switches,
      held: false,
      latched: nil,
      latched_at: nil,
      pending: nil,
      pending_timer: nil,
      refresh_timer: nil,
      counts: %{requested: 0, sent: 0, unchanged: 0, coalesced: 0, refreshed: 0, ignored: 0}
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:network_state, network_state}, state) do
    {:noreply, request(state, network_state)}
  end

  def handle_info({:timeout, timer, :send_pending}, %{pending_timer: timer} = state) do
    data = state.pending
    state = %{state | pending: nil, pending_timer: nil}

    if state.switches.send_on_change and data == state.latched do
      {:noreply, count(state, :unchanged)}
    else
      {:noreply, send_frame(state, data)}
    end
  end

  def handle_info({:timeout, timer, :refresh}, %{refresh_timer: timer} = state) do
    state = %{state | refresh_timer: nil}

    # A queued frame is about to latch, and re-arms the refresh when it does.
    if state.pending do
      {:noreply, state}
    else
      {_received, state} = transmit(state, state.latched, :auto)
      {:noreply, count(state, :refreshed)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Directly push a NetworkState update to this chain (bypasses PubSub).
  """
  def update(chain_id, network_state) do
    GenServer.cast(via(chain_id), {:update, network_state})
  end

  @doc """
  Synchronous version of `update/2`. Returns once the update has been
  sent, skipped or queued. Rarely needed now that chains have
  independent XLATs --- kept for use cases that want back-pressure.
  """
  def update_sync(chain_id, network_state) do
    GenServer.call(via(chain_id), {:update, network_state})
  end

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

  @doc """
  Like `push_raw/2` but skips the `24 * chip_count` length check so
  callers can intentionally clock more bits than the chain can hold.
  Extra bits fall off the last chip's SOUT.

  Diagnostic only. Use `Diag.flood_oversize/3`.
  """
  @spec push_oversize(atom(), [float()]) :: :ok
  def push_oversize(chain_id, channel_values) when is_list(channel_values) do
    GenServer.call(via(chain_id), {:push_oversize, channel_values})
  end

  @doc """
  Shift raw 12-bit grayscale values (`24 * chip_count`, chip-major like
  `push_raw/2`, no gamma) into the chain and latch them as `latch` says
  (see `t:latch/0`). Ignores the switches and `hold/1`.

  Returns the bytes sent and the bytes clocked in on MISO meanwhile. With
  the last chip's SOUT wired to MISO, those are the shift register's
  previous contents.
  """
  @spec shift(atom(), [non_neg_integer()], latch()) ::
          {:ok, %{sent: binary(), received: binary()}}
          | {:error, :bad_length | :bad_level | :no_blank_gpio}
  def shift(chain_id, gs_values, latch \\ :auto)
      when is_list(gs_values) and latch in [:auto, :xlat, :blank_pulse, :none] do
    GenServer.call(via(chain_id), {:shift, gs_values, latch})
  end

  @doc """
  Change switches at runtime (see the moduledoc). Keys not given keep
  their current values. If a new `:blank_gpio` won't open (another
  handle has it, or the label is wrong), nothing changes.
  """
  @spec configure(atom(), keyword() | map()) ::
          :ok | {:error, {:invalid_switch, atom(), term()} | {:blank_gpio, term()}}
  def configure(chain_id, switches) do
    GenServer.call(via(chain_id), {:configure, Map.new(switches)})
  end

  @doc """
  Ignore updates from the build until `release/1`. Drops any frame
  waiting on `:max_rate_hz`.
  """
  @spec hold(atom()) :: :ok
  def hold(chain_id), do: GenServer.call(via(chain_id), :hold)

  @doc """
  Resume taking updates after `hold/1`.
  """
  @spec release(atom()) :: :ok
  def release(chain_id), do: GenServer.call(via(chain_id), :release)

  @doc """
  The chain's switches, counters and hold state.

  `:counts` tallies updates: `:requested` (rendered), `:sent`,
  `:unchanged` (skipped by `:send_on_change`), `:coalesced` (replaced
  while waiting on `:max_rate_hz`), `:refreshed` and `:ignored` (arrived
  while held).
  """
  @spec status(atom()) :: map()
  def status(chain_id), do: GenServer.call(via(chain_id), :status)

  @impl true
  def handle_call({:update, network_state}, _from, state) do
    {:reply, :ok, request(state, network_state)}
  end

  @impl true
  def handle_call({:push_raw, channel_values}, _from, state) do
    expected = length(state.boards) * Board.channels_per_board()

    if length(channel_values) == expected do
      data = channel_values |> Enum.reverse() |> Board.encode()
      {_received, state} = state |> cancel_pending() |> transmit(data, :auto)
      {:reply, :ok, state}
    else
      {:reply, {:error, :bad_length}, state}
    end
  end

  @impl true
  def handle_call({:push_oversize, channel_values}, _from, state) do
    data = channel_values |> Enum.reverse() |> Board.encode()
    {_received, state} = state |> cancel_pending() |> transmit(data, :auto)
    # What the chips latched isn't a frame of this chain any more, so there's
    # nothing to compare against or refresh.
    {:reply, :ok, %{cancel_timer(state, :refresh_timer) | latched: nil}}
  end

  @impl true
  def handle_call({:shift, gs_values, latch}, _from, state) do
    latch = resolve_latch(latch, state)

    cond do
      length(gs_values) != length(state.boards) * Board.channels_per_board() ->
        {:reply, {:error, :bad_length}, state}

      not Enum.all?(gs_values, &(is_integer(&1) and &1 >= 0 and &1 <= Board.gs_max())) ->
        {:reply, {:error, :bad_level}, state}

      latch == :blank_pulse and state.blank == nil ->
        {:reply, {:error, :no_blank_gpio}, state}

      true ->
        data = gs_values |> Enum.reverse() |> Board.pack()
        state = if latch == :none, do: state, else: cancel_pending(state)
        {received, state} = transmit(state, data, latch)
        {:reply, {:ok, %{sent: data, received: received}}, state}
    end
  end

  @impl true
  def handle_call({:configure, changes}, _from, state) do
    with {:ok, changes} <- validate_switches(changes),
         {:ok, configured} <- apply_switches(state, changes) do
      {:reply, :ok, configured}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:hold, _from, state) do
    state = state |> cancel_pending() |> cancel_timer(:refresh_timer)
    {:reply, :ok, %{state | held: true}}
  end

  @impl true
  def handle_call(:release, _from, state) do
    {:reply, :ok, schedule_refresh(%{state | held: false})}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      id: state.id,
      spi_device: state.spi_device,
      mode: state.mode,
      chips: length(state.boards),
      held: state.held,
      switches: state.switches,
      counts: state.counts,
      pending: state.pending != nil,
      ms_since_latch: state.latched_at && now_ms() - state.latched_at
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:update, network_state}, state) do
    {:noreply, request(state, network_state)}
  end

  defp request(%{held: true} = state, _network_state), do: count(state, :ignored)

  defp request(state, network_state) do
    data =
      network_state
      |> render_all_boards(state)
      |> Enum.reverse()
      |> Board.encode()

    state = count(state, :requested)

    cond do
      state.switches.send_on_change and data == (state.pending || state.latched) ->
        count(state, :unchanged)

      rate_limited?(state) ->
        queue(state, data)

      true ->
        send_frame(state, data)
    end
  end

  defp render_all_boards(network_state, %{render_frame_fn: render_frame_fn})
       when is_function(render_frame_fn) do
    render_frame_fn.(network_state)
  end

  defp render_all_boards(network_state, %{render_fn: render_fn, boards: boards})
       when is_function(render_fn) do
    Enum.flat_map(boards, fn board_spec ->
      render_fn.(network_state, board_spec)
    end)
  end

  defp render_all_boards(_network_state, %{boards: boards}) do
    Enum.flat_map(boards, fn _board_spec -> Board.blank() end)
  end

  defp rate_limited?(%{switches: %{max_rate_hz: nil}}), do: false
  defp rate_limited?(%{latched_at: nil}), do: false
  defp rate_limited?(state), do: now_ms() < next_slot(state)

  defp next_slot(state), do: state.latched_at + 1000 / state.switches.max_rate_hz

  defp queue(state, data) do
    state = if state.pending, do: count(state, :coalesced), else: state

    timer =
      state.pending_timer ||
        :erlang.start_timer(ceil(next_slot(state)), self(), :send_pending, abs: true)

    %{state | pending: data, pending_timer: timer}
  end

  defp send_frame(state, data) do
    {_received, state} = state |> cancel_pending() |> transmit(data, :auto)
    count(state, :sent)
  end

  defp cancel_pending(state), do: %{cancel_timer(state, :pending_timer) | pending: nil}

  defp cancel_timer(state, key) do
    case Map.fetch!(state, key) do
      nil -> :ok
      timer -> :erlang.cancel_timer(timer)
    end

    Map.put(state, key, nil)
  end

  defp schedule_refresh(state) do
    state = cancel_timer(state, :refresh_timer)

    if state.switches.refresh_ms && state.latched && !state.held do
      %{state | refresh_timer: :erlang.start_timer(state.switches.refresh_ms, self(), :refresh)}
    else
      state
    end
  end

  defp count(state, key), do: update_in(state, [:counts, key], &(&1 + 1))

  defp resolve_latch(:auto, %{switches: %{blank_pulse: true}, blank: blank}) when blank != nil,
    do: :blank_pulse

  defp resolve_latch(:auto, _state), do: :xlat
  defp resolve_latch(latch, _state), do: latch

  defp validate_switches(switches) do
    Enum.reduce_while(switches, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if valid_switch?(key, value),
        do: {:cont, {:ok, Map.put(acc, key, value)}},
        else: {:halt, {:error, {:invalid_switch, key, value}}}
    end)
  end

  defp valid_switch?(key, value) when key in [:send_on_change, :blank_pulse],
    do: is_boolean(value)

  defp valid_switch?(:max_rate_hz, value), do: is_nil(value) or (is_number(value) and value > 0)
  defp valid_switch?(:refresh_ms, value), do: is_nil(value) or (is_integer(value) and value > 0)
  defp valid_switch?(:blank_gpio, value), do: is_nil(value) or is_binary(value)
  defp valid_switch?(_key, _value), do: false

  defp apply_switches(state, changes) do
    switches = Map.merge(state.switches, changes)

    with {:ok, state} <- reopen_blank(state, state.switches.blank_gpio, switches.blank_gpio) do
      {:ok, schedule_refresh(%{state | switches: switches})}
    end
  end

  defp reopen_blank(state, label, label), do: {:ok, state}

  # Opens the new line before letting go of the old one, so a failure leaves
  # the chain as it was. The chips are already showing a frame, so the new
  # line starts low.
  defp reopen_blank(state, _old_label, new_label) do
    case open_blank(new_label, 0) do
      {:ok, blank} ->
        if state.blank, do: Circuits.GPIO.close(state.blank)
        {:ok, %{state | blank: blank, blanked: false}}

      {:error, reason} ->
        {:error, {:blank_gpio, reason}}
    end
  end

  # The TLC5947 takes up to 30 MHz on its own but only 15 MHz cascaded,
  # and 25 MHz failed past chip 3 on the 9-chip :main ribbon chain
  # (2026-04-17). 1 MHz matches the known-good Python bench config; a
  # 9-chip frame is ~2.6 ms, well inside the 33 ms tick.
  @spi_speed_hz 1_000_000

  # Kept from the April bench sessions: a wait between the transfer
  # returning and XLAT. It was added for a suspected early return from the
  # aux SPI driver, but spi-bcm2835aux doesn't complete a transfer until
  # it has clocked in the last byte, which can't happen before the last
  # bit has gone out. So it's a harmless precaution, not a fix. It
  # busy-waits because Process.sleep/1 has a 1 ms floor.
  @xlat_delay_us 100

  defp open_spi(spi_device) do
    case Circuits.SPI.open(spi_device, speed_hz: @spi_speed_hz) do
      {:ok, spi} ->
        {spi, :hardware}

      {:error, reason} ->
        Logger.warning(
          "SPI #{spi_device} unavailable (#{inspect(reason)}), chain running in simulation mode"
        )

        {nil, :simulation}
    end
  end

  defp open_xlat(nil), do: nil

  defp open_xlat(gpio_label) do
    case Circuits.GPIO.open(gpio_label, :output, initial_value: 0) do
      {:ok, gpio} ->
        gpio

      {:error, reason} ->
        Logger.warning(
          "XLAT GPIO #{gpio_label} unavailable (#{inspect(reason)}), chain running without manual XLAT"
        )

        nil
    end
  end

  defp open_blank(nil, _initial_value), do: {:ok, nil}

  defp open_blank(gpio_label, initial_value) do
    case Circuits.GPIO.open(gpio_label, :output, initial_value: initial_value) do
      {:ok, gpio} ->
        {:ok, gpio}

      {:error, reason} ->
        Logger.warning(
          "BLANK GPIO #{gpio_label} unavailable (#{inspect(reason)}), chain running without BLANK"
        )

        {:error, reason}
    end
  end

  # Shifts `data` out, latches it as `latch` says, and returns what came
  # back on MISO.
  defp transmit(state, data, latch) do
    started_at = now_ms()
    received = spi_transfer(state, data)

    state =
      case resolve_latch(latch, state) do
        :none -> state
        latch -> state |> pulse_latch(latch) |> record_latch(data, started_at)
      end

    {received, state}
  end

  defp spi_transfer(%{mode: :hardware, spi: spi}, data), do: Circuits.SPI.transfer!(spi, data)
  defp spi_transfer(%{mode: :simulation}, data), do: :binary.copy(<<0>>, byte_size(data))

  # Without SPI the shift registers hold whatever they powered up with, so
  # don't latch it.
  defp pulse_latch(%{mode: :simulation} = state, _latch), do: state

  defp pulse_latch(state, :xlat) do
    busy_wait_us(@xlat_delay_us)
    pulse_xlat(state.xlat)

    if state.blanked do
      Circuits.GPIO.write(state.blank, 0)
    end

    %{state | blanked: false}
  end

  defp pulse_latch(state, :blank_pulse) do
    busy_wait_us(@xlat_delay_us)
    Circuits.GPIO.write(state.blank, 1)
    pulse_xlat(state.xlat)
    Circuits.GPIO.write(state.blank, 0)
    %{state | blanked: false}
  end

  defp record_latch(state, data, started_at) do
    schedule_refresh(%{state | latched: data, latched_at: started_at})
  end

  defp pulse_xlat(nil), do: :ok

  defp pulse_xlat(gpio) do
    Circuits.GPIO.write(gpio, 1)
    Circuits.GPIO.write(gpio, 0)
  end

  defp busy_wait_us(us) do
    deadline = System.monotonic_time(:microsecond) + us
    spin_until(deadline)
  end

  defp spin_until(deadline) do
    if System.monotonic_time(:microsecond) < deadline do
      spin_until(deadline)
    else
      :ok
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp pubsub_available? do
    !!Process.whereis(NeonPerceptron.PubSub)
  end
end
