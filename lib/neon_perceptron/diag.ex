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
end
