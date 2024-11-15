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

  The model will have a 7-dimensional input (each one corresponding to a segment in the
  display) and a 10-dimensional output (for the softmax predictions; one for each digit 0-9).

  `hidden_layer_sizes` is the size of the hidden layer.

  Example: create a networks with a single hidden layer of 2 neurons:

      iex> Brainworms.Model.new(2)
      #Axon<
        inputs: %{"bitlist" => {nil, 7}}
        outputs: "softmax_0"
        nodes: 5
      >

  """
  def new(hidden_layer_size) do
    Axon.input("bitlist", shape: {nil, 7})
    |> Axon.dense(hidden_layer_size)
    |> Axon.relu()
    |> Axon.dense(10)
    |> Axon.activation(:softmax)
  end

  @doc """
  Create a training set of bitlists for use as a training set.

  Compared to most AI problems this is _extremely_ trivial; there are only
  10 digits, and each one has one unambiguous bitlist representation, so
  z there are only 10 pairs in the training set. Toy problems ftw :)

  The output won't be a list of lists, it'll be an [Nx](https://hexdocs.pm/nx/) tensor,
  because that's what's expected by the training code.

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
      |> Enum.map(&Utils.digit_to_bitlist/1)
      |> Nx.tensor(names: [:digit, :bitlist], type: :u8)

    # a tensor of the (one-hot-encoded) digits 0-9 (one per row).
    targets =
      0..9
      |> Enum.to_list()
      |> Nx.tensor(type: :u8, names: [:digit])
      |> Nx.new_axis(-1, :one_hot)
      |> Nx.equal(Nx.tensor(Enum.to_list(0..9)))

    Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))
  end

  @doc """
  Creates a loop for training the model.

  Returns an Axon loop configured with categorical cross-entropy loss,
  the Adam optimizer, and accuracy metrics.
  """
  def train(model, data, opts \\ []) do
    model
    |> Axon.Loop.trainer(:categorical_cross_entropy, :adam)
    |> Axon.Loop.metric(:accuracy, "Accuracy")
    |> Axon.Loop.run(data, Axon.ModelState.empty(), opts)
  end

  @doc """
  Run single-shot inference for a trained model.

  Intended use:
  - `model` comes from `new/1`
  - `params` comes from `train/4`

  For a given `digit` 0-9, return the predicted class distribution under `model`.
  """
  def predict(model, params, digit) do
    input = Utils.digit_to_bitlist(digit) |> Nx.tensor() |> Nx.new_axis(0)
    Axon.predict(model, params, input)
  end

  @doc """
  Run single-shot inference for a trained model and return the most likely digit class.

  Intended use:
  - `model` comes from `new/1`
  - `params` comes from `train/4`

  For a given `digit` 0-9, return the predicted digit class (0-9) under `model`.
  """
  def predict_class(model, params, digit) do
    model
    |> predict(params, digit)
    |> Nx.argmax(axis: 1)
    |> Nx.to_flat_list()
    |> List.first()
  end
end
