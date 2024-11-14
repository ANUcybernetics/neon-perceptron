defmodule Brainworms.Display.SevenSegment do
  @moduledoc """
  Functions for lighting up the seven-segment display.
  """

  # NOTE? this will return lists of floats in [0.0, 1.0], ready for pwm_encoding and then sending
  def to_brightness_list(digit) do
    digit
    |> Brainworms.Utils.digit_to_bitlist!()
    # final 0 is the decimal point
    |> List.insert_at(-1, 0)
  end
end
