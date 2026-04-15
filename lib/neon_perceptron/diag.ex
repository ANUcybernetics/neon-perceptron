defmodule NeonPerceptron.Diag do
  @moduledoc """
  Interactive bench-side diagnostics for the LED chains.

  All helpers assume the target chain is running. Frame helpers are
  deterministic: each call blanks the full chain before setting the
  requested channel(s), so there is no hidden state between calls.

  Typical bench workflow:

      Diag.pause_ticker()
      Diag.light(:input_left, 0, 18, 1.0)   # inspect one channel on one chip
      Diag.light_all(:main, 20, 1.0)        # same channel lit on every chip
      Diag.light_chip(:main, 5, 1.0)        # is chip 5 alive?
      Diag.dark(:input_left)
      Diag.resume_ticker()
  """

  alias NeonPerceptron.{Board, Chain}

  @channels_per_board 24

  @doc """
  Return the number of chips (boards) on a running chain.
  """
  @spec chip_count(atom()) :: non_neg_integer()
  def chip_count(chain_id) do
    Chain.via(chain_id)
    |> :sys.get_state()
    |> Map.fetch!(:boards)
    |> length()
  end

  @doc """
  Push an all-zero frame to the chain (blanks every channel on every chip).
  """
  @spec dark(atom()) :: :ok | {:error, :bad_length}
  def dark(chain_id) do
    Chain.push_raw(chain_id, blank_frame(chain_id))
  end

  @doc """
  Light one `channel` on one `chip_index` of `chain_id` to `value`
  (default 1.0). Every other channel on every other chip is zero.
  """
  @spec light(atom(), non_neg_integer(), non_neg_integer(), float()) ::
          :ok | {:error, :bad_length}
  def light(chain_id, chip_index, channel, value \\ 1.0)

  def light(chain_id, chip_index, channel, value)
      when is_integer(chip_index) and chip_index >= 0 and
             is_integer(channel) and channel >= 0 and channel < @channels_per_board do
    n = chip_count(chain_id)

    if chip_index >= n do
      raise ArgumentError,
            "chip_index #{chip_index} out of range (chain :#{chain_id} has #{n} chips)"
    end

    frame =
      blank_frame_for_count(n)
      |> List.replace_at(chip_index * @channels_per_board + channel, value)

    Chain.push_raw(chain_id, frame)
  end

  def light(_chain_id, _chip_index, channel, _value)
      when not (is_integer(channel) and channel >= 0 and channel < @channels_per_board) do
    raise ArgumentError, "channel must be in 0..23 (got #{inspect(channel)})"
  end

  @doc """
  Light `channel` on *every* chip in the chain to `value` (default 1.0).
  Every other channel is zero. Useful for checking channel consistency
  across boards.
  """
  @spec light_all(atom(), non_neg_integer(), float()) ::
          :ok | {:error, :bad_length}
  def light_all(chain_id, channel, value \\ 1.0)
      when is_integer(channel) and channel >= 0 and channel < @channels_per_board do
    n = chip_count(chain_id)

    frame =
      Enum.flat_map(0..(n - 1), fn _chip ->
        Board.blank() |> List.replace_at(channel, value)
      end)

    Chain.push_raw(chain_id, frame)
  end

  @doc """
  Light every channel on one `chip_index` to `value` (default 1.0). Every
  channel on every other chip is zero. Useful for "is this chip alive?"
  chain-propagation bisection.
  """
  @spec light_chip(atom(), non_neg_integer(), float()) ::
          :ok | {:error, :bad_length}
  def light_chip(chain_id, chip_index, value \\ 1.0)
      when is_integer(chip_index) and chip_index >= 0 do
    n = chip_count(chain_id)

    if chip_index >= n do
      raise ArgumentError,
            "chip_index #{chip_index} out of range (chain :#{chain_id} has #{n} chips)"
    end

    frame =
      Enum.flat_map(0..(n - 1), fn i ->
        if i == chip_index,
          do: List.duplicate(value, @channels_per_board),
          else: Board.blank()
      end)

    Chain.push_raw(chain_id, frame)
  end

  defp blank_frame(chain_id), do: blank_frame_for_count(chip_count(chain_id))

  defp blank_frame_for_count(n) do
    Enum.flat_map(0..(n - 1), fn _ -> Board.blank() end)
  end
end
