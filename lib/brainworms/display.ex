defmodule Brainworms.Display do
  @moduledoc """
  Handles display output through PWM controllers.
  """

  alias Brainworms.Utils
  alias Brainworms.Input.Knob

  @pwm_controller_count 3

  @pin_mapping %{
    ss: {62, 7},
    dense_0: {48, 14},
    dense_1_0: {0, 15},
    dense_1_1: {24, 15}
  }

  def breathe_demo(spi_bus) do
    # for now, just "breathe" the wires... until we can process the model properly
    #
    # TODO generate a whole batch of breathing-osc data, and then replace_sublist the digit over the top

    _digit = Knob.get_position() |> Integer.mod(10)

    data =
      Range.new(1, 24 * @pwm_controller_count)
      |> Enum.map(fn x -> 0.5 + 0.5 * Utils.osc(0.1 * (1 + Integer.mod(x, 8))) end)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Handles display output through PWM controllers, providing various demo and
  control functions for LED displays using SPI communication.
  """
  def step_demo(spi_bus) do
    second = System.os_time(:second) |> Integer.mod(24 * @pwm_controller_count)

    data =
      List.duplicate(1, 24 * @pwm_controller_count)
      |> List.replace_at(second, 0)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  def set_all(spi_bus, value) do
    data =
      value
      |> List.duplicate(24 * @pwm_controller_count)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
    :ok
  end

  def breathe(spi_bus) do
    data =
      Range.new(1, 24 * @pwm_controller_count)
      |> Enum.map(fn x -> 0.5 + 0.5 * Utils.osc(0.1 * (1 + Integer.mod(x, 8))) end)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  defp replace_sublist(list, {start_index, length}, new_sublist) do
    Enum.take(list, start_index) ++
      new_sublist ++
      Enum.drop(list, start_index + length)
  end
end
