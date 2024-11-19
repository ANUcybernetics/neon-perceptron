defmodule Brainworms.Model do
  use GenServer
  alias Brainworms.Utils

  @moduledoc """
  Helper module for defining, training and running inference with fully-connected
  networks for the "map a seven-segment digit to the number displayed" problem.

  This module is a leaky abstraction - the returned models are [Axon](https://hexdocs.pm/axon/)
  data structures. If you just follow this notebook you (probably) don't need to understand
  how they work.
  """

  @training_sleep_interval 0

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # initialise model & training state
    model = new(2)
    training_data = training_set()
    {init_fn, step_fn} = Axon.Loop.train_step(model, :categorical_cross_entropy, :adam)
    step_state = init_fn.(training_data, Axon.ModelState.empty())

    schedule_training_step()

    {:ok,
     %{
       model: model,
       training_data: training_data,
       init_fn: init_fn,
       step_fn: step_fn,
       step_state: step_state
     }}
  end

  @impl true
  def handle_call({:activations, input}, _from, state) do
    activations = activations_from_model_state(state.step_state.model_state, input)
    {:reply, activations, state}
  end

  @impl true
  def handle_call({:predict, input}, _from, state) do
    batched_input = input |> Nx.tensor() |> Nx.new_axis(0)

    prediction =
      Axon.predict(state.model, state.step_state.model_state, batched_input) |> Nx.to_flat_list()

    {:reply, prediction, state}
  end

  @impl true
  def handle_call(:iteration, _from, state) do
    {:reply, state.step_state.i, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    step_state = state.init_fn.(state.training_data, Axon.ModelState.empty())
    {:reply, :ok, %{state | step_state: step_state}}
  end

  @impl true
  def handle_info(:train_step, state) do
    step_state = state.step_fn.(state.training_data, state.step_state)
    schedule_training_step()
    {:noreply, %{state | step_state: step_state}}
  end

  @doc """
  Create a fully-connected multi-layer perceptron model

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
        f32[bitlist: 7]
        [1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0]
      >
  """
  def training_set() do
    inputs =
      0..9
      |> Enum.map(&Utils.digit_to_bitlist/1)
      |> Nx.tensor(names: [:digit, :bitlist], type: :f32)

    # a tensor of the (one-hot-encoded) digits 0-9 (one per row).
    targets =
      0..9
      |> Enum.to_list()
      |> Nx.tensor(type: :f32, names: [:digit])
      |> Nx.new_axis(-1, :one_hot)
      |> Nx.equal(Nx.tensor(Enum.to_list(0..9)))

    {inputs, targets}
  end

  @doc """
  Train a model on the given data.

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

  @doc """
  Takes the current model state and a bitlist input and returns a list of the intermediate
  computations and final activations during inference. The list includes
  element-wise multiplications and summed results for each layer, in order.

  This is hard-coded to the structure of the model created by `new/1`---a fully-connected
  network with one hidden layer (ReLU activation) and a softmax output layer. There might be a
  nicer and more general way to get this info out of Axon (e.g. `Axon.build/2` with `print_values: true`
  will print some of the right values) but I haven't found it yet.

  Used to map neural network calculations to wire brightness values for visualization.
  """
  def activations_from_model_state(model_state, input) do
    weights = Map.get(model_state, :data)

    %{
      "dense_0" => %{"bias" => _bias_0, "kernel" => kernel_0},
      "dense_1" => %{"bias" => _bias_1, "kernel" => kernel_1}
    } = weights

    input_vector = Nx.tensor(input, type: :f32)

    activations_dense_0 =
      input_vector |> Nx.new_axis(1) |> Nx.multiply(kernel_0)

    relu_0 = activations_dense_0 |> Nx.sum(axes: [0]) |> Axon.Activations.relu()

    activations_dense_1 =
      relu_0 |> Nx.new_axis(1) |> Nx.multiply(kernel_1)

    softmax_0 = activations_dense_1 |> Nx.sum(axes: [0]) |> Axon.Activations.softmax()

    [
      input_vector,
      activations_dense_0,
      relu_0,
      activations_dense_1,
      softmax_0
    ]
    |> Enum.map(fn tensor -> Nx.to_flat_list(tensor) end)
  end

  def activations(input) do
    GenServer.call(__MODULE__, {:activations, input})
  end

  def predict(input) do
    GenServer.call(__MODULE__, {:predict, input})
  end

  def iteration() do
    GenServer.call(__MODULE__, :iteration)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  defp schedule_training_step() do
    Process.send_after(self(), :train_step, @training_sleep_interval)
  end
end
