defmodule Brainworms.Utils do
  @moduledoc """
  Data representation for both the 0-9 digits and the associated 7-segment bit patterns.

  There's no number data structure per. se - this module just converts (in both directions)
  between 0-9 integers (digits) and 7-element lists of 0/1 (bitlists).
  """

  @bitlists [
    # 0
    [1, 1, 1, 1, 1, 1, 0],
    # 1
    [0, 0, 0, 0, 1, 1, 0],
    # 2
    [1, 1, 0, 1, 1, 0, 1],
    # 3
    [1, 1, 1, 1, 0, 0, 1],
    # 4
    [0, 1, 1, 0, 0, 1, 1],
    # 5
    [1, 0, 1, 1, 0, 1, 1],
    # 6
    [1, 0, 1, 1, 1, 1, 1],
    # 7
    [1, 1, 1, 0, 0, 0, 0],
    # 8
    [1, 1, 1, 1, 1, 1, 1],
    # 9
    [1, 1, 1, 1, 0, 1, 1]
  ]

  @doc """
  Return the bitlist for a given dikit (0-9)

  This function will raise if `digit` is not a single (0-9) digit.

      iex> Brainworms.Utils.digit_to_bitlist!!(1)
      [0, 0, 1, 0, 0, 1, 0]

      iex> Brainworms.Utils.digit_to_bitlist!!(5)
      [1, 1, 0, 1, 0, 1, 1]
  """
  def digit_to_bitlist!(digit) do
    if digit not in 0..9, do: raise("digit must be 0-9 (got #{digit})")
    Enum.at(@bitlists, digit)
  end

  @doc """
  Return the digit for a given bitlist (0-9)

  This function will raise if the bitlist doesn't correspond to a single (0-9) digit.

      iex> Brainworms.Utils.bitlist_to_digit!([1, 1, 1, 1, 1, 1, 1])
      8

      iex> Brainworms.Utils.bitlist_to_digit!([1, 1, 0, 1, 0, 1, 1])
      5
  """
  def bitlist_to_digit!(bitlist) do
    digit = Enum.find_index(@bitlists, fn bp -> bp == bitlist end)
    digit || raise "bitlist did not correspond to a digit 0-9"
  end

  def osc(frequency, phase \\ 0.0) do
    t = :os.system_time(:nanosecond) / 1.0e9

    :math.sin(2 * :math.pi() * (t * frequency + phase))
  end

  def gamma_correction(value) do
    gamma = 2.8
    :math.pow(value, gamma)
  end

  def clamp(value) do
    max(0.0, min(1.0, value))
  end

  @doc """
  Encode a list of integers as a binary string of 12-bit unsigned integers

  Input values should be floats in the range [0.0, 1.0] (if outside this
  they'll be clamped) they will be converted to 12-bit integers and packed
  into a binary string.

  This function also applies gamma correction to the values before encoding
  because of the nonlinearity of human perception of brightness.

  Useful for writing to PWM registers like on
  [this board](https://core-electronics.com.au/adafruit-24-channel-12-bit-pwm-led-driver-spi-interface-tlc5947.html).

  No overflow checking is done.
  """
  def pwm_encode(values) when is_list(values) do
    values
    |> Enum.map(&clamp/1)
    |> Enum.map(&gamma_correction/1)
    |> Enum.map(&((&1 * 4095.9999999999) |> trunc()))
    |> Enum.map(&<<&1::unsigned-integer-size(12)>>)
    |> Enum.reduce(<<>>, fn x, acc -> <<acc::bitstring, x::bitstring>> end)
  end
end
