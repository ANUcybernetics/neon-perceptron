defmodule Brainworms.Knob do
  use GenServer
  alias Brainworms.BrainServer
  alias Brainworms.Utils
  alias Circuits.GPIO

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case {GPIO.open("GPIO17", :input), GPIO.open("GPIO18", :input)} do
      {{:ok, pin_a}, {:ok, pin_b}} ->
        # Enable interrupts on both edges
        GPIO.set_interrupts(pin_a, :both)
        GPIO.set_interrupts(pin_b, :both)

        # Set pull-up resistors
        GPIO.set_pull_mode(pin_a, :pullup)
        GPIO.set_pull_mode(pin_b, :pullup)

        {:ok,
         %{
           pin_a: pin_a,
           pin_b: pin_b,
           previous_a: GPIO.read(pin_a),
           previous_b: GPIO.read(pin_b),
           # start at 126, which is the digit "0"
           position: 126
         }}

      _ ->
        Logger.warning("Could not initialize GPIO pins for rotary encoder - interrupts disabled")

        {:ok,
         %{
           pin_a: nil,
           pin_b: nil,
           previous_a: 0,
           previous_b: 0,
           position: 0
         }}
    end
  end

  # Handler for GPIO17 (Pin A)
  @impl true
  def handle_info({:circuits_gpio, "GPIO17", _timestamp, value}, state) do
    new_position =
      determine_direction(
        value,
        GPIO.read(state.pin_b),
        state.previous_a,
        state.previous_b,
        state.position
      )

    BrainServer.touch_updated_at()

    {:noreply, %{state | previous_a: value, position: new_position}}
  end

  # Handler for GPIO18 (Pin B)
  @impl true
  def handle_info({:circuits_gpio, "GPIO18", _timestamp, value}, state) do
    new_position =
      determine_direction(
        GPIO.read(state.pin_a),
        value,
        state.previous_a,
        state.previous_b,
        state.position
      )

    {:noreply, %{state | previous_b: value, position: new_position}}
  end

  defp determine_direction(a, b, previous_a, previous_b, position) do
    case {previous_a, previous_b, a, b} do
      # Clockwise
      {1, 1, 0, 1} -> position + 1
      # Clockwise
      {0, 1, 0, 0} -> position + 1
      # Clockwise
      {0, 0, 1, 0} -> position + 1
      # Clockwise
      {1, 0, 1, 1} -> position + 1
      # Counter-clockwise
      {1, 1, 1, 0} -> position - 1
      # Counter-clockwise
      {1, 0, 0, 0} -> position - 1
      # Counter-clockwise
      {0, 0, 0, 1} -> position - 1
      # Counter-clockwise
      {0, 1, 1, 1} -> position - 1
      # No change or invalid state
      _ -> position
    end
  end

  @impl true
  def handle_call(:bitlist, _from, state) do
    # normalise (i.e. remove the factor of 4 inherent to rotary encoders)
    # and turn into a bitlist
    bitlist =
      state.position
      |> div(4)
      |> Utils.integer_to_bitlist()

    {:reply, bitlist, state}
  end

  @impl true
  def handle_call(:digit, _from, state) do
    # normalise (i.e. remove the factor of 4 inherent to rotary encoders)
    # and turn into a bitlist
    digit_bitlist =
      state.position
      |> div(4)
      |> Integer.mod(10)
      |> Utils.digit_to_bitlist()

    {:reply, digit_bitlist, state}
  end

  def bitlist do
    GenServer.call(__MODULE__, :bitlist)
  end

  def digit do
    GenServer.call(__MODULE__, :digit)
  end
end
