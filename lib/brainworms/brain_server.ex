defmodule Brainworms.BrainServer do
  @moduledoc """
  A GenServer for controlling the Brainworms.
  """
  use GenServer

  @display_refresh_interval 10

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @type state :: %{
          mode: :inference | :training,
          model: Axon.t(),
          last_activity: DateTime.t(),
          devices: %{spi: reference()}
        }

  @spec init(:ok) :: {:ok, state()}
  @impl true
  def init(:ok) do
    {:ok, spi} = Circuits.SPI.open("spidev0.0")

    # give it 1s to start up the first time (although not really needed)
    Process.send_after(self(), :demo, @display_refresh_interval)
    # Process.send_after(self(), :update_lights, 1_000)

    {:ok,
     %{
       mode: :inference,
       model: Brainworms.Model.new(4),
       last_activity: DateTime.utc_now(),
       devices: %{spi: spi}
     }}
  end

  @impl true
  def handle_call(:train_epoch, _from, state) do
    # TODO should update the model
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # reset model state
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:demo, state) do
    # Brainworms.Display.Wires.breathe(state.devices.spi)

    position = Brainworms.Input.Knob.get_position()
    digit = Integer.mod(position, 10)
    Brainworms.Display.set(state.devices.spi, digit, state.model)

    Process.send_after(self(), :demo, @display_refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:update_lights, state) do
    mode =
      if state.mode == :inference and
           DateTime.diff(DateTime.utc_now(), state.last_activity) > 10 do
        :training
      else
        state.mode
      end

    # finally, schedule the next update
    Process.send_after(self(), :update_lights, @display_refresh_interval)
    {:noreply, %{state | mode: mode}}
  end

  ## client api

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end
end
