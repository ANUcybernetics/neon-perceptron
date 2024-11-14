defmodule Brainworms.Display.Wires do
  @moduledoc """
  Functions for lighting up the nOOdz wires using PWM.
  """

  alias Brainworms.Utils

  @pwm_controller_count Application.compile_env!(:brainworms, :pwm_controller_count)

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
end
