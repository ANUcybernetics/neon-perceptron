defmodule Brainworms.Display.Wires do
  @moduledoc """
  Functions for lighting up the nOOdz wires using PWM.
  """

  alias Brainworms.Utils

  @pwm_controller_count 2

  def set(_mode, _ref, _model_state) do
    # TODO
    true
  end

  def set_all(spi_bus, value) do
    corrected_value = Utils.gamma_correction(max(0.0, min(1.0, value)))

    data =
      List.duplicate(corrected_value, 24 * @pwm_controller_count)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
    :ok
  end
end
