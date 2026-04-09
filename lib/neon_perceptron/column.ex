defmodule NeonPerceptron.Column do
  @moduledoc """
  GenServer driving one SPI column (chip select) of daisy-chained TLC5947 boards.

  Each Column subscribes to PubSub for `NetworkState` updates. On each update,
  it calls the build's render function to produce PWM data for each board in the
  chain, then sends the encoded binary over SPI.

  ## Config

  A column config map has these keys:

  - `:id` --- atom identifying this column (e.g. `:input_left`)
  - `:spi_device` --- SPI device path (e.g. `"spidev0.0"`)
  - `:boards` --- list of board specs, each `%{layer: "input", node_index: 0}`
  - `:render_fn` --- `(NetworkState.t(), board_spec) -> [float()]` returning 24 values
  - `:render_frame_fn` --- alternative: `(NetworkState.t()) -> [float()]` returning
    all N*24 values at once (for builds where boards don't map one-per-node)

  Exactly one of `:render_fn` or `:render_frame_fn` must be provided.
  """
  use GenServer

  require Logger

  alias NeonPerceptron.Board

  @type board_spec :: %{layer: String.t(), node_index: non_neg_integer()}

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
  Registry-based name for a column process.
  """
  def via(id), do: {:via, Registry, {NeonPerceptron.ColumnRegistry, id}}

  @impl true
  def init(config) do
    if pubsub_available?() do
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "network_state")
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
  Directly push a NetworkState update to this column (bypasses PubSub).
  """
  def update(column_id, network_state) do
    GenServer.cast(via(column_id), {:update, network_state})
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
          "SPI #{spi_device} unavailable (#{inspect(reason)}), column running in simulation mode"
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
