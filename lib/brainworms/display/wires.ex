defmodule Brainworms.Display.Wires do
  @moduledoc """
  Functions for lighting up the nOOdz wires using PWM.
  """

  # @controller_count 1
  @bus_name "spidev0.0"

  def init() do
    {:ok, ref} = Circuits.SPI.open(@bus_name)
    ref
  end

  def light_up(_mode, _ref, _model_state) do
    # TODO
    true
  end
end
