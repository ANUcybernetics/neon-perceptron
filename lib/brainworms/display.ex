defmodule Brainworms.Display do
  @moduledoc """
  Handles display output through PWM controllers.
  """

  alias Brainworms.Utils

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

  def set(brightness_list, :input, seven_segment) do
    brightness_list
    |> replace_sublist(@pin_mapping.ss, seven_segment)
  end

  def set(brightness_list, :dense_0, dense_0) do
    brightness_list
    |> replace_sublist(@pin_mapping.dense_0, dense_0)
  end

  def set(brightness_list, :hidden, [hidden_0a, hidden_0b]) do
    brightness_list
    |> List.replace_at(@pin_mapping.hidden_0a, hidden_0a)
    |> List.replace_at(@pin_mapping.hidden_0b, hidden_0b)
  end

  def set(brightness_list, :dense_1, dense_1) do
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

  def set(brightness_list, :output, output) do
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

  def set(spi_bus, activations) do
    [seven_segment, dense_0, hidden_0, dense_1, output] = scale_activations(activations)

    data =
      List.duplicate(0, 24 * @pwm_controller_count)
      |> set(:input, seven_segment)
      |> set(:dense_0, dense_0)
      |> set(:hidden, hidden_0)
      |> set(:dense_1, dense_1)
      |> set(:output, output)
      # it's a big'ol shift register, so we need to send the bits in reverse
      |> Enum.reverse()
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Demonstrates breathing effect on LED display by applying oscillating PWM values.
  Takes current knob position as input to determine seven segment display pattern,
  then applies a breathing pattern across all other controllers.

  Params:
    spi_bus: The SPI bus instance for communication with PWM controllers
  """
  def breathe_demo(spi_bus, seven_segment) do
    data =
      Range.new(1, 24 * @pwm_controller_count)
      |> Enum.map(fn x -> 0.5 + 0.5 * Utils.osc(0.1 * 0.5 * Integer.mod(x, 19)) end)
      |> replace_sublist(@pin_mapping.ss, seven_segment)
      # it's a big'ol shift register, so we need to send the bits in reverse
      |> Enum.reverse()
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Show a demo by flashing through the layers of the network.

  Params:
    spi_bus: The SPI bus instance for communication with PWM controllers
  """
  def layer_demo(spi_bus) do
    layer = System.os_time(:second) |> Integer.mod(5)
    zeroes = List.duplicate(0, 24 * @pwm_controller_count)

    data =
      case layer do
        0 ->
          set(zeroes, :input, List.duplicate(1, 7))

        1 ->
          set(zeroes, :dense_0, List.duplicate(1, 14))

        2 ->
          set(zeroes, :hidden, [1, 1])

        3 ->
          set(zeroes, :dense_1, List.duplicate(1, 20))

        4 ->
          set(zeroes, :output, List.duplicate(1, 10))
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

  def scale_activations(activations) do
    [input, dense_0, hidden_0, dense_1, output] = activations

    [
      input,
      Enum.map(dense_0, &(&1 * 0.5 + 0.5)),
      Enum.map(hidden_0, &(&1 * 0.5 + 0.5)),
      Enum.map(dense_1, &(&1 * 0.5 + 0.5)),
      Enum.map(output, &(&1 * 3))
    ]
  end
end
