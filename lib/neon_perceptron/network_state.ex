defmodule NeonPerceptron.NetworkState do
  @moduledoc """
  The canonical data structure flowing from the trainer to display columns.

  Contains layer activations, weight matrices, network topology, and the
  current training iteration. Broadcast via PubSub so that Column processes
  (potentially on remote BEAM nodes) can render their boards.
  """

  defstruct activations: %{},
            weights: %{},
            topology: %{layers: [], sizes: %{}},
            iteration: 0,
            loss: 0.0

  @type t :: %__MODULE__{
          activations: %{String.t() => [float()]},
          weights: %{String.t() => [float()]},
          topology: topology(),
          iteration: non_neg_integer(),
          loss: float()
        }

  @type topology :: %{
          layers: [String.t()],
          sizes: %{String.t() => non_neg_integer()}
        }

  @doc """
  Build a zeroed-out NetworkState for a given topology.
  """
  @spec null(topology()) :: t()
  def null(topology) do
    activations =
      Map.new(topology.layers, fn layer ->
        {layer, List.duplicate(0.0, topology.sizes[layer])}
      end)

    weights =
      topology.layers
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Map.new(fn {[from, to], index} ->
        size = topology.sizes[from] * topology.sizes[to]
        {"dense_#{index}", List.duplicate(0.0, size)}
      end)

    %__MODULE__{
      activations: activations,
      weights: weights,
      topology: topology,
      iteration: 0
    }
  end

  @doc """
  Get the activation value for a single node.
  """
  @spec activation_for_node(t(), String.t(), non_neg_integer()) :: float()
  def activation_for_node(%__MODULE__{activations: activations}, layer, index) do
    activations |> Map.fetch!(layer) |> Enum.at(index)
  end

  @doc """
  Get the incoming weights for a node (from the previous layer).

  Returns a list of weights, one per node in the previous layer. These are the
  weights connecting each previous-layer node to this node.
  """
  @spec incoming_weights(t(), String.t(), non_neg_integer()) :: [float()]
  def incoming_weights(%__MODULE__{topology: topology} = state, layer, node_index) do
    layer_index = Enum.find_index(topology.layers, &(&1 == layer))

    if layer_index == 0 do
      []
    else
      weight_key = "dense_#{layer_index - 1}"
      prev_size = topology.sizes[Enum.at(topology.layers, layer_index - 1)]
      this_size = topology.sizes[layer]
      kernel = Map.fetch!(state.weights, weight_key)

      Enum.map(0..(prev_size - 1), fn prev_i ->
        Enum.at(kernel, prev_i * this_size + node_index)
      end)
    end
  end

  @doc """
  Get the outgoing weights from a node (to the next layer).

  Returns a list of weights, one per node in the next layer. These are the
  weights connecting this node to each next-layer node.
  """
  @spec outgoing_weights(t(), String.t(), non_neg_integer()) :: [float()]
  def outgoing_weights(%__MODULE__{topology: topology} = state, layer, node_index) do
    layer_index = Enum.find_index(topology.layers, &(&1 == layer))
    last_index = length(topology.layers) - 1

    if layer_index == last_index do
      []
    else
      weight_key = "dense_#{layer_index}"
      next_size = topology.sizes[Enum.at(topology.layers, layer_index + 1)]
      kernel = Map.fetch!(state.weights, weight_key)

      Enum.map(0..(next_size - 1), fn next_i ->
        Enum.at(kernel, node_index * next_size + next_i)
      end)
    end
  end

  @doc """
  Get the weighted activation contributions from the previous layer to a node.

  Returns a list of `{weight, activation, contribution}` tuples where
  contribution = weight * activation. Useful for visualising how much each
  incoming connection contributes to a node's pre-activation value.
  """
  @spec incoming_contributions(t(), String.t(), non_neg_integer()) ::
          [{float(), float(), float()}]
  def incoming_contributions(%__MODULE__{topology: topology} = state, layer, node_index) do
    layer_index = Enum.find_index(topology.layers, &(&1 == layer))

    if layer_index == 0 do
      []
    else
      prev_layer = Enum.at(topology.layers, layer_index - 1)
      weights = incoming_weights(state, layer, node_index)
      prev_activations = Map.fetch!(state.activations, prev_layer)

      Enum.zip(weights, prev_activations)
      |> Enum.map(fn {w, a} -> {w, a, w * a} end)
    end
  end
end
