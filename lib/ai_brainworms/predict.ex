defmodule AIBrainworms.Predict do
  @moduledoc """
  Run single-shot inference for a trained model.

  Intended use:
  - `model` comes from `AIBrainworms.Model.new/1`
  - `params` comes from `AIBrainworms.Train.run/4`
  """

  alias AIBrainworms.Number

  @doc """
  For a given `digit` 0-9, return the predicted class distribution under `model`.
  """
  def from_digit(model, params, digit) do
    input = Number.encode_digit!(digit) |> Nx.tensor() |> Nx.new_axis(0)
    Axon.predict(model, params, input)
  end
end
