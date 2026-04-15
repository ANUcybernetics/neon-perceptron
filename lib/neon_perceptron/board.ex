defmodule NeonPerceptron.Board do
  @moduledoc """
  TLC5947 board encoding and channel constants.

  Each node board has one TLC5947 providing 24 PWM channels (12-bit each). The
  channel-to-PCB-pad layout on the designed board is:

  - Channels 0--17: noodle pad positions (9 pairs)
  - Channels 18--20: "front" big-LED pad triple (blue, green, red)
  - Channels 21--23: "rear" big-LED pad triple (blue, green, red)

  `@front_*` / `@rear_*` are *chip-local* names for the two big-LED pad triples
  on the PCB. They are NOT the installation-wide orientation terms --- the
  `Builds.V2` moduledoc uses "back" (input-side) and "front" (output-side) for
  the installation, and those two senses do not match up automatically.

  Per-board population is non-uniform, and the channel-to-physical-LED wiring
  on a given board does not always match this PCB-pad table. Notably:

  - **Input boards** drive their outgoing-edge noodles (the noodles connecting
    to the first hidden column) plus one monochrome and one RGB big LED. At
    least one channel in 18--23 on an input board has been observed driving a
    noodle rather than a big-LED pad.
  - **Hidden boards** do not drive any noodles --- noodles physically
    terminate on hidden boards but only for voltage reference, not PWM. Their
    channels 0--17 have no observable function. The single RGB big LED on a
    hidden board is wired to channels TBD.
  - **Output boards** drive their incoming-edge noodles (from the second
    hidden column) plus front and rear RGB big LEDs.

  See TASK-17 and `Builds.V2` for the ongoing per-board channel
  characterisation.
  """

  @channels_per_board 24

  @front_blue 18
  @front_green 19
  @front_red 20
  @rear_blue 21
  @rear_green 22
  @rear_red 23

  @gamma 2.8

  def channels_per_board, do: @channels_per_board

  def front_blue, do: @front_blue
  def front_green, do: @front_green
  def front_red, do: @front_red
  def rear_blue, do: @rear_blue
  def rear_green, do: @rear_green
  def rear_red, do: @rear_red

  @doc """
  Return a blank board (24 channels, all zero).
  """
  @spec blank() :: [float()]
  def blank, do: List.duplicate(0.0, @channels_per_board)

  @doc """
  Encode a list of float brightness values (0.0--1.0) to TLC5947 SPI binary.

  Applies gamma correction (gamma=#{@gamma}) for perceptually linear brightness,
  then packs each value as a 12-bit unsigned integer.
  """
  @spec encode([float()]) :: binary()
  def encode(values) when is_list(values) do
    values
    |> Enum.map(&clamp/1)
    |> Enum.map(&gamma_correction/1)
    |> Enum.map(&((&1 * 4095.9999999999) |> trunc()))
    |> Enum.map(&<<&1::unsigned-integer-size(12)>>)
    |> Enum.reduce(<<>>, fn x, acc -> <<acc::bitstring, x::bitstring>> end)
  end

  defp gamma_correction(value) do
    :math.pow(value, @gamma)
  end

  defp clamp(value) do
    max(0.0, min(1.0, value))
  end
end
