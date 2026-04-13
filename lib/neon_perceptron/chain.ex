defmodule NeonPerceptron.Chain do
  @moduledoc """
  GenServer driving one SPI chain of daisy-chained TLC5947 boards.

  Each Chain subscribes to PubSub for `NetworkState` updates, calls the
  build's render function to produce PWM data for each chip in the chain,
  concatenates into one buffer, and sends it over SPI. Under the
  `spiN-1cs` overlay the kernel SPI driver toggles CE0 at transfer end,
  which drives XLAT --- so all chips in the chain latch simultaneously
  with no extra GPIO work.

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

  Exactly one of `:render_fn` or `:render_frame_fn` must be provided.
  """
  use GenServer

  require Logger

  alias NeonPerceptron.Board

  @type board_spec :: {String.t(), non_neg_integer()}

  @type config :: %{
          id: atom(),
          spi_device: String.t(),
          boards: [board_spec()],
          render_fn: (NeonPerceptron.NetworkState.t(), board_spec() -> [float()]) | nil,
          render_frame_fn: (NeonPerceptron.NetworkState.t() -> [float()]) | nil
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

    state = %{
      id: config.id,
      spi: spi,
      mode: mode,
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

  @impl true
  def handle_call({:update, network_state}, _from, state) do
    render_and_send(network_state, state)
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
    spi_transfer(state.spi, state.mode, data)
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

  defp open_spi(spi_device) do
    case Circuits.SPI.open(spi_device) do
      {:ok, spi} ->
        {spi, :hardware}

      {:error, reason} ->
        Logger.warning(
          "SPI #{spi_device} unavailable (#{inspect(reason)}), chain running in simulation mode"
        )

        {nil, :simulation}
    end
  end

  defp spi_transfer(spi, :hardware, data), do: Circuits.SPI.transfer!(spi, data)
  defp spi_transfer(_spi, :simulation, _data), do: :ok

  defp pubsub_available? do
    !!Process.whereis(NeonPerceptron.PubSub)
  end
end
