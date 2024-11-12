defmodule Brainworms.BrainServer do
  @moduledoc """
  A GenServer for controlling the Brainworms.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @type state :: %{
          input: integer(),
          model: Axon.t(),
          last_activity: DateTime.t()
        }

  @spec init(:ok) :: {:ok, state()}
  @impl true
  def init(:ok) do
    {:ok, %{input: 0, model: Brainworms.Model.new([4]), last_activity: DateTime.utc_now()}}
  end

  @impl true
  def handle_call({:knob, position_delta}, _from, state) do
    {:reply, :ok, %{state | input: Brainworms.Input.Knob.update(state.input, position_delta)}}
  end

  @impl true
  def handle_call(_msg, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
