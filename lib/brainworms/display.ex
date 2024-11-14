defmodule Brainworms.Display do
  @moduledoc """
  Handles display output through PWM controllers.
  """

  alias Brainworms.Display.SevenSegment
  alias Brainworms.Utils

  def set(spi_bus, digit, _model) do
    # for now, just "breathe" the wires... until we can process the model properly
    c1_data = <<0::size(192)>> <> SevenSegment.to_pwm_binary(digit)

    c2_data =
      Range.new(1, 24)
      |> Enum.map(fn _ -> 0.5 + 0.5 * Utils.osc(0.2) end)
      |> Utils.pwm_encode()

    c3_data =
      Range.new(1, 24)
      |> Enum.map(fn _ -> :rand.uniform() end)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, c3_data <> c2_data <> c1_data)
  end
end
