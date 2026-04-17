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
  Blank every channel on every chip across *every running chain*. Chain
  membership is discovered from `NeonPerceptron.ChainRegistry`, so this
  follows whatever build is live (V1, V2, TestPattern, etc.).

  Returns a list of `{chain_id, result}` pairs for visibility.
  """
  @spec dark_all() :: [{atom(), :ok | {:error, :bad_length}}]
  def dark_all do
    for chain_id <- chain_ids() do
      {chain_id, dark(chain_id)}
    end
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

  def light(_chain_id, chip_index, _channel, _value)
      when not (is_integer(chip_index) and chip_index >= 0) do
    raise ArgumentError,
          "chip_index must be a non-negative integer (got #{inspect(chip_index)})"
  end

  @doc """
  Light *every* channel on *every* chip across *every running chain* to
  `value` (default 1.0). Useful as a "is the entire installation alive?"
  smoke check, and as the on-counterpart to `dark_all/0`.

  Returns a list of `{chain_id, result}` pairs for visibility.

  Disambiguation by arity:

  - `light_all/0`, `light_all/1` — flood every chain with `value`.
  - `light_all/2`, `light_all/3` — light one `channel` on every chip of
    one `chain_id`.
  """
  @spec light_all(float()) :: [{atom(), :ok | {:error, :bad_length}}]
  def light_all(value \\ 1.0) when is_number(value) do
    for chain_id <- chain_ids() do
      n = chip_count(chain_id)
      frame = List.duplicate(value * 1.0, n * @channels_per_board)
      {chain_id, Chain.push_raw(chain_id, frame)}
    end
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
      Enum.flat_map(0..(n - 1)//1, fn _chip ->
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
      Enum.flat_map(0..(n - 1)//1, fn i ->
        if i == chip_index,
          do: List.duplicate(value, @channels_per_board),
          else: Board.blank()
      end)

    Chain.push_raw(chain_id, frame)
  end

  @doc """
  Light every noodle pair's "blue" or "red" channel on every chip in
  `chain_id` to `value` (default 1.0). Reads each chip's noodle spec
  from the live Chain state (which mirrors the build's
  `chain_configs/0`), so whatever `blue_ch`/`red_ch` is currently
  configured is what gets driven.

  Bench use: run `Diag.noodles_all(:main, :blue)` and visually check
  that every noodle that lights up is actually the blue wire. For any
  pair where the red wire lights instead, swap `blue_ch` and `red_ch`
  in that noodle spec and reload.

  Chips with no `:noodles` key (e.g. hidden chips, or builds that
  don't use the V2 board-spec shape) are skipped silently.
  """
  @spec noodles_all(atom(), :blue | :red, float()) :: :ok | {:error, :bad_length}
  def noodles_all(chain_id, colour, value \\ 1.0)
      when colour in [:blue, :red] and is_number(value) do
    boards =
      Chain.via(chain_id)
      |> :sys.get_state()
      |> Map.fetch!(:boards)

    frame =
      Enum.flat_map(boards, fn board ->
        case board do
          %{noodles: noodles} when is_list(noodles) ->
            Enum.reduce(noodles, Board.blank(), fn noodle, acc ->
              ch = Map.fetch!(noodle, channel_key(colour))
              List.replace_at(acc, ch, value * 1.0)
            end)

          _ ->
            Board.blank()
        end
      end)

    Chain.push_raw(chain_id, frame)
  end

  defp channel_key(:blue), do: :blue_ch
  defp channel_key(:red), do: :red_ch

  @doc """
  Bench sanity check: clock `multiplier * n * 24` values of `value`
  (default 1.0, multiplier default 3) into `chain_id`. Extra bits fall
  off the chain's final SOUT — harmless.

  If chips beyond position X still stay dark at `multiplier=3`, the
  fault is a physical chain break (SOUT→SIN, XLAT, or power) and not a
  software under-clocking issue.
  """
  @spec flood_oversize(atom(), pos_integer(), float()) :: :ok
  def flood_oversize(chain_id, multiplier \\ 3, value \\ 1.0)
      when is_integer(multiplier) and multiplier >= 1 and is_number(value) do
    n = chip_count(chain_id)
    frame = List.duplicate(value * 1.0, multiplier * n * @channels_per_board)
    Chain.push_oversize(chain_id, frame)
  end

  defp blank_frame(chain_id), do: blank_frame_for_count(chip_count(chain_id))

  defp blank_frame_for_count(n) do
    Enum.flat_map(0..(n - 1)//1, fn _ -> Board.blank() end)
  end

  defp chain_ids do
    Registry.select(NeonPerceptron.ChainRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Terminate any supervised child whose id ends in `.Ticker` (e.g.
  `NeonPerceptron.Builds.TestPattern.Ticker`) so bench diagnostics aren't
  overwritten 30 times per second.

  Returns `:ok` if a ticker was terminated, `:not_running` otherwise.
  """
  @spec pause_ticker() :: :ok | :not_running
  def pause_ticker do
    case find_ticker() do
      nil ->
        :not_running

      {sup, id} ->
        case Supervisor.terminate_child(sup, id) do
          :ok -> :ok
          {:error, :not_found} -> :not_running
        end
    end
  end

  @doc """
  Restart the ticker child previously paused by `pause_ticker/0`.

  Returns `:ok` on success, `:not_running` if no ticker child is known.
  """
  @spec resume_ticker() :: :ok | :not_running
  def resume_ticker do
    case find_ticker() do
      nil ->
        :not_running

      {sup, id} ->
        case Supervisor.restart_child(sup, id) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, :already_present} -> :ok
          {:error, _other} -> :not_running
        end
    end
  end

  defp find_ticker do
    case Process.whereis(NeonPerceptron.Supervisor) do
      nil ->
        nil

      sup ->
        sup
        |> Supervisor.which_children()
        |> Enum.find_value(fn {id, _, _, _} ->
          if is_atom(id) and String.ends_with?(Atom.to_string(id), ".Ticker") do
            {sup, id}
          end
        end)
    end
  end
end
