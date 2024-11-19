defmodule Brainworms.BrainServer do
  @moduledoc """
  A GenServer for controlling the Brainworms.
  """
  use GenServer

  alias Brainworms.Display
  alias Brainworms.Knob
  alias Brainworms.Model
  alias Brainworms.Utils

  @display_refresh_interval 10

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @type state :: %{
          mode: :inference | :training,
          updated_at: DateTime.t(),
          segment_phase: [integer()],
          devices: %{spi: reference()}
        }

  @spec init(:ok) :: {:ok, state()}
  @impl true
  def init(:ok) do
    {:ok, spi} = Circuits.SPI.open("spidev0.0")

    # Process.send_after(self(), :demo, @display_refresh_interval)
    Process.send_after(self(), :display, @display_refresh_interval)

    {:ok,
     %{
       mode: :inference,
       updated_at: DateTime.utc_now(),
       segment_phase: List.duplicate({0, 0}, 7),
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
    t = :os.system_time(:nanosecond) / 1.0e9

    # calculate the phases for the 7 segments so that when they start to "drift"
    # it's easy to make them drift from their current value (0 or 1)
    segment_phase =
      0..6
      # a small spread of frequencies, all very breathy
      |> Enum.map(fn x -> 0.3 + 0.0723 * x end)
      |> Enum.map(fn freq -> {freq, :math.fmod(t, 2 + :math.pi() * freq)} end)

    {:reply, :ok, %{state | updated_at: DateTime.utc_now(), segment_phase: segment_phase}}
  end

  @impl true
  def handle_info(:demo, state) do
    Display.step_demo(state.devices.spi)

    Process.send_after(self(), :demo, @display_refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:display, state) do
    knob = Knob.bitlist()

    seven_segment =
      if DateTime.diff(DateTime.utc_now(), state.updated_at) < 10 do
        knob
      else
        t = :os.system_time(:nanosecond) / 1.0e9

        knob
        |> Enum.map(&(&1 * (:math.pi() / 2)))
        |> Enum.zip(state.segment_phase)
        |> Enum.map(fn {phase_offset, {freq, phase}} ->
          Utils.osc(freq, phase + phase_offset, t) |> abs()
        end)
      end

    activations = Model.activations(seven_segment)

    Display.set(state.devices.spi, activations)

    # finally, schedule the next update
    Process.send_after(self(), :display, @display_refresh_interval)
    {:noreply, state}
  end

  ## client api
  def touch_updated_at do
    GenServer.call(__MODULE__, :touch_updated_at)
  end
end
