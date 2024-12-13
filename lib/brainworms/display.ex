defmodule Brainworms.Display do
  @moduledoc """
  A GenServer for controlling and displaying neural network activations on an LED display.
  """
  use GenServer

  alias Brainworms.Utils

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @type state :: %{spi: %Circuits.SPI.SPIDev{}}

  @spec init(:ok) :: {:ok, state()}
  @impl true
  def init(:ok) do
    {:ok, spi} = Circuits.SPI.open("spidev0.0")
    {:ok, %{spi: spi}}
  end

  @impl true
  def handle_cast({:update, activations}, state) do
    activations
    |> scale_activations()
    |> then(&set_activations(state.spi, &1))

    {:noreply, state}
  end

  @impl true
  def handle_info({:demo, :layer}, state) do
    layer_demo(state.spi)
    Process.send_after(self(), {:demo, :layer}, 10)
    {:noreply, state}
  end

  @impl true
  def handle_info({:demo, :breathe}, state) do
    breathe_demo(state.spi)
    Process.send_after(self(), {:demo, :breathe}, 10)
    {:noreply, state}
  end

  # from here, the nitty gritty of how to display the activations on the nOOdz
  @pwm_controller_count 3

  @pin_mapping %{
    ss: 62,
    dense_0: 48,
    # dense_1 is split into two parts, and the layer weights & final softmax outputs are interleaved
    dense_1_and_output_a: 0,
    dense_1_and_output_b: 24,
    # hidden layer neurons are also in two separate (non-contiguous) locations
    hidden_0a: 15,
    hidden_0b: 39
  }

  def set_layer(brightness_list, :input, seven_segment) do
    brightness_list
    |> replace_sublist(@pin_mapping.ss, seven_segment)
  end

  def set_layer(brightness_list, :dense_0, dense_0) do
    brightness_list
    |> replace_sublist(@pin_mapping.dense_0, dense_0)
  end

  def set_layer(brightness_list, :hidden, [hidden_0a, hidden_0b]) do
    brightness_list
    |> List.replace_at(@pin_mapping.hidden_0a, hidden_0a)
    |> List.replace_at(@pin_mapping.hidden_0b, hidden_0b)
  end

  def set_layer(brightness_list, :dense_1, dense_1) do
    # split list in half
    {dense_1_a, dense_1_b} = Enum.split(dense_1, 10)
    indices = [0, 1, 3, 4, 6, 7, 9, 10, 12, 13]

    replacements_1_a =
      Enum.zip(indices, dense_1_a)
      |> Enum.map(fn {idx, val} -> {idx + @pin_mapping.dense_1_and_output_a, val} end)
      |> Map.new()

    replacements_1 =
      Enum.zip(indices, dense_1_b)
      |> Enum.map(fn {idx, val} -> {idx + @pin_mapping.dense_1_and_output_b, val} end)
      |> Map.new()
      |> Map.merge(replacements_1_a)

    # replace the values corresponding to the specific dense_1 pins, leaving the rest as they are
    brightness_list
    |> Enum.with_index()
    |> Enum.map(fn {elem, idx} ->
      Map.get(replacements_1, idx, elem)
    end)
  end

  def set_layer(brightness_list, :output, output) do
    # split list in half
    {output_a, output_b} = Enum.split(output, 5)
    indices = [2, 5, 8, 11, 14]

    replacements_1_a =
      Enum.zip(indices, output_a)
      |> Enum.map(fn {idx, val} -> {idx + @pin_mapping.dense_1_and_output_a, val} end)
      |> Map.new()

    replacements_1 =
      Enum.zip(indices, output_b)
      |> Enum.map(fn {idx, val} -> {idx + @pin_mapping.dense_1_and_output_b, val} end)
      |> Map.new()
      |> Map.merge(replacements_1_a)

    # replace the values corresponding to the specific dense_1 pins, leaving the rest as they are
    brightness_list
    |> Enum.with_index()
    |> Enum.map(fn {elem, idx} ->
      Map.get(replacements_1, idx, elem)
    end)
  end

  def set_activations(spi_bus, %{
        input: seven_segment,
        dense_0: dense_0,
        hidden_0: hidden_0,
        dense_1: dense_1,
        output: output
      }) do
    data =
      List.duplicate(0, 24 * @pwm_controller_count)
      |> set_layer(:input, seven_segment)
      |> set_layer(:dense_0, dense_0)
      |> set_layer(:hidden, hidden_0)
      |> set_layer(:dense_1, dense_1)
      |> set_layer(:output, output)
      # it's a big'ol shift register, so we need to send the bits in reverse
      |> Enum.reverse()
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Demonstrates breathing effect on LED display by applying oscillating PWM values.
  Creates a pulsing wave pattern across all LEDs.

  Params:
    spi_bus: The SPI bus instance for communication with PWM controllers
  """
  def breathe_demo(spi_bus) do
    data =
      Range.new(1, 24 * @pwm_controller_count)
      |> Enum.map(fn x -> 0.5 + 0.5 * Utils.osc(0.1 * 0.5 * Integer.mod(x, 19)) end)
      # it's a big'ol shift register, so we need to send the bits in reverse
      |> Enum.reverse()
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Shows a sequential demonstration of each neural network layer by illuminating
  corresponding LEDs one layer at a time.

  Params:
    spi_bus: The SPI bus instance for communication with PWM controllers
  """
  def layer_demo(spi_bus) do
    layer = System.os_time(:second) |> Integer.mod(5)
    zeroes = List.duplicate(0, 24 * @pwm_controller_count)

    data =
      case layer do
        0 ->
          set_layer(zeroes, :input, List.duplicate(1, 7))

        1 ->
          set_layer(zeroes, :dense_0, List.duplicate(1, 14))

        2 ->
          set_layer(zeroes, :hidden, [1, 1])

        3 ->
          set_layer(zeroes, :dense_1, List.duplicate(1, 20))

        4 ->
          set_layer(zeroes, :output, List.duplicate(1, 10))
      end
      # it's a big'ol shift register, so we need to send the bits in reverse
      |> Enum.reverse()
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Demonstrates a step pattern by moving a single off LED around the display.

  Params:
    spi_bus: The SPI bus instance for communication with PWM controllers
  """
  def step_demo(spi_bus) do
    second = System.os_time(:second) |> Integer.mod(24 * @pwm_controller_count)

    data =
      List.duplicate(1, 24 * @pwm_controller_count)
      |> List.replace_at(second, 0)
      # it's a big'ol shift register, so we need to send the bits in reverse
      |> Enum.reverse()
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Sets a single PWM channel to a specified value.

  Params:
    spi_bus: The SPI bus instance for communication with PWM controllers
    index: Index of the PWM channel to set (0-71)
    value: Value to set the PWM channel to between 0 and 1
  """
  def set_one(spi_bus, index, value) do
    data =
      List.duplicate(0, 24 * @pwm_controller_count)
      |> List.replace_at(index, value)
      # it's a big'ol shift register, so we need to send the bits in reverse
      |> Enum.reverse()
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Sets all PWM channels to a specified value.

  Params:
    spi_bus: The SPI bus instance for communication with PWM controllers
    value: Value to set all PWM channels to between 0 and 1
  """
  def set_all(spi_bus, value) do
    data =
      value
      |> List.duplicate(24 * @pwm_controller_count)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
    :ok
  end

  def replace_sublist(list, start_index, new_sublist) do
    Enum.take(list, start_index) ++
      new_sublist ++
      Enum.drop(list, start_index + length(new_sublist))
  end

  def scale_activations(%{
        input: input,
        dense_0: dense_0,
        hidden_0: hidden_0,
        dense_1: dense_1,
        output: output
      }) do
    %{
      input: input,
      dense_0: Enum.map(dense_0, &abs/1),
      hidden_0: Enum.map(hidden_0, &abs/1),
      dense_1: Enum.map(dense_1, &abs/1),
      output: Enum.map(output, &(&1 * 3))
    }
  end

  ## client API

  def update(activations) do
    GenServer.cast(__MODULE__, {:update, activations})
  end

  def demo(type) do
    Process.send(__MODULE__, {:demo, type}, [])
  end
end
