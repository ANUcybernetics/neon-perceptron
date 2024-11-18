defmodule Brainworms.BrainServer do
  @moduledoc """
  A GenServer for controlling the Brainworms.
  """
  use GenServer

  alias Brainworms.Display
  alias Brainworms.Knob

  @display_refresh_interval 10

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @type state :: %{
          mode: :inference | :training,
          updated_at: DateTime.t(),
          devices: %{spi: reference()}
        }

  @spec init(:ok) :: {:ok, state()}
  @impl true
  def init(:ok) do
    {:ok, spi} = Circuits.SPI.open("spidev0.0")

    # Process.send_after(self(), :demo, @display_refresh_interval)
    # Process.send_after(self(), :display, @display_refresh_interval)

    {:ok,
     %{
       mode: :inference,
       updated_at: DateTime.utc_now(),
       devices: %{spi: spi}
     }}
  end

  @impl true
  def handle_call(:train_epoch, _from, state) do
    # TODO should update the model
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:touch_updated_at, _from, state) do
    {:reply, :ok, %{state | updated_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # reset model state
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:demo, state) do
    Display.step_demo(state.devices.spi)

    Process.send_after(self(), :demo, @display_refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:display, state) do
    seven_segment = Knob.bitlist()

    Display.set(state.devices.spi, seven_segment, %{})

    # mode =
    #   if state.mode == :inference and
    #        DateTime.diff(DateTime.utc_now(), state.updated_at) > 10 do
    #     :training
    #   else
    #     state.mode
    #   end

    # finally, schedule the next update
    Process.send_after(self(), :display, @display_refresh_interval)
    {:noreply, state}
  end

  ## client api
  def touch_updated_at do
    GenServer.call(__MODULE__, :touch_updated_at)
  end
end
