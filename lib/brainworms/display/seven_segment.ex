defmodule Brainworms.Display.SevenSegment do
  @moduledoc """
  Functions for lighting up the seven-segment display.
  """

  def light_up(_mode, _ref, %{input: current_value}) do
    _bitlist = Brainworms.Utils.digit_to_bitlist!(current_value)

    # TODO update the display, based on the current value

    :ok
  end
end
