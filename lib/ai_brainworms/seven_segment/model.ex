defmodule AIBrainworms.SevenSegment.Model do
  @moduledoc """
  Helper module for defining fully-connected networks of different sizes.

  This module is a leaky abstraction - the returned models are [Axon](https://hexdocs.pm/axon/)
  data structures. If you just follow this notebook you (probably) don't need to understand
  how they work.
  """

  @doc """
  Create a fully-conneted model

  The model will have a 7-dimensional input (for the bitlists) and a 10-dimensional
  output (for the softmax predictions; one for each digit 0-9).

  `hidden_layer_sizes` should be a list of sizes for the hidden layers.

  Example: create a networks with a single hidden layer of 2 neurons:

      iex> SevenSegment.Model.new([2])
      #Axon<
        inputs: %{"bitlist" => {nil, 7}}
        outputs: "softmax_0"
        nodes: 5
      >

  """
  def new(hidden_layer_sizes) do
    input = Axon.input("bitlist", shape: {nil, 7})

    hidden_layer_sizes
    |> Enum.reduce(input, fn layer_size, model ->
      Axon.dense(model, layer_size, activation: :relu)
    end)
    |> Axon.dense(10, activation: :softmax)
  end
end
