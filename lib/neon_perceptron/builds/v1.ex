defmodule NeonPerceptron.Builds.V1 do
  @moduledoc """
  V1 build: 7-segment digit classifier.

  A 7→2→10 network that classifies 7-segment display patterns into digits 0--9.
  Three daisy-chained TLC5947s on a single SPI bus, with layer activations
  scattered across the 72 PWM channels.

  This build uses `render_frame_fn` mode because the pin mapping does not follow
  a one-board-per-node layout. Instead, the 72 channels are divided into regions
  for each layer with interleaved dense_1/output channels.
  """

  alias NeonPerceptron.{NetworkState, Utils}

  @topology %{
    layers: ["input", "hidden_0", "output"],
    sizes: %{"input" => 7, "hidden_0" => 2, "output" => 10}
  }

  @pwm_controller_count 3

  @pin_mapping %{
    ss: 62,
    dense_0: 48,
    dense_1_and_output_a: 0,
    dense_1_and_output_b: 24,
    hidden_0a: 15,
    hidden_0b: 39
  }

  def topology, do: @topology

  def trainer_config do
    %{
      build: __MODULE__,
      model_fn: &model/0,
      training_data_fn: &training_data/0,
      topology: @topology,
      loss_fn: &Axon.Losses.categorical_cross_entropy(&1, &2, reduction: :mean),
      output_activation: :softmax
    }
  end

  def chain_configs do
    [
      %{
        id: :v1_display,
        spi_device: "spidev0.0",
        boards: [],
        render_fn: nil,
        render_frame_fn: &render_frame/1
      }
    ]
  end

  def model do
    Axon.input("bitlist", shape: {nil, 7})
    |> Axon.dense(2, use_bias: false)
    |> Axon.tanh()
    |> Axon.dense(10, use_bias: false)
    |> Axon.softmax()
  end

  def training_data do
    inputs =
      0..9
      |> Enum.map(&Utils.digit_to_bitlist/1)
      |> Nx.tensor(names: [:digit, :bitlist], type: :f32)

    targets =
      0..9
      |> Enum.to_list()
      |> Nx.tensor(type: :f32, names: [:digit])
      |> Nx.new_axis(-1, :one_hot)
      |> Nx.equal(Nx.tensor(Enum.to_list(0..9)))

    {inputs, targets}
  end

  @doc """
  Render all 72 PWM channels from a NetworkState.

  This implements the original V1 pin mapping where layer activations are
  scattered across 3 daisy-chained TLC5947s. The layout is:

  - Channels 62--68: 7-segment input (7 channels)
  - Channels 48--61: dense_0 layer (14 channels = 7 inputs × 2 hidden)
  - Channel 15, 39: hidden_0 neurons (2 channels)
  - Channels 0--14, 24--38: dense_1 + output interleaved (30 channels)
  """
  def render_frame(%NetworkState{} = state) do
    input = Map.fetch!(state.activations, "input")
    hidden_0 = Map.fetch!(state.activations, "hidden_0")
    output = Map.fetch!(state.activations, "output")

    dense_0 = compute_dense_activations(state, "dense_0", "input", "hidden_0")
    dense_1 = compute_dense_activations(state, "dense_1", "hidden_0", "output")

    scaled_output = Enum.map(output, &(&1 * 3))

    List.duplicate(0, 24 * @pwm_controller_count)
    |> set_layer(:input, input)
    |> set_layer(:dense_0, dense_0)
    |> set_layer(:hidden, hidden_0)
    |> set_layer(:dense_1, dense_1)
    |> set_layer(:output, scaled_output)
    |> pulse_negatives()
  end

  defp compute_dense_activations(state, weight_key, from_layer, to_layer) do
    prev = Map.fetch!(state.activations, from_layer)
    kernel = Map.fetch!(state.weights, weight_key)
    to_size = state.topology.sizes[to_layer]
    from_size = length(prev)

    Enum.flat_map(0..(from_size - 1), fn i ->
      Enum.map(0..(to_size - 1), fn j ->
        Enum.at(prev, i) * Enum.at(kernel, i * to_size + j)
      end)
    end)
  end

  defp set_layer(brightness_list, :input, seven_segment) do
    replace_sublist(brightness_list, @pin_mapping.ss, seven_segment)
  end

  defp set_layer(brightness_list, :dense_0, dense_0) do
    replace_sublist(brightness_list, @pin_mapping.dense_0, dense_0)
  end

  defp set_layer(brightness_list, :hidden, [hidden_0a, hidden_0b]) do
    brightness_list
    |> List.replace_at(@pin_mapping.hidden_0a, hidden_0a)
    |> List.replace_at(@pin_mapping.hidden_0b, hidden_0b)
  end

  defp set_layer(brightness_list, :dense_1, dense_1) do
    {dense_1_a, dense_1_b} = Enum.split(dense_1, 10)
    indices = [0, 1, 3, 4, 6, 7, 9, 10, 12, 13]

    replacements =
      build_replacements(indices, dense_1_a, @pin_mapping.dense_1_and_output_a)
      |> Map.merge(build_replacements(indices, dense_1_b, @pin_mapping.dense_1_and_output_b))

    apply_replacements(brightness_list, replacements)
  end

  defp set_layer(brightness_list, :output, output) do
    {output_a, output_b} = Enum.split(output, 5)
    indices = [2, 5, 8, 11, 14]

    replacements =
      build_replacements(indices, output_a, @pin_mapping.dense_1_and_output_a)
      |> Map.merge(build_replacements(indices, output_b, @pin_mapping.dense_1_and_output_b))

    apply_replacements(brightness_list, replacements)
  end

  defp build_replacements(indices, values, offset) do
    Enum.zip(indices, values)
    |> Map.new(fn {idx, val} -> {idx + offset, val} end)
  end

  defp apply_replacements(list, replacements) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {elem, idx} -> Map.get(replacements, idx, elem) end)
  end

  defp replace_sublist(list, start_index, new_sublist) do
    Enum.take(list, start_index) ++
      new_sublist ++
      Enum.drop(list, start_index + length(new_sublist))
  end

  defp pulse_negatives(brightness_list) do
    amp = 0.05
    freq = 10.0
    t = Utils.float_now()

    Enum.map(brightness_list, fn val ->
      if val < 0 do
        -val + amp * Utils.osc(freq, 0.0, t)
      else
        val
      end
    end)
  end
end
