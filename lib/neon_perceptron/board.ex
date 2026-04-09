defmodule NeonPerceptron.Board do
  @moduledoc """
  TLC5947 board encoding and channel constants.

  Each node board has one TLC5947 providing 24 PWM channels (12-bit each):

  - Channels 0--17: individual LEDs
  - Channels 18--20: "big LED" front (blue, green, red)
  - Channels 21--23: "big LED" rear (blue, green, red)
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
