defmodule Brainworms.Number do
  @moduledoc """
  Data representation for both the 0-9 digits and the associated 7-segment bit patterns.

  There's no number data structure per. se - this module just converts (in both directions)
  between 0-9 integers (digits) and 7-element lists of 0/1 (bitlists).
  """

  @bitlists [
    [1, 1, 1, 0, 1, 1, 1],
    [0, 0, 1, 0, 0, 1, 0],
    [1, 0, 1, 1, 1, 0, 1],
    [1, 0, 1, 1, 0, 1, 1],
    [0, 1, 1, 1, 0, 1, 0],
    [1, 1, 0, 1, 0, 1, 1],
    [1, 1, 0, 1, 1, 1, 1],
    [1, 0, 1, 0, 0, 1, 0],
    [1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 0, 1, 1]
  ]

  @doc """
  Return the bitlist for a given dikit (0-9)

  This function will raise if `digit` is not a single (0-9) digit.

      iex> Brainworms.Number.encode_digit!(1)
      [0, 0, 1, 0, 0, 1, 0]

      iex> Brainworms.Number.encode_digit!(5)
      [1, 1, 0, 1, 0, 1, 1]
  """
  def encode_digit!(digit) do
    unless digit in 0..9, do: "digit must be 0-9"
    Enum.at(@bitlists, digit)
  end

  @doc """
  Return the digit for a given bitlist (0-9)

  This function will raise if the bitlist doesn't correspond to a single (0-9) digit.

      iex> Brainworms.Number.decode_digit!([1, 1, 1, 1, 1, 1, 1])
      8

      iex> Brainworms.Number.decode_digit!([1, 1, 0, 1, 0, 1, 1])
      5
  """
  def decode_digit!(bitlist) do
    digit = Enum.find_index(@bitlists, fn bp -> bp == bitlist end)
    digit || raise "bitlist did not correspond to a digit 0-9"
  end
end
