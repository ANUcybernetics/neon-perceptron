defmodule Brainworms.BrainServer do
  @moduledoc """
  A GenServer for controlling the Brainworms.
  """
  use GenServer
  alias Brainworms.Utils

  @display_refresh_interval 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @type state :: %{
          mode: :inference | :training,
          input: integer(),
          model: Axon.t(),
          last_activity: DateTime.t(),
          devices: %{spi: reference()}
        }

  @spec init(:ok) :: {:ok, state()}
  @impl true
  def init(:ok) do
    {:ok, spi} = Circuits.SPI.open("spidev0.0")

    # give it 1s to start up the first time (although not really needed)
    Process.send_after(self(), :demo_lights, 1_000)
    # Process.send_after(self(), :update_lights, 1_000)

    {:ok,
     %{
       mode: :inference,
       input: 0,
       model: Brainworms.Model.new(4),
       last_activity: DateTime.utc_now(),
       devices: %{spi: spi}
     }}
  end

  @impl true
  def handle_call({:knob, position_delta}, _from, state) do
    {:reply, :ok,
     %{
       state
       | input: Brainworms.Input.Knob.update(state.input, position_delta),
         mode: :inference,
         last_activity: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_call(:train_epoch, _from, state) do
    # TODO should update the model
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # reset model state
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:demo_lights, state) do
    val = Utils.osc(0.2)

    data =
      0..23
      |> Enum.map(fn _ -> 0.5 + 0.5 * val end)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(state.devices[:spi], data)

    Process.send_after(self(), :demo_lights, @display_refresh_interval)
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

    # Brainworms.Display.SevenSegment.light_up(mode, state.devices[:spi], state.input)
    # Brainworms.Display.Wires.light_up(mode, state.devices[:spi], state.model)

    # finally, schedule the next update
    Process.send_after(self(), :update_lights, @display_refresh_interval)
    {:noreply, %{state | mode: mode}}
  end
end
