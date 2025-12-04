defmodule NeonPerceptron.Model25 do
  use GenServer

  @moduledoc """
  A 25-input neural network model for the digital twin visualisation.

  Architecture: 25 inputs (5×5 pixel grid) → hidden layer (configurable) → 10 outputs

  The server trains continuously and broadcasts weight updates to the web UI.
  The JS client owns the input state and calculates activations locally using
  the received weights, creating an exact replica of the model's forward pass.
  """

  @training_log_interval 5_000
  @web_broadcast_interval 33

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    hidden_size = Keyword.get(opts, :hidden_size, 8)

    model = new(hidden_size)
    training_data = training_set()
    {init_fn, step_fn} = Axon.Loop.train_step(model, :categorical_cross_entropy, :adam)
    {_, predict_fn} = Axon.build(model)
    step_state = init_fn.(training_data, Axon.ModelState.empty())

    {:ok,
     %{
       model: model,
       hidden_size: hidden_size,
       training_data: training_data,
       init_fn: init_fn,
       step_fn: step_fn,
       predict_fn: predict_fn,
       step_state: step_state
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
  def handle_call(:topology, _from, state) do
    topology = %{
      input_size: 25,
      hidden_size: state.hidden_size,
      output_size: 10
    }

    {:reply, topology, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    step_state = state.init_fn.(state.training_data, Axon.ModelState.empty())
    {:reply, :ok, %{state | step_state: step_state}}
  end

  @impl true
  def handle_info(:train_step, state) do
    step_state = state.step_fn.(state.training_data, state.step_state)
    iteration = Nx.to_number(step_state.i)

    if rem(iteration, @training_log_interval) == 0 do
      print_training_summary(step_state)
    end

    if rem(iteration, @web_broadcast_interval) == 0 do
      broadcast_weights(state.hidden_size, step_state.model_state)
    end

    schedule_training_step()
    {:noreply, %{state | step_state: step_state}}
  end

  @doc """
  Create a fully-connected MLP for 5×5 pixel input classification.

  Architecture: input[25] → dense → tanh → dense → softmax → output[10]

  Design choices for the digital twin visualisation:
  - No biases: simplifies the model to just weight matrices, making the
    relationship between inputs and outputs clearer to visualise
  - tanh activation: bounded [-1, 1] output maps nicely to visual intensity,
    and bipolar values allow clear positive/negative edge distinction
  - No layer norm: unnecessary for this small network, and removes extra
    parameters that would need to be sent to the JS client
  - The forward pass can be replicated exactly in JS with just two matrix
    multiplies: hidden = tanh(input @ dense_0), output = softmax(hidden @ dense_1)
  """
  def new(hidden_layer_size) do
    Axon.input("pixels", shape: {nil, 25})
    |> Axon.dense(hidden_layer_size, use_bias: false)
    |> Axon.tanh()
    |> Axon.dense(10, use_bias: false)
    |> Axon.softmax()
  end

  @doc """
  Create a simple training set with synthetic 5×5 digit patterns.
  """
  def training_set do
    inputs =
      0..9
      |> Enum.map(&digit_to_5x5_pattern/1)
      |> Nx.tensor(names: [:digit, :pixel], type: :f32)

    targets =
      0..9
      |> Enum.to_list()
      |> Nx.tensor(type: :f32, names: [:digit])
      |> Nx.new_axis(-1, :one_hot)
      |> Nx.equal(Nx.tensor(Enum.to_list(0..9)))

    {inputs, targets}
  end

  def digit_to_5x5_pattern(digit) do
    patterns = %{
      0 => [1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1],
      1 => [0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0],
      2 => [1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1],
      3 => [1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0],
      4 => [1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0],
      5 => [1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0],
      6 => [0, 1, 1, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0],
      7 => [1, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0],
      8 => [0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0],
      9 => [0, 1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0]
    }

    Map.get(patterns, digit)
  end

  defp print_training_summary(step_state) do
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
  end

  def topology, do: GenServer.call(__MODULE__, :topology)
  def predict(input), do: GenServer.call(__MODULE__, {:predict, input})
  def iteration, do: GenServer.call(__MODULE__, :iteration)
  def reset, do: GenServer.call(__MODULE__, :reset)

  # Broadcast weights to the web UI via PubSub.
  # The JS client uses these to calculate activations locally.
  defp broadcast_weights(hidden_size, model_state) do
    if pubsub_available?() do
      weights = extract_weights(model_state)

      data = %{
        weights: weights,
        topology: %{
          input_size: 25,
          hidden_size: hidden_size,
          output_size: 10
        }
      }

      Phoenix.PubSub.broadcast(NeonPerceptron.PubSub, "weights", {:weights, data})
    end
  end

  defp pubsub_available? do
    case Process.whereis(NeonPerceptron.PubSub) do
      nil -> false
      _pid -> true
    end
  end

  # Extract weight matrices for the JS digital twin.
  # Since use_bias: false, we only have kernels (no bias vectors).
  # dense_0: [25, hidden_size] flattened row-major
  # dense_1: [hidden_size, 10] flattened row-major
  defp extract_weights(model_state) do
    %{data: data} = model_state

    %{
      dense_0: data["dense_0"]["kernel"] |> Nx.to_flat_list(),
      dense_1: data["dense_1"]["kernel"] |> Nx.to_flat_list()
    }
  end

  defp schedule_training_step do
    Process.send_after(self(), :train_step, 1)
  end

  defp predict_helper(input, state) do
    batched_input = input |> Nx.tensor() |> Nx.new_axis(0)

    state.predict_fn.(state.step_state.model_state, batched_input)
    |> Nx.to_flat_list()
  end
end
