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
          seven_segment: [integer()],
          drift_at: DateTime.t(),
          drift_params: [{float(), float()}],
          devices: %{spi: %Circuits.SPI.SPIDev{}}
        }

  @spec init(:ok) :: {:ok, state()}
  @impl true
  def init(:ok) do
    {:ok, spi} = Circuits.SPI.open("spidev0.0")

    Process.send_after(self(), :demo, @display_refresh_interval)
    Process.send_after(self(), :demo, @display_refresh_interval)

    {:ok,
     %{
       mode: :inference,
       seven_segment: [1, 0, 0, 0, 0, 0, 0],
       drift_at: DateTime.utc_now(),
       drift_params: Utils.calculate_drift_params(Utils.float_now()),
       devices: %{spi: spi}
     }}
  end

  @impl true
  def handle_call(:train_epoch, _from, state) do
    # TODO should update the model
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:demo, state) do
    knob_bitlist =
      Knob.position()
      |> Utils.integer_to_bitlist()
      # nice to reverse it so that the "A" segment is changing fastest
      |> Enum.reverse()

    Display.breathe_demo(state.devices.spi, knob_bitlist)

    Process.send_after(self(), :demo, @display_refresh_interval)
    {:noreply, update_seven_segment(state, knob_bitlist)}
  end

  @impl true
  def handle_info(:display, state) do
    knob_bitlist =
      Knob.position()
      |> Utils.integer_to_bitlist()
      # nice to reverse it so that the "A" segment is changing fastest
      |> Enum.reverse()

    seven_segment =
      if DateTime.before?(DateTime.utc_now(), state.drift_at) do
        knob_bitlist
      else
        Utils.apply_drift(
          knob_bitlist,
          state.drift_params,
          Utils.float_now()
        )
      end

    activations = Model.activations(seven_segment)

    Display.set(state.devices.spi, activations)

    # finally, schedule the next update
    Process.send_after(self(), :display, @display_refresh_interval)
    {:noreply, update_seven_segment(state, knob_bitlist)}
  end

  ## client api
  def touch_updated_at do
    GenServer.call(__MODULE__, :touch_updated_at)
  end

  defp update_seven_segment(state, seven_segment) do
    if seven_segment == state.seven_segment do
      state
    else
      drift_at = DateTime.utc_now() |> DateTime.add(@drift_delay, :second)
      drift_params = Utils.calculate_drift_params(Utils.float_now())

      %{state | seven_segment: seven_segment, drift_at: drift_at, drift_params: drift_params}
    end
  end
end
