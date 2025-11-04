defmodule NeonPerceptron.Model do
  use GenServer
  alias NeonPerceptron.Utils
  alias NeonPerceptron.Knob
  alias NeonPerceptron.Display

  @moduledoc """
  Helper module for defining, training and running inference with fully-connected
  networks for the "map a seven-segment digit to the number displayed" problem.

  This module is a leaky abstraction - the returned models are [Axon](https://hexdocs.pm/axon/)
  data structures. If you just follow this notebook you (probably) don't need to understand
  how they work.
  """

  # how often to print summary stats to the log (disable for prod)
  @training_log_interval 5_000
  # in steps (need to tweak once we're on the board)
  @display_update_interval 1

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # @type state :: %{
  #         activations: %{
  #           input: list(float()),
  #           dense_0: list(float()),
  #           hidden_0: list(float()),
  #           dense_1: list(float()),
  #           output: list(float())
  #         }
  #       }

  @impl true
  def init(_opts) do
    # initialise model & training state
    model = new(2)
    training_data = training_set()
    {init_fn, step_fn} = Axon.Loop.train_step(model, :categorical_cross_entropy, :adam)
    {_, predict_fn} = Axon.build(model)
    step_state = init_fn.(training_data, Axon.ModelState.empty())

    {:ok,
     %{
       model: model,
       training_data: training_data,
       init_fn: init_fn,
       step_fn: step_fn,
       predict_fn: predict_fn,
       step_state: step_state,
       activations: null_activations()
     }, {:continue, :start_training}}
  end

  @impl true
  def handle_continue(:start_training, state) do
    schedule_training_step()
    {:noreply, state}
  end

  @impl true
  def handle_call({:predict, input}, _from, state) do
    prediction = predict_helper(input, state)
    {:reply, prediction, state}
  end

  @impl true
  def handle_call(:iteration, _from, state) do
    {:reply, state.step_state.i, state}
  end

  @impl true
  def handle_call(:activations, _from, state) do
    {:reply, state.activations, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    step_state = state.init_fn.(state.training_data, Axon.ModelState.empty())
    {:reply, :ok, %{state | step_state: step_state}}
  end

  @impl true
  def handle_cast({:calc_layer_activations, :input, input}, state) do
    kernel = get_kernel(state.step_state.model_state, "dense_0")

    # this is a bit "fake", because we ignore the bias
    # TODO perhaps Axon can set the model to learn bias-less dense kernels?
    dense_0_activations =
      input
      |> Nx.transpose()
      |> Nx.broadcast(Nx.shape(kernel))
      |> Nx.multiply(kernel)
      # |> Nx.flatten()
      |> Nx.to_flat_list()

    activations =
      Map.merge(state.activations, %{input: Nx.to_flat_list(input), dense_0: dense_0_activations})

    {:noreply, %{state | activations: activations}}
  end

  @impl true
  def handle_cast({:calc_layer_activations, :hidden_0, hidden_0}, state) do
    kernel = get_kernel(state.step_state.model_state, "dense_1")

    # this is a bit "fake", because we ignore the bias
    # TODO perhaps Axon can set the model to learn bias-less dense kernels?
    dense_1_activations =
      hidden_0
      |> Nx.transpose()
      |> Nx.broadcast(Nx.shape(kernel))
      |> Nx.multiply(kernel)
      # |> Nx.flatten()
      |> Nx.transpose()
      |> Nx.to_flat_list()

    activations =
      Map.merge(state.activations, %{
        hidden_0: Nx.to_flat_list(hidden_0),
        dense_1: dense_1_activations
      })

    {:noreply, %{state | activations: activations}}
  end

  @impl true
  def handle_cast({:calc_layer_activations, :output, output}, state) do
    activations = Map.merge(state.activations, %{output: Nx.to_flat_list(output)})
    {:noreply, %{state | activations: activations}}
  end

  @impl true
  def handle_cast({:predict, input}, state) do
    # run for the side effect of triggering the calculation of the activations
    predict_helper(input, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:train_step, state) do
    step_state = state.step_fn.(state.training_data, state.step_state)
    iteration = Nx.to_number(step_state.i)

    if rem(iteration, @training_log_interval) == 0 do
      print_param_summary(step_state, state.activations)
    end

    if rem(iteration, @display_update_interval) == 0 do
      # need to trigger a prediction to update the activations
      seven_segment = Knob.position() |> Utils.integer_to_bitlist()

      GenServer.cast(__MODULE__, {:predict, seven_segment})

      Display.update(state.activations)
    end

    schedule_training_step()
    {:noreply, %{state | step_state: step_state}}
  end

  @doc """
  Create a fully-connected multi-layer perceptron model

  The model will have a 7-dimensional input (each one corresponding to a segment in the
  display) and a 10-dimensional output (for the softmax predictions; one for each digit 0-9).

  `hidden_layer_sizes` is the size of the hidden layer.
  """
  def new(hidden_layer_size) do
    Axon.input("bitlist", shape: {nil, 7})
    |> calc_layer_activations_hook(:input)
    |> Axon.dense(hidden_layer_size)
    |> Axon.tanh()
    |> calc_layer_activations_hook(:hidden_0)
    |> Axon.dense(10)
    |> Axon.layer_norm()
    |> Axon.activation(:softmax)
    |> calc_layer_activations_hook(:output)
  end

  defp get_kernel(model_state, layer_name) do
    %{data: %{^layer_name => %{"kernel" => kernel}}} = model_state
    kernel
  end

  defp calc_layer_activations_hook(model, layer) do
    Axon.attach_hook(
      model,
      fn value ->
        # has to be a cast, because a Call will block (resulting in deadlock)
        GenServer.cast(__MODULE__, {:calc_layer_activations, layer, value})
      end,
      on: :forward,
      mode: :inference
    )
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

      iex> train_data = NeonPerceptron.Train.inputs()
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

  def print_param_summary(step_state, activations) do
    %{input: input, dense_0: dense_0, hidden_0: hidden_0, dense_1: dense_1, output: softmax_0} =
      activations

    IO.puts("\nIteration: #{Nx.to_number(step_state.i)}")

    loss =
      Axon.Losses.categorical_cross_entropy(step_state.y_true, step_state.y_pred)
      |> Nx.to_list()

    loss
    |> Enum.with_index()
    |> Enum.map(fn {l, i} -> "#{i}/#{Float.round(l, 2)}" end)
    |> Enum.join("  ")
    |> then(&"Loss: #{loss |> Enum.sum() |> Float.round(2)} (#{&1})")
    |> IO.puts()

    Axon.Metrics.accuracy(step_state.y_true, step_state.y_pred)
    |> Nx.to_number()
    |> Kernel.*(100.0)
    |> Float.round(2)
    |> then(&"Accuracy: #{&1}%")
    |> IO.puts()

    IO.puts("  Input: min=#{Enum.min(input)}, max=#{Enum.max(input)}")

    IO.puts(
      "  Dense 0: min=#{Float.round(Enum.min(dense_0), 2)}, max=#{Float.round(Enum.max(dense_0), 2)}"
    )

    IO.puts(
      "  Hidden 0: min=#{Float.round(Enum.min(hidden_0), 2)}, max=#{Float.round(Enum.max(hidden_0), 2)}"
    )

    IO.puts(
      "  Dense 1: min=#{Float.round(Enum.min(dense_1), 2)}, max=#{Float.round(Enum.max(dense_1), 2)}"
    )

    IO.puts(
      "  Softmax 0: min=#{Float.round(Enum.min(softmax_0), 2)}, max=#{Float.round(Enum.max(softmax_0), 2)}"
    )

    activation_list = activations |> Map.delete(:input) |> Map.values() |> List.flatten()

    IO.puts(
      "  Overall (excl. input): min=#{Float.round(Enum.min(activation_list), 2)}, max=#{Float.round(Enum.max(activation_list), 2)}"
    )
  end

  def activations() do
    GenServer.call(__MODULE__, :activations)
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
    Process.send_after(self(), :train_step, 1)
  end

  def null_activations() do
    %{
      input: List.duplicate(0.0, 7),
      dense_0: List.duplicate(0.0, 14),
      hidden_0: List.duplicate(0.0, 2),
      dense_1: List.duplicate(0.0, 20),
      output: List.duplicate(0.0, 10)
    }
  end

  defp predict_helper(input, state) do
    batched_input = input |> Nx.tensor() |> Nx.new_axis(0)

    state.predict_fn.(state.step_state.model_state, batched_input)
    |> Nx.to_flat_list()
  end

  @doc """
  Run single-shot inference for a trained model.

  Intended use:
  - `model` comes from `new/1`
  - `params` comes from `train/2`

  For a given `digit` 0-9, return the predicted class distribution under `model`.
  """
  def predict(model, params, digit) do
    input = Utils.digit_to_bitlist(digit) |> Nx.tensor() |> Nx.new_axis(0)
    {_init_fn, predict_fn} = Axon.build(model)
    predict_fn.(params, input)
  end

  @doc """
  Run single-shot inference for a trained model and return the most likely digit class.

  Intended use:
  - `model` comes from `new/1`
  - `params` comes from `train/2`

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
  Calculate layer activations manually from model state.

  This is a somewhat hacky way to extract intermediate layer activations. There's probably a
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

    tanh_0 = activations_dense_0 |> Nx.sum(axes: [0]) |> Nx.tanh()

    activations_dense_1 =
      tanh_0 |> Nx.new_axis(1) |> Nx.multiply(kernel_1)

    softmax_0 = activations_dense_1 |> Nx.sum(axes: [0]) |> Axon.Activations.softmax()

    [
      input_vector,
      activations_dense_0,
      tanh_0,
      activations_dense_1,
      softmax_0
    ]
    |> Enum.map(fn tensor -> Nx.to_flat_list(tensor) end)
  end
end
