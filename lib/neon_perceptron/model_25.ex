defmodule NeonPerceptron.Model25 do
  use GenServer

  @moduledoc """
  A 25-input neural network model for the digital twin visualisation.

  Architecture: 25 inputs (5×5 pixel grid) → hidden layer (configurable) → 10 outputs

  This model is designed for:
  - Interactive input from the web UI (drawing on a 5×5 grid)
  - Real-time visualisation of activations and weights
  - Training on downsampled MNIST data (future)
  """

  @training_log_interval 5_000
  @display_update_interval 1
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
       step_state: step_state,
       activations: null_activations(hidden_size),
       web_input: List.duplicate(0.0, 25)
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
  def handle_cast({:calc_layer_activations, :input, input}, state) do
    kernel = get_kernel(state.step_state.model_state, "dense_0")

    dense_0_activations =
      input
      |> Nx.transpose()
      |> Nx.broadcast(Nx.shape(kernel))
      |> Nx.multiply(kernel)
      |> Nx.to_flat_list()

    activations =
      Map.merge(state.activations, %{input: Nx.to_flat_list(input), dense_0: dense_0_activations})

    {:noreply, %{state | activations: activations}}
  end

  @impl true
  def handle_cast({:calc_layer_activations, :hidden_0, hidden_0}, state) do
    kernel = get_kernel(state.step_state.model_state, "dense_1")

    dense_1_activations =
      hidden_0
      |> Nx.transpose()
      |> Nx.broadcast(Nx.shape(kernel))
      |> Nx.multiply(kernel)
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
    predict_helper(input, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_web_input, input}, state) do
    {:noreply, %{state | web_input: input}}
  end

  @impl true
  def handle_info(:train_step, state) do
    step_state = state.step_fn.(state.training_data, state.step_state)
    iteration = Nx.to_number(step_state.i)

    if rem(iteration, @training_log_interval) == 0 do
      print_param_summary(step_state, state.activations)
    end

    if rem(iteration, @display_update_interval) == 0 do
      GenServer.cast(__MODULE__, {:predict, state.web_input})
    end

    if rem(iteration, @web_broadcast_interval) == 0 do
      broadcast_to_web(state)
    end

    schedule_training_step()
    {:noreply, %{state | step_state: step_state}}
  end

  @doc """
  Create a fully-connected MLP for 5×5 pixel input classification.
  """
  def new(hidden_layer_size) do
    Axon.input("pixels", shape: {nil, 25})
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
        GenServer.cast(__MODULE__, {:calc_layer_activations, layer, value})
      end,
      on: :forward,
      mode: :inference
    )
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

  def activations, do: GenServer.call(__MODULE__, :activations)
  def topology, do: GenServer.call(__MODULE__, :topology)
  def predict(input), do: GenServer.call(__MODULE__, {:predict, input})
  def iteration, do: GenServer.call(__MODULE__, :iteration)
  def reset, do: GenServer.call(__MODULE__, :reset)

  def set_web_input(input) when is_list(input) do
    GenServer.cast(__MODULE__, {:set_web_input, input})
  end

  defp broadcast_to_web(state) do
    if pubsub_available?() do
      weights = extract_weights(state.step_state.model_state)

      data = %{
        activations: state.activations,
        weights: weights,
        topology: %{
          input_size: 25,
          hidden_size: state.hidden_size,
          output_size: 10
        }
      }

      Phoenix.PubSub.broadcast(NeonPerceptron.PubSub, "activations", {:activations, data})
    end
  end

  defp pubsub_available? do
    case Process.whereis(NeonPerceptron.PubSub) do
      nil -> false
      _pid -> true
    end
  end

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

  def null_activations(hidden_size) do
    %{
      input: List.duplicate(0.0, 25),
      dense_0: List.duplicate(0.0, 25 * hidden_size),
      hidden_0: List.duplicate(0.0, hidden_size),
      dense_1: List.duplicate(0.0, hidden_size * 10),
      output: List.duplicate(0.0, 10)
    }
  end

  defp predict_helper(input, state) do
    batched_input = input |> Nx.tensor() |> Nx.new_axis(0)

    state.predict_fn.(state.step_state.model_state, batched_input)
    |> Nx.to_flat_list()
  end
end
