defmodule NeonPerceptron.Chain do
  @moduledoc """
  GenServer driving one SPI chain of daisy-chained TLC5947 boards.

  Each Chain subscribes to PubSub for `NetworkState` updates, calls the
  build's render function to produce PWM data for each chip in the chain,
  concatenates into one buffer, and sends it over SPI, and then pulses the
  `:xlat_gpio` manually to latch all chips simultaneously.

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

  @type config :: %{
          id: atom(),
          spi_device: String.t(),
          boards: [board_spec()],
          render_fn: (NeonPerceptron.NetworkState.t(), board_spec() -> [float()]) | nil,
          render_frame_fn: (NeonPerceptron.NetworkState.t() -> [float()]) | nil,
          xlat_gpio: String.t() | nil
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

    {spi, mode} = open_spi(config.spi_device)
    xlat = open_xlat(config[:xlat_gpio])

    state = %{
      id: config.id,
      spi: spi,
      mode: mode,
      xlat: xlat,
      boards: config[:boards] || [],
      render_fn: config[:render_fn],
      render_frame_fn: config[:render_frame_fn]
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:network_state, network_state}, state) do
    render_and_send(network_state, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Directly push a NetworkState update to this chain (bypasses PubSub).
  """
  def update(chain_id, network_state) do
    GenServer.cast(via(chain_id), {:update, network_state})
  end

  @doc """
  Synchronous version of `update/2`. Returns after the SPI transfer
  completes. Rarely needed now that chains have independent XLATs ---
  kept for use cases that want back-pressure.
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

  @impl true
  def handle_call({:update, network_state}, _from, state) do
    render_and_send(network_state, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:push_raw, channel_values}, _from, state) do
    expected = length(state.boards) * 24

    if length(channel_values) == expected do
      data = channel_values |> Enum.reverse() |> Board.encode()
      spi_transfer(state.spi, state.mode, state.xlat, data)
      {:reply, :ok, state}
    else
      {:reply, {:error, :bad_length}, state}
    end
  end

  @impl true
  def handle_call({:push_oversize, channel_values}, _from, state) do
    data = channel_values |> Enum.reverse() |> Board.encode()
    spi_transfer(state.spi, state.mode, state.xlat, data)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:update, network_state}, state) do
    render_and_send(network_state, state)
    {:noreply, state}
  end

  defp render_and_send(network_state, state) do
    channel_values = render_all_boards(network_state, state)
    data = channel_values |> Enum.reverse() |> Board.encode()
    spi_transfer(state.spi, state.mode, state.xlat, data)
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

  # TLC5947 datasheet max is 30 MHz, but bench testing 2026-04-17 showed
  # 25 MHz degrades through the 9-chip :main ribbon chain (chips 4-8 stay
  # dark from signal integrity loss). 1 MHz matches the known-good Python
  # bench config; a 9-chip frame is ~2.6 ms, well inside the 33 ms tick.
  @spi_speed_hz 1_000_000

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

  defp spi_transfer(spi, :hardware, xlat, data) do
    Circuits.SPI.transfer!(spi, data)
    # BCM2711 aux SPI (SPI1) returns from transfer! before the TX FIFO has
    # fully drained onto MOSI — bench 2026-04-17 observed a uniform 36-bit
    # (3-channel) shift on :main because XLAT fired while the last bits
    # were still in flight. Classic SPI0 (:input_left) doesn't need this
    # but pays a harmless ~100 µs. µs-precision busy-wait avoids BEAM's
    # 1 ms Process.sleep floor (which produced visible frame jitter).
    busy_wait_us(100)
    pulse_xlat(xlat)
  end

  defp spi_transfer(_spi, :simulation, _xlat, _data), do: :ok

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

  defp pubsub_available? do
    !!Process.whereis(NeonPerceptron.PubSub)
  end
end
