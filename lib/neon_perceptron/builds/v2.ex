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
  - **2 hidden** (gelu, no bias)
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

  13 TLC5947 boards across 2 SPI chains. The reTerminal DM carrier claims
  GPIO 2/3 (SPI3 alt function) for i2c1/PCF857x (DSI reset, LCD power),
  so we can't use 5 dedicated SPI buses. Instead, we daisy-chain
  everything onto SPI3 except one input column which lives on SPI0.

  | spidev    | Chain ID      | Chips | Contents                               |
  |-----------|---------------|-------|----------------------------------------|
  | spidev0.0 | `:input_left` | 2     | input[0], input[2]                     |
  | spidev1.0 | `:main`       | 9     | input_right + hidden (front+rear) + output |

  The wiring is purely a property of `chain_configs/0` --- edit that
  single function to re-cable the installation.

  ## Installation nomenclature

  "Back" and "front" refer to *installation-wide* orientation:

  - **Back** = input-side of the installation (closer to the input layer).
  - **Front** = output-side of the installation (closer to the output layer).

  This is distinct from `Board`'s `@front_*` / `@rear_*` channel constants,
  which name *chip-local* PCB pad triples. A big-LED pad labelled "front_red"
  in `Board` is just "channel 20 of the TLC5947" --- its physical location
  in the installation depends on how the board is oriented when mounted.

  ## LED inventory

  18 big LEDs plus noodle wires on the TLC5947 chain:

  - **4 monochrome big LEDs** --- one on the *back* of each of the 4 input
    boards.
  - **14 RGB big LEDs**:
    - 4 on the *front* of each input board (1 per input).
    - 2 on the *back* of the first hidden column.
    - 2 on the *front* of the second hidden column.
    - 6 on the output column (1 *front* + 1 *back* for each of 3 output
      nodes).

  The specific TLC5947 channel each physical LED is wired to is not uniform
  across boards and is being characterised in TASK-17. Do not assume channels
  18--23 on a given board correspond to big-LED pads --- on input boards at
  least one channel in 18--23 has been observed driving a noodle instead.

  ## LED hardware per board (TLC5947, 24 channels)

  ### Big LEDs

  The "big LED" pads on each PCB live at channels 18--20 ("front" pad triple)
  and 21--23 ("rear" pad triple) in the canonical `Board` layout. Population
  varies by role:

  - **Input boards**: one monochrome white LED on the *back* of the
    installation (3 RGB pads tied to one LED element), plus one RGB LED on
    the *front*. Brightness on the mono encodes input activation (0.0--1.0).
    The intent for the front RGB is TBD.
  - **Hidden boards**: one RGB big LED facing the gap between the two
    physical hidden columns (back of column 1 or front of column 2,
    depending on which copy of the node). Hue encodes activation.
  - **Output boards**: one RGB big LED on the *front* and one on the *back*.
    Hue encodes activation.

  Specific TLC5947 channels driving each populated big LED are TBD per board
  --- see TASK-17.

  ### LED noodles

  Each noodle is a flexible LED wire connecting two boards in adjacent
  layers. The PWM signal for a noodle comes from the *non-hidden* end of
  the wire --- the hidden-side end is a voltage reference only. So:

  - **Input-to-hidden noodles** are driven by the input boards. Each input
    board drives 3 outgoing-edge noodle pairs (one pair per hidden node),
    totalling 6 noodles per input board.
  - **Hidden-to-output noodles** are driven by the output boards. Each output
    board drives 3 incoming-edge noodle pairs (one pair per hidden node),
    totalling 6 noodles per output board.
  - **Hidden boards drive no noodles** --- noodles terminate on hidden boards
    only for voltage reference.

  Each noodle pair is colour-coded for sign of the edge contribution:

  - **Positive noodle**: lit when the edge contribution
    (weight × source activation) is positive.
  - **Negative noodle**: lit when the contribution is negative.
  - Brightness = `min(abs(contribution), 1.0)`.

  Specific TLC5947 channels driving each noodle pair on input/output boards
  are TBD --- see TASK-17.
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

  @doc """
  Chain configurations.

  Each entry describes one SPI chain: the `spi_device`, and an ordered
  list of chips (`boards`) from the MOSI-side of the chain to the far
  end. Each chip entry is `{layer, node_index}` --- the logical network
  node that chip visualises. Repeating a node means "another physical
  chip for the same node" (e.g. the front and rear big LEDs on the
  hidden layer).

  To re-cable, just edit this function. No other code depends on the
  wiring layout.

  Requires `dtoverlay=spi0-1cs,cs0_pin=26` and
  `dtoverlay=spi1-1cs,cs0_pin=25` in `config/rpi4/config.txt`. Both chains
  use manual XLAT (kernel CE on Pi 4 doesn't reliably latch TLC5947).
  """
  def chain_configs do
    render = &render_node/2

    [
      %{
        id: :input_left,
        spi_device: "spidev0.0",
        xlat_gpio: "GPIO8",
        boards: [
          {"input", 0},
          {"input", 2}
        ],
        render_fn: render,
        render_frame_fn: nil
      },
      %{
        id: :main,
        spi_device: "spidev1.0",
        xlat_gpio: "GPIO18",
        boards: [
          {"input", 1},
          {"input", 3},
          {"hidden_0", 0},
          {"hidden_0", 1},
          {"hidden_0", 0},
          {"hidden_0", 1},
          {"output", 0},
          {"output", 1},
          {"output", 2}
        ],
        render_fn: render,
        render_frame_fn: nil
      }
    ]
  end

  @doc """
  Axon model: 4 inputs -> 2 hidden (gelu) -> 3 outputs (softmax).

  No bias terms, which makes the classification slightly harder to learn and
  more interesting to watch train. GELU (rather than tanh) is used for the
  hidden activation --- with only 2 hidden units tanh gets stuck in local
  minima ~80% of the time, whereas GELU reaches 100% training accuracy in
  ~80% of runs. Softmax ensures outputs are normalised probabilities
  summing to 1.
  """
  def model do
    Axon.input("bits", shape: {nil, 4})
    |> Axon.dense(2, use_bias: false)
    |> Axon.gelu()
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
  def render_node(%NetworkState{} = state, {"input", index}) do
    activation = NetworkState.activation_for_node(state, "input", index)

    Board.blank()
    |> List.replace_at(Board.front_blue(), activation)
    |> List.replace_at(Board.front_green(), activation)
    |> List.replace_at(Board.front_red(), activation)
    |> List.replace_at(Board.rear_blue(), activation)
    |> List.replace_at(Board.rear_green(), activation)
    |> List.replace_at(Board.rear_red(), activation)
  end

  def render_node(%NetworkState{} = state, {layer, index}) do
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
