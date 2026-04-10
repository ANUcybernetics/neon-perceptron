defmodule NeonPerceptron.Builds.V2 do
  @moduledoc """
  V2 build: 2x2 pattern classifier.

  A 4->3->3 network that classifies 2x2 binary input patterns into three
  categories: diagonal, row, or column. Demonstrates that a hidden layer with
  nonlinear activation can solve linearly inseparable classification problems
  --- the core insight from Minsky & Papert's 1969 *Perceptrons* critique.

  ## Network

  - **4 inputs**: 2x2 grid read row-major [top-left, top-right, bottom-left,
    bottom-right], values 0.0--1.0 (continuous, driven by touch)
  - **3 hidden** (tanh, no bias)
  - **3 outputs** (softmax): probabilities summing to 1
    - output[0] = diagonal (⟍ or ⟋)
    - output[1] = row (top or bottom)
    - output[2] = column (left or right)
  - **Loss**: categorical cross-entropy

  ## Training data

  Only the 6 clean patterns are used for training. The 10 ambiguous patterns
  (all off, all on, single corners, three-of-four) are deliberately excluded
  so that the network's response to them is emergent --- viewers can explore
  how the trained network generalises to inputs it hasn't seen.

  | Pattern          | Inputs       | Label    |
  |------------------|-------------|----------|
  | left diagonal ⟍  | [1,0,0,1]   | diagonal |
  | right diagonal ⟋ | [0,1,1,0]   | diagonal |
  | top row          | [1,1,0,0]   | row      |
  | bottom row       | [0,0,1,1]   | row      |
  | left column      | [1,0,1,0]   | column   |
  | right column     | [0,1,0,1]   | column   |

  ## Physical layout

  13 TLC5947 boards across 5 chip selects (SPI0 CE0/CE1 + SPI1 CE0/CE1/CE2)
  on a single reTerminal DM.

  | spidev    | Column       | Boards | Network nodes                          |
  |-----------|-------------|--------|----------------------------------------|
  | spidev0.0 | input_left   | 2      | input[0], input[2]                     |
  | spidev0.1 | input_right  | 2      | input[1], input[3]                     |
  | spidev1.0 | hidden_front | 3      | hidden_0[0], hidden_0[1], hidden_0[2]  |
  | spidev1.1 | hidden_rear  | 3      | Same 3 hidden nodes (back-to-back)     |
  | spidev1.2 | output       | 3      | output[0] (diag), output[1] (row), output[2] (col) |

  ## LED hardware per board (TLC5947, 24 channels)

  ### Big LEDs (channels 18--23)

  Each board has a front and rear "big LED" driven by three PWM channels each.
  The physical LED type differs by layer:

  - **Input layer boards**: monochrome LEDs --- all three RGB pads are wired to
    the same LED element. Setting R=G=B=brightness is sufficient; the hue
    doesn't matter. Brightness encodes the input activation (0.0--1.0).
  - **Hidden and output layer boards**: proper RGB LEDs. Hue encodes the node's
    activation value, at full saturation and value.

  ### LED noodles (channels 0--17, 9 pairs)

  Each board has 18 individual PWM outputs driving 9 pairs of LED "noodles"
  (flexible LED wires). Each pair represents one incoming edge in the neural
  network graph. The two noodles in a pair are different physical colours,
  forming a diverging colour palette:

  - **Channel 2*i** (even): "positive" noodle --- lit when the edge
    contribution (weight * source activation) is positive.
  - **Channel 2*i+1** (odd): "negative" noodle --- lit when the edge
    contribution is negative.
  - Brightness = magnitude of the contribution, clamped to [0, 1].

  Pair-to-edge mapping:
  - Hidden nodes (4 incoming edges from input): pairs 0--3 used, pairs 4--8 dark.
  - Output nodes (3 incoming edges from hidden): pairs 0--2 used, pairs 3--8 dark.
  - Input nodes (no incoming edges): all noodle pairs dark.
  """

  alias NeonPerceptron.{Board, NetworkState}

  @topology %{
    layers: ["input", "hidden_0", "output"],
    sizes: %{"input" => 4, "hidden_0" => 3, "output" => 3}
  }

  @output_labels ["diagonal", "row", "column"]

  def topology, do: @topology
  def output_labels, do: @output_labels

  def extra_children do
    ids = Enum.map(column_configs(), & &1.id)
    [{NeonPerceptron.FrameCoordinator, ids}]
  end

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

  @doc """
  Column configurations for the 5 SPI channels.

  Requires dtoverlay=spi1-3cs in config.txt (and CAN/audio overlays omitted)
  to make SPI1 CE0/CE1/CE2 available on GPIO 18/17/16.

  SPI1 columns use spidev0.0 for data (shared SPI0 MOSI/SCLK) and a spidev1.x
  dummy transfer to pulse XLAT via its CS line. See TASK-16 for details.

  Order matters: SPI1 columns first, then spidev0.1, then spidev0.0 last so
  input_left re-latches its own correct data after spurious CE0 XLATs.
  """
  def column_configs do
    render = &render_node/2

    [
      %{
        id: :hidden_front,
        spi_device: "spidev0.0",
        xlat_spi_device: "spidev1.0",
        pubsub_subscribe: false,
        boards: [
          %{layer: "hidden_0", node_index: 0},
          %{layer: "hidden_0", node_index: 1},
          %{layer: "hidden_0", node_index: 2}
        ],
        render_fn: render,
        render_frame_fn: nil
      },
      %{
        id: :hidden_rear,
        spi_device: "spidev0.0",
        xlat_spi_device: "spidev1.1",
        pubsub_subscribe: false,
        boards: [
          %{layer: "hidden_0", node_index: 0},
          %{layer: "hidden_0", node_index: 1},
          %{layer: "hidden_0", node_index: 2}
        ],
        render_fn: render,
        render_frame_fn: nil
      },
      %{
        id: :output,
        spi_device: "spidev0.0",
        xlat_spi_device: "spidev1.2",
        pubsub_subscribe: false,
        boards: [
          %{layer: "output", node_index: 0},
          %{layer: "output", node_index: 1},
          %{layer: "output", node_index: 2}
        ],
        render_fn: render,
        render_frame_fn: nil
      },
      %{
        id: :input_right,
        spi_device: "spidev0.1",
        pubsub_subscribe: false,
        boards: [
          %{layer: "input", node_index: 1},
          %{layer: "input", node_index: 3}
        ],
        render_fn: render,
        render_frame_fn: nil
      },
      %{
        id: :input_left,
        spi_device: "spidev0.0",
        pubsub_subscribe: false,
        boards: [
          %{layer: "input", node_index: 0},
          %{layer: "input", node_index: 2}
        ],
        render_fn: render,
        render_frame_fn: nil
      }
    ]
  end

  @doc """
  Axon model: 4 inputs -> 3 hidden (tanh) -> 3 outputs (softmax).

  No bias terms, which makes the classification slightly harder to learn and
  more interesting to watch train. Softmax ensures outputs are normalised
  probabilities summing to 1.
  """
  def model do
    Axon.input("bits", shape: {nil, 4})
    |> Axon.dense(3, use_bias: false)
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
  Render a single node board's 24 PWM channels.

  Dispatches to layer-specific rendering: input nodes use monochrome big LEDs
  with no noodles; hidden/output nodes use RGB big LEDs with noodle pairs
  showing incoming edge contributions.
  """
  def render_node(%NetworkState{} = state, %{layer: "input", node_index: index}) do
    activation = NetworkState.activation_for_node(state, "input", index)

    Board.blank()
    |> List.replace_at(Board.front_blue(), activation)
    |> List.replace_at(Board.front_green(), activation)
    |> List.replace_at(Board.front_red(), activation)
    |> List.replace_at(Board.rear_blue(), activation)
    |> List.replace_at(Board.rear_green(), activation)
    |> List.replace_at(Board.rear_red(), activation)
  end

  def render_node(%NetworkState{} = state, %{layer: layer, node_index: index}) do
    activation = NetworkState.activation_for_node(state, layer, index)
    {r, g, b} = activation_to_rgb(activation, layer)

    channels =
      Board.blank()
      |> List.replace_at(Board.front_red(), r)
      |> List.replace_at(Board.front_green(), g)
      |> List.replace_at(Board.front_blue(), b)
      |> List.replace_at(Board.rear_red(), r)
      |> List.replace_at(Board.rear_green(), g)
      |> List.replace_at(Board.rear_blue(), b)

    incoming = NetworkState.incoming_contributions(state, layer, index)

    Enum.with_index(incoming)
    |> Enum.reduce(channels, fn {{_weight, _act, contribution}, pair_index}, acc ->
      pos_ch = pair_index * 2
      neg_ch = pair_index * 2 + 1

      if contribution >= 0 do
        acc
        |> List.replace_at(pos_ch, min(contribution, 1.0))
        |> List.replace_at(neg_ch, 0.0)
      else
        acc
        |> List.replace_at(pos_ch, 0.0)
        |> List.replace_at(neg_ch, min(abs(contribution), 1.0))
      end
    end)
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
