defmodule Brainworms.Display.SevenSegment do
  @moduledoc """
  Functions for lighting up the seven-segment display.
  """

  alias Brainworms.MCP23017

  def light_up(bus, digit) do
    # final 0 is the decimal point
    bitlist = Brainworms.Utils.digit_to_bitlist!(digit) ++ [0]
    data = :erlang.list_to_binary(bitlist)
    MCP23017.write_port_a(bus, data)
  end
end
