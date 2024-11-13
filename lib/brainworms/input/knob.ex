defmodule Brainworms.Input.Knob do
  @moduledoc """
  This module concerns the rotary encoder knob used to sweep through
  the different possible patterns on the seven-segment display
  """

  @gpio_label "PIN18"

  def init() do
    {:ok, gpio} = Circuits.GPIO.open(@gpio_label, :input)
    gpio
  end

  def update(input, position_delta) do
    Integer.mod(input + position_delta, 0x7F)
  end
end
