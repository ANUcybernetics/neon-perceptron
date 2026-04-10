defmodule NeonPerceptron.Trainer do
  @moduledoc """
  Generic training GenServer parameterised by a build configuration.

  Continuously trains an Axon model and broadcasts a `NetworkState` via PubSub
  so that Column processes and the web UI can render the network's current state.

  ## Config

  The build config map must have these keys:

  - `:build` --- the build module (used for logging)
  - `:model_fn` --- zero-arity function returning an `Axon` model
  - `:training_data_fn` --- zero-arity function returning `{inputs, targets}` tensors
  - `:topology` --- `%{layers: [String.t()], sizes: %{String.t() => integer()}}`
  - `:loss_fn` --- (optional) loss function, defaults to binary cross-entropy
  - `:output_activation` --- (optional) `:sigmoid` or `:softmax`, defaults to `:sigmoid`
  """
  use GenServer

  require Logger

  alias NeonPerceptron.NetworkState

  @training_log_interval 5_000
  @broadcast_interval 33
  @auto_reset_check_interval 3_000
  @auto_reset_accuracy_threshold 0.9

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    model = config.model_fn.()
    training_data = config.training_data_fn.()
    topology = config.topology

    loss = config[:loss_fn] || &default_loss_fn/2
    {init_fn, step_fn} = Axon.Loop.train_step(model, loss, :adam)
    {_, predict_fn} = Axon.build(model)
    step_state = init_fn.(training_data, Axon.ModelState.empty())

    state = %{
      model: model,
      topology: topology,
      training_data: training_data,
      init_fn: init_fn,
      step_fn: step_fn,
      predict_fn: predict_fn,
      step_state: step_state,
      network_state: NetworkState.null(topology),
      web_input: nil,
      build: config[:build],
      output_activation: config[:output_activation] || :sigmoid
    }

    {:ok, state, {:continue, :start_training}}
  end

  @impl true
  def handle_continue(:start_training, state) do
    schedule_training_step()
    {:noreply, state}
  end

  @impl true
  def handle_info(:train_step, state) do
    step_state = state.step_fn.(state.training_data, state.step_state)
    eval_step_state(step_state)
    iteration = Nx.to_number(step_state.i)

    if rem(iteration, @training_log_interval) == 0 do
      print_training_summary(step_state, state.topology)
    end

    state = %{state | step_state: step_state}

    state =
      if rem(iteration, @broadcast_interval) == 0 do
        network_state = compute_network_state(state, iteration)
        broadcast(network_state)
        %{state | network_state: network_state}
      else
        state
      end

    state =
      if iteration > 0 and rem(iteration, @auto_reset_check_interval) == 0 do
        maybe_auto_reset(state)
      else
        state
      end

    schedule_training_step()
    {:noreply, state}
  end

  @impl true
  def handle_call(:network_state, _from, state) do
    {:reply, state.network_state, state}
  end

  @impl true
  def handle_call(:iteration, _from, state) do
    {:reply, Nx.to_number(state.step_state.i), state}
  end

  @impl true
  def handle_call(:topology, _from, state) do
    {:reply, state.topology, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, reinitialise(state)}
  end

  @impl true
  def handle_call({:predict, input}, _from, state) do
    result = predict_helper(input, state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:set_web_input, input}, state) do
    {:noreply, %{state | web_input: input}}
  end

  def network_state, do: GenServer.call(__MODULE__, :network_state)
  def iteration, do: GenServer.call(__MODULE__, :iteration)
  def topology, do: GenServer.call(__MODULE__, :topology)
  def reset, do: GenServer.call(__MODULE__, :reset)
  def predict(input), do: GenServer.call(__MODULE__, {:predict, input})
  def set_web_input(input), do: GenServer.cast(__MODULE__, {:set_web_input, input})

  defp reinitialise(state) do
    step_state = state.init_fn.(state.training_data, Axon.ModelState.empty())
    %{state | step_state: step_state}
  end

  defp maybe_auto_reset(state) do
    accuracy = compute_accuracy(state)

    if accuracy < @auto_reset_accuracy_threshold do
      iteration = Nx.to_number(state.step_state.i)

      Logger.info(
        "[Trainer] auto-reset at iteration #{iteration} (accuracy #{Float.round(accuracy, 3)} < #{@auto_reset_accuracy_threshold})"
      )

      reinitialise(state)
    else
      state
    end
  end

  defp compute_network_state(state, iteration) do
    %{data: data} = state.step_state.model_state
    topology = state.topology

    input = current_input(state)
    weights = extract_weights(data, topology)
    activations = compute_activations(input, weights, topology, state.output_activation)

    accuracy = compute_accuracy(state)

    %NetworkState{
      activations: activations,
      weights: weights,
      topology: topology,
      iteration: iteration,
      loss: Nx.to_number(state.step_state.loss),
      accuracy: accuracy
    }
  end

  defp current_input(state) do
    case state.web_input do
      nil ->
        input_size = state.topology.sizes[hd(state.topology.layers)]
        List.duplicate(0.0, input_size)

      input ->
        input
    end
  end

  defp extract_weights(data, topology) do
    topology.layers
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Map.new(fn {[_from, _to], index} ->
      key = "dense_#{index}"
      {"dense_#{index}", data[key]["kernel"] |> Nx.to_flat_list()}
    end)
  end

  defp compute_activations(input, weights, topology, output_activation) do
    layers = topology.layers

    {activations, _} =
      Enum.reduce(tl(layers), {%{hd(layers) => input}, input}, fn layer, {acc, prev_values} ->
        layer_index = Enum.find_index(layers, &(&1 == layer))
        weight_key = "dense_#{layer_index - 1}"
        kernel = weights[weight_key]

        prev_size = length(prev_values)
        this_size = topology.sizes[layer]

        pre_activation =
          Enum.map(0..(this_size - 1), fn j ->
            Enum.reduce(0..(prev_size - 1), 0.0, fn i, sum ->
              sum + Enum.at(prev_values, i) * Enum.at(kernel, i * this_size + j)
            end)
          end)

        activated =
          if layer == List.last(layers) do
            apply_output_activation(pre_activation, output_activation)
          else
            Enum.map(pre_activation, &:math.tanh/1)
          end

        {Map.put(acc, layer, activated), activated}
      end)

    activations
  end

  defp apply_output_activation(values, :sigmoid) do
    Enum.map(values, &sigmoid/1)
  end

  defp apply_output_activation(values, :softmax) do
    softmax(values)
  end

  defp sigmoid(x), do: 1.0 / (1.0 + :math.exp(-x))

  defp softmax(values) do
    max = Enum.max(values)
    exps = Enum.map(values, &:math.exp(&1 - max))
    sum = Enum.sum(exps)
    Enum.map(exps, &(&1 / sum))
  end

  defp compute_accuracy(state) do
    {inputs, targets} = state.training_data
    predictions = state.predict_fn.(state.step_state.model_state, inputs)
    pred_classes = Nx.argmax(predictions, axis: 1)
    true_classes = Nx.argmax(targets, axis: 1)
    Nx.equal(pred_classes, true_classes) |> Nx.mean() |> Nx.to_number()
  end

  defp default_loss_fn(y_pred, y_true) do
    Axon.Losses.binary_cross_entropy(y_pred, y_true, reduction: :mean)
  end

  defp predict_helper(input, state) do
    batched = input |> Nx.tensor(type: :f32) |> Nx.new_axis(0)
    state.predict_fn.(state.step_state.model_state, batched)
  end

  defp broadcast(network_state) do
    if pubsub_available?() do
      Phoenix.PubSub.broadcast(
        NeonPerceptron.PubSub,
        "network_state",
        {:network_state, network_state}
      )
    end
  end

  defp pubsub_available? do
    !!Process.whereis(NeonPerceptron.PubSub)
  end

  defp schedule_training_step do
    Process.send_after(self(), :train_step, 1)
  end

  defp print_training_summary(step_state, topology) do
    loss = Nx.to_number(step_state.loss)
    iteration = Nx.to_number(step_state.i)

    Logger.info(
      "[Trainer] iteration=#{iteration} loss=#{Float.round(loss, 6)} " <>
        "topology=#{inspect(Map.values(topology.sizes))}"
    )
  end

  defp eval_step_state(step_state) do
    if Code.ensure_loaded?(EMLX.Backend) and function_exported?(EMLX.NIF, :eval, 1) do
      do_eval_step_state(step_state)
    end
  end

  defp do_eval_step_state(step_state) do
    %{model_state: %{data: data}, optimizer_state: {_, opt}} = step_state

    for {_, layer} <- data, {_, tensor} <- layer, do: emlx_eval(tensor)
    emlx_eval(opt.count)
    for {_, layer} <- opt.mu, {_, tensor} <- layer, do: emlx_eval(tensor)
    for {_, layer} <- opt.nu, {_, tensor} <- layer, do: emlx_eval(tensor)

    :ok
  end

  defp emlx_eval(%Nx.Tensor{data: %{ref: {_device, ref}}}) when is_reference(ref) do
    EMLX.NIF.eval(ref)
  rescue
    _ -> :ok
  end

  defp emlx_eval(_), do: :ok
end
