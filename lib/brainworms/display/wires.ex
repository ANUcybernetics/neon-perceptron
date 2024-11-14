defmodule Brainworms.Display.Wires do
  @moduledoc """
  Functions for lighting up the nOOdz wires using PWM.
  """

  alias Brainworms.Utils

  def light_up(_mode, _ref, _model_state) do
    # TODO
    true
  end

  def light_all(spi_bus, value) do
    data =
      0..23
      |> Enum.map(fn _ -> Utils.gamma_correction(value) end)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
    :ok
  end
end
