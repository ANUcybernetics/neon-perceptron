defmodule Brainworms.Display.SevenSegment do
  @moduledoc """
  Functions for lighting up the seven-segment display.
  """

  # NOTE? this will return binaries, but don't be fooled by the printed representation
  # which uses bytes, not 12-bit words
  def to_pwm_binary(digit) do
    digit
    |> Brainworms.Utils.digit_to_bitlist!()
    # final 0 is the decimal point
    |> List.insert_at(-1, 0)
    |> Brainworms.Utils.pwm_encode()
  end
end
