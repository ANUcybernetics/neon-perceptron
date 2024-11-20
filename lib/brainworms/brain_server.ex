defmodule Brainworms.BrainServer do
  @moduledoc """
  A GenServer for controlling the Brainworms.
  """
  use GenServer

  alias Brainworms.Display
  alias Brainworms.Knob
  alias Brainworms.Model
  alias Brainworms.Utils

  # this is in ms
  @display_refresh_interval 10

  # this is in seconds
  @drift_delay 10

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @type state :: %{
          mode: :inference | :training,
          updated_at: DateTime.t(),
          drift_osc_params: [{float(), float()}],
          devices: %{spi: %Circuits.SPI.SPIDev{}}
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
       drift_osc_params: List.duplicate({0, 0}, 7),
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
    drift_osc_params = calculate_drift_osc_params(Utils.float_now() + @drift_delay)
    {:reply, :ok, %{state | updated_at: DateTime.utc_now(), drift_osc_params: drift_osc_params}}
  end

  @impl true
  def handle_info(:demo, state) do
    Display.step_demo(state.devices.spi)

    Process.send_after(self(), :demo, @display_refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:display, state) do
    knob_bitlist = Knob.bitlist()

    seven_segment =
      if DateTime.diff(DateTime.utc_now(), state.updated_at) < @drift_delay do
        knob_bitlist
      else
        seven_segment_brightness_with_drift(
          knob_bitlist,
          state.drift_osc_params,
          Utils.float_now()
        )
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

  def calculate_drift_osc_params(drift_start_time) do
    # calculate the phases for the 7 segments so that when they start to "drift"
    # it's easy to make them drift from their current value (0 or 1)
    0..6
    # a small spread of frequencies, all very "breathy" (i.e. around 0.5Hz)
    |> Enum.map(fn x -> 0.3 + 0.0723 * x end)
    |> Enum.map(fn freq -> {freq, :math.fmod(drift_start_time, 2 + :math.pi() * freq)} end)
  end

  def seven_segment_brightness_with_drift(bitlist, drift_osc_params, t) do
    bitlist
    # add pi/2 for all the "high" bits so they start from 1, otherwise 0
    |> Enum.map(&(&1 * (:math.pi() / 2)))
    # zip with the already-calculated freq/phases for each segment
    |> Enum.zip(drift_osc_params)
    # calculate the brightness for each segment (abs(), because it needs to be in [0, 1])
    |> Enum.map(fn {phase_offset, {freq, phase}} ->
      Utils.osc(freq, phase + phase_offset, t) |> abs()
    end)
  end
end
