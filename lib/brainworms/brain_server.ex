defmodule Brainworms.BrainServer do
  @moduledoc """
  A GenServer for controlling the Brainworms.
  """
  use GenServer

  @display_refresh_interval 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @type state :: %{
          mode: :inference | :training,
          input: integer(),
          model: Axon.t(),
          last_activity: DateTime.t(),
          device_refs: %{wires: reference()}
        }

  @spec init(:ok) :: {:ok, state()}
  @impl true
  def init(:ok) do
    wires_ref = Brainworms.Display.Wires.init()

    # give it 1s to start up the first time (although not really needed)
    Process.send_after(self(), :update_lights, 1_000)

    {:ok,
     %{
       mode: :inference,
       input: 0,
       model: Brainworms.Model.new([4]),
       last_activity: DateTime.utc_now(),
       device_refs: %{wires: wires_ref}
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
  def handle_call(:update_lights, _from, state) do
    mode =
      if state.mode == :inference and
           DateTime.diff(DateTime.utc_now(), state.last_activity) > 10 do
        :training
      else
        state.mode
      end

    # Brainworms.Display.SevenSegment.light_up(mode, state.device_refs[:wires], state.input)
    # Brainworms.Display.Wires.light_up(mode, state.device_refs[:wires], state.model)

    # finally, schedule the next update
    Process.send_after(self(), :update_lights, @display_refresh_interval)
    {:reply, :ok, %{state | mode: mode}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # reset model state
    {:reply, :ok, state}
  end
end
