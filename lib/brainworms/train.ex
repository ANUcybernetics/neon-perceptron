defmodule Brainworms.Train do
  @moduledoc """
  Create datasets and train models.
  """

  alias Brainworms.Number

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
  def inputs() do
    0..9
    |> Enum.map(&Number.encode_digit!/1)
    |> Nx.tensor(names: [:digit, :bitlist], type: :u8)
  end

  @doc """
  Return a tensor of the (one-hot-encoded) digits 0-9 (one per row).
  """
  def targets() do
    0..9
    |> Enum.to_list()
    |> Nx.tensor(type: :u8, names: [:digit])
    |> Nx.new_axis(-1, :one_hot)
    |> Nx.equal(Nx.tensor(Enum.to_list(0..9)))
  end

  @doc "convenience function for building an {inputs, targets} tuple of tensors for use in training"
  def training_set() do
    {inputs(), targets()}
  end

  @doc """
  Run the training procedure, returning a map of (trained) params
  """
  def run(model, inputs, targets, opts \\ []) do
    # since this training set is so small, use batches of size 1
    data = Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))

    opts = Keyword.merge(opts, epochs: 1000)
    # opts = Keyword.merge(opts, epochs: 1000, compiler: EXLA)

    model
    |> Axon.Loop.trainer(:categorical_cross_entropy, :adam)
    |> Axon.Loop.metric(:accuracy, "Accuracy")
    |> Axon.Loop.run(data, %{}, opts)
  end
end
