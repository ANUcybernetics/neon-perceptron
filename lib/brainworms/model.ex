defmodule Brainworms.Model do
  @moduledoc """
  Helper module for defining, training and running inference with fully-connected
  networks for the "map a seven-segment digit to the number displayed" problem.

  This module is a leaky abstraction - the returned models are [Axon](https://hexdocs.pm/axon/)
  data structures. If you just follow this notebook you (probably) don't need to understand
  how they work.
  """
  alias Brainworms.Utils

  @doc """
  Create a fully-connected model

  The model will have a 7-dimensional input (for the bitlists) and a 10-dimensional
  output (for the softmax predictions; one for each digit 0-9).

  `hidden_layer_sizes` should be a list of sizes for the hidden layers.

  Example: create a networks with a single hidden layer of 2 neurons:

      iex> Brainworms.Model.new([2])
      #Axon<
        inputs: %{"bitlist" => {nil, 7}}
        outputs: "softmax_0"
        nodes: 5
      >

  """
  def new(hidden_layer_sizes) when is_list(hidden_layer_sizes) do
    input = Axon.input("bitlist", shape: {nil, 7})

    hidden_layer_sizes
    |> Enum.reduce(input, fn layer_size, model ->
      Axon.dense(model, layer_size, activation: :relu)
    end)
    |> Axon.dense(10, activation: :softmax)
  end

  # helper function for when there's just one hidden layer
  def new(hidden_layer_size), do: new([hidden_layer_size])

  @doc """
  Create a training set of bitlists for use as a training set.

  Compared to most AI problems this is _extremely_ trivial; there are only
  10 digits, and each one has one unambiguous bitlist representation, so
  z there are only 10 pairs in the training set. Toy problems ftw :)

  The output won't be a list of lists, it'll be an [Nx](https://hexdocs.pm/nx/) tensor,
  because that's what's expected by the trainingkcode.

  Note that the returned tensor won't include the digits explicitly, but the digits can be used to index
  into the `:digit` axis to get the correct bitlist, e.g.

      iex> train_data = Brainworms.Train.inputs()
      iex> train_data[[digit: 0]]
      #Nx.Tensor<
        u8[bitlist: 7]
        [1, 1, 1, 0, 1, 1, 1]
      >
  """
  def training_set() do
    inputs =
      0..9
      |> Enum.map(&Utils.digit_to_bitlist!/1)
      |> Nx.tensor(names: [:digit, :bitlist], type: :u8)

    # a tensor of the (one-hot-encoded) digits 0-9 (one per row).
    targets =
      0..9
      |> Enum.to_list()
      |> Nx.tensor(type: :u8, names: [:digit])
      |> Nx.new_axis(-1, :one_hot)
      |> Nx.equal(Nx.tensor(Enum.to_list(0..9)))

    {inputs, targets}
  end

  @doc """
  Run the training procedure, returning a map of (trained) params
  """
  def train(model, inputs, targets, opts \\ []) do
    # since this training set is so small, use batches of size 1
    train_data = Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))

    opts = Keyword.merge(opts, epochs: 1000)
    # opts = Keyword.merge(opts, epochs: 1000, compiler: EXLA)

    model
    |> Axon.Loop.trainer(:categorical_cross_entropy, :adam)
    |> Axon.Loop.metric(:accuracy, "Accuracy")
    |> Axon.Loop.run(train_data, %{}, opts)
  end

  @doc """
  Run single-shot inference for a trained model.

  Intended use:
  - `model` comes from `new/1`
  - `params` comes from `train/4`

  For a given `digit` 0-9, return the predicted class distribution under `model`.
  """
  def predict(model, params, digit) do
    input = Utils.digit_to_bitlist!(digit) |> Nx.tensor() |> Nx.new_axis(0)
    Axon.predict(model, params, input)
  end
end
