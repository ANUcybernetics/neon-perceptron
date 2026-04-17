defmodule NeonPerceptron.Board do
  @moduledoc """
  TLC5947 board encoding and channel constants.

  Each node board has one TLC5947 providing 24 PWM channels (12-bit each). The
  channel-to-PCB-pad layout on the designed board is:

  - Channels 0--17: 18 individual noodle pads (one channel per pad, not
    pre-paired --- a "noodle pair" is any two pads wired to the two ends
    of one blue/red noodle wire-pair)
  - Channels 18--20: "front" big-LED pad triple (B=18, G=19, R=20)
  - Channels 21--23: "rear" big-LED pad triple (B=21, G=22, R=23)

  `@front_*` / `@rear_*` are *chip-local* names for the two big-LED pad
  triples on opposite physical faces of the PCB --- they describe silicon,
  not installation orientation. Build-level code (e.g. `Builds.V2`) is
  responsible for mapping these triples to installation-wide directions
  (upstream/downstream) and to per-role LED population (RGB vs mono vs
  unpopulated).

  Per-build population is non-uniform. For V2 specifically:

  - **Input boards** populate noodle pads `(0,1)` and `(9,10)` (2 pairs),
    plus an RGB LED on one triple and a mono LED on the other.
  - **Hidden boards** drive no noodle pads (noodles physically terminate
    here only for voltage reference, not PWM). One RGB big LED on the
    outward face of the board's column.
  - **Output boards** populate noodle pads `(5,6)` and `(14,15)` (2 pairs),
    plus RGB LEDs on both triples.

  See `docs/build_v2_hardware.md` for the full per-role channel map.
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
