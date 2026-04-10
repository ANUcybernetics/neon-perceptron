defmodule NeonPerceptron.FrameCoordinator do
  @moduledoc """
  Coordinates SPI transfers across columns in the correct order.

  When multiple columns share an SPI data bus but have independent XLAT lines
  (via separate SPI1 CS pins), transfer ordering matters. Each spidev0.0
  transfer causes a spurious CE0 XLAT on the input_left column, so SPI1 columns
  must transfer first, and input_left (spidev0.0) must transfer last.

  This module subscribes to `"network_state"` PubSub and forwards updates to
  each column synchronously in the order specified by `column_ids`.
  """
  use GenServer

  alias NeonPerceptron.Column

  def start_link(column_ids) do
    GenServer.start_link(__MODULE__, column_ids, name: __MODULE__)
  end

  @impl true
  def init(column_ids) do
    if Process.whereis(NeonPerceptron.PubSub) do
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "network_state")
    end

    {:ok, %{column_ids: column_ids}}
  end

  @impl true
  def handle_info({:network_state, network_state}, state) do
    for id <- state.column_ids do
      Column.update_sync(id, network_state)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
