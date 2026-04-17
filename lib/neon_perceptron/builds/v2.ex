defmodule NeonPerceptron.Builds.V2 do
  @moduledoc """
  V2 build: 2x2 pattern classifier.

  A 4->2->3 network that classifies 2x2 binary input patterns into three
  categories: diagonal, row, or column. Demonstrates that a hidden layer with
  nonlinear activation can solve linearly inseparable classification problems
  --- the core insight from Minsky & Papert's 1969 *Perceptrons* critique.

  ## Network

  - **4 inputs**: 2x2 grid read row-major [top-left, top-right, bottom-left,
    bottom-right], values 0.0--1.0 (continuous, driven by touch)
  - **2 hidden** (tanh, no bias)
  - **3 outputs** (softmax): probabilities summing to 1
    - output[0] = diagonal (⟍ or ⟋)
    - output[1] = row (top or bottom)
    - output[2] = column (left or right)
  - **Loss**: categorical cross-entropy

  ## Hardware reference

  The authoritative description of the physical installation --- chain
  layout, per-role TLC5947 channel map, noodle routing, and polarity
  table --- lives in `docs/build_v2_hardware.md`. This module's
  `chain_configs/0` is the machine-readable mirror of that document.
  """

  alias NeonPerceptron.{Board, NetworkState}

  @topology %{
    layers: ["input", "hidden_0", "output"],
    sizes: %{"input" => 4, "hidden_0" => 2, "output" => 3}
  }

  @output_labels ["diagonal", "row", "column"]

  def topology, do: @topology
  def output_labels, do: @output_labels

  @doc """
  Trainer configuration for the pattern classifier.
  """
  def trainer_config do
    %{
      build: __MODULE__,
      model_fn: &model/0,
      training_data_fn: &training_data/0,
      topology: @topology,
      output_activation: :softmax,
      loss_fn: &Axon.Losses.categorical_cross_entropy(&1, &2, reduction: :mean)
    }
  end

  # Every input board populates the same two pad-pairs with the same
  # best-guess polarity (per bench data on :input_left chip 0). The
  # targets are identical on every input board too: pads (0,1) go to
  # hidden_0[1], pads (9,10) go to hidden_0[0]. Noodles from chain-0
  # chips physically land on col 1; chain-1 chips land on col 2, but
  # that's a property of the physical wiring, not the per-chip config.
  defp input_noodles do
    [
      %{pads: {0, 1}, target: {"hidden_0", 1}, blue_ch: 1, red_ch: 0},
      %{pads: {9, 10}, target: {"hidden_0", 0}, blue_ch: 9, red_ch: 10}
    ]
  end

  # All three output boards populate the same two pad-pairs. Per-chip
  # polarity is best-guess for now --- bench-verify via
  # `Diag.noodles_all(:main, :blue)` and swap blue_ch/red_ch in any
  # pair that lights up red instead of blue.
  defp output_noodles do
    [
      %{pads: {5, 6}, target: {"hidden_0", 0}, blue_ch: 6, red_ch: 5},
      %{pads: {14, 15}, target: {"hidden_0", 1}, blue_ch: 14, red_ch: 15}
    ]
  end

  @doc """
  Chain configurations.

  Each `:boards` entry is a map describing a single physical chip:

      %{
        node: {layer, index},     # logical node this chip visualises
        noodles: [                # populated noodle pairs on this chip
          %{
            pads:    {ch_a, ch_b},   # the two TLC5947 channels for this pair
            target:  {layer, index}, # other end of the edge (hidden-side in V2)
            blue_ch: non_neg_integer, # channel driving the blue (pos) wire
            red_ch:  non_neg_integer  # channel driving the red (neg) wire
          },
          ...
        ]
      }

  Board ordering within a chain is MOSI-side → chain-end. The `:main`
  chain follows the "logical node index ascends physically top-to-bottom"
  convention, so e.g. chip 6 is `output[2]` (bottom of output column)
  and chip 8 is `output[0]` (top). See `docs/build_v2_hardware.md` for
  the full physical layout and channel map.
  """
  def chain_configs do
    [
      %{
        id: :input_left,
        spi_device: "spidev0.0",
        xlat_gpio: "GPIO8",
        boards: [
          %{node: {"input", 0}, noodles: input_noodles()},
          %{node: {"input", 2}, noodles: input_noodles()}
        ],
        render_fn: &render_node/2,
        render_frame_fn: nil
      },
      %{
        id: :main,
        spi_device: "spidev1.0",
        xlat_gpio: "GPIO18",
        boards: [
          %{node: {"input", 1}, noodles: input_noodles()},
          %{node: {"input", 3}, noodles: input_noodles()},
          %{node: {"hidden_0", 1}, noodles: []},
          %{node: {"hidden_0", 0}, noodles: []},
          %{node: {"hidden_0", 0}, noodles: []},
          %{node: {"hidden_0", 1}, noodles: []},
          %{node: {"output", 2}, noodles: output_noodles()},
          %{node: {"output", 1}, noodles: output_noodles()},
          %{node: {"output", 0}, noodles: output_noodles()}
        ],
        render_fn: &render_node/2,
        render_frame_fn: nil
      }
    ]
  end

  @doc """
  Axon model: 4 inputs -> 2 hidden (tanh) -> 3 outputs (softmax).

  No bias terms, which makes the classification slightly harder to learn and
  more interesting to watch train. Softmax ensures outputs are normalised
  probabilities summing to 1.
  """
  def model do
    Axon.input("bits", shape: {nil, 4})
    |> Axon.dense(2, use_bias: false)
    |> Axon.tanh()
    |> Axon.dense(3, use_bias: false)
    |> Axon.softmax()
  end

  @doc """
  Training data: 6 clean 2x2 patterns with one-hot class labels.

  The 4 inputs form a 2x2 grid read row-major: [top-left, top-right,
  bottom-left, bottom-right]. Targets are one-hot encoded:
  - [1, 0, 0] = diagonal
  - [0, 1, 0] = row
  - [0, 0, 1] = column

  Only the 6 unambiguous patterns are included. The network's response to
  ambiguous inputs (all off, single corners, all on, etc.) is emergent.
  """
  def training_data do
    inputs =
      Nx.tensor(
        [
          [1, 0, 0, 1],
          [0, 1, 1, 0],
          [1, 1, 0, 0],
          [0, 0, 1, 1],
          [1, 0, 1, 0],
          [0, 1, 0, 1]
        ],
        type: :f32
      )

    targets =
      Nx.tensor(
        [
          [1, 0, 0],
          [1, 0, 0],
          [0, 1, 0],
          [0, 1, 0],
          [0, 0, 1],
          [0, 0, 1]
        ],
        type: :f32
      )

    {inputs, targets}
  end

  @doc """
  Render a single chip's 24 PWM channels.

  Dispatches on the node's layer:
  - **input**: drive all 6 big-LED channels at `activation` (mono
    shows white brightness; RGB shows white-at-activation since all
    three colour channels are equal). Drive each noodle pair based
    on this input's outgoing-edge contribution to the targeted
    hidden node.
  - **hidden_0**: drive all 6 big-LED channels at the node's HSV→RGB
    colour. Only one triple is populated per chip (ch 18-20 for col 1,
    ch 21-23 for col 2); the other wastes nothing.
  - **output**: drive all 6 big-LED channels at the node's HSV→RGB
    colour (both triples populated). Drive each noodle pair based on
    the incoming-edge contribution from the sourced hidden node.
  """
  def render_node(%NetworkState{} = state, %{node: {"input", index}, noodles: noodles}) do
    activation = NetworkState.activation_for_node(state, "input", index)
    contributions = NetworkState.outgoing_contributions(state, "input", index)

    Board.blank()
    |> set_big_leds(activation, activation, activation)
    |> apply_noodles(noodles, contributions)
  end

  def render_node(%NetworkState{} = state, %{node: {"hidden_0", index}}) do
    activation = NetworkState.activation_for_node(state, "hidden_0", index)
    {r, g, b} = activation_to_rgb(activation, "hidden_0")

    Board.blank() |> set_big_leds(r, g, b)
  end

  def render_node(%NetworkState{} = state, %{node: {"output", index}, noodles: noodles}) do
    activation = NetworkState.activation_for_node(state, "output", index)
    {r, g, b} = activation_to_rgb(activation, "output")
    contributions = NetworkState.incoming_contributions(state, "output", index)

    Board.blank()
    |> set_big_leds(r, g, b)
    |> apply_noodles(noodles, contributions)
  end

  defp set_big_leds(channels, r, g, b) do
    channels
    |> List.replace_at(Board.front_blue(), b)
    |> List.replace_at(Board.front_green(), g)
    |> List.replace_at(Board.front_red(), r)
    |> List.replace_at(Board.rear_blue(), b)
    |> List.replace_at(Board.rear_green(), g)
    |> List.replace_at(Board.rear_red(), r)
  end

  defp apply_noodles(channels, noodles, contributions) do
    Enum.reduce(noodles, channels, fn %{target: {_layer, target_index}} = noodle, acc ->
      {_w, _a, contribution} = Enum.at(contributions, target_index)
      apply_noodle_pair(acc, noodle, contribution)
    end)
  end

  defp apply_noodle_pair(channels, %{blue_ch: blue_ch, red_ch: red_ch}, contribution) do
    if contribution >= 0 do
      channels
      |> List.replace_at(blue_ch, min(contribution, 1.0))
      |> List.replace_at(red_ch, 0.0)
    else
      channels
      |> List.replace_at(blue_ch, 0.0)
      |> List.replace_at(red_ch, min(abs(contribution), 1.0))
    end
  end

  defp activation_to_rgb(activation, "hidden_0") do
    t = (activation + 1) / 2
    hsv_to_rgb(t * 270, 1.0, 1.0)
  end

  defp activation_to_rgb(activation, "output") do
    hsv_to_rgb(activation * 270, 1.0, 1.0)
  end

  defp hsv_to_rgb(h, s, v) do
    c = v * s
    h_prime = h / 60
    x = c * (1 - abs(fmod(h_prime, 2) - 1))

    {r1, g1, b1} =
      case trunc(h_prime) do
        0 -> {c, x, 0.0}
        1 -> {x, c, 0.0}
        2 -> {0.0, c, x}
        3 -> {0.0, x, c}
        4 -> {x, 0.0, c}
        _ -> {c, 0.0, x}
      end

    m = v - c
    {r1 + m, g1 + m, b1 + m}
  end

  defp fmod(a, b), do: a - Float.floor(a / b) * b
end
