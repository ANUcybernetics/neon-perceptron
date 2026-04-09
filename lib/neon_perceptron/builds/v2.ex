defmodule NeonPerceptron.Builds.V2 do
  @moduledoc """
  V2 build: mini XOR perceptron.

  A 4→3→2 network demonstrating that a hidden layer with nonlinear activation
  can solve linearly inseparable problems (XOR). Physical layout: 12 TLC5947
  boards across 5 chip selects (SPI0 CE0/CE1 + SPI1 CE0/CE1/CE2) on a single
  reTerminal DM.

  The 2x2 input grid has two diagonal patterns:
  - Left diagonal:  `[[1,0],[0,1]]` → output[0] = 1
  - Right diagonal: `[[0,1],[1,0]]` → output[1] = 1

  ## Physical layout

  | spidev   | Column       | Boards | Network nodes                     |
  |----------|-------------|--------|----------------------------------|
  | spidev0.0 | input_left   | 2      | input[0], input[2]               |
  | spidev0.1 | input_right  | 2      | input[1], input[3]               |
  | spidev1.0 | hidden_front | 3      | hidden_0[0], hidden_0[1], hidden_0[2] |
  | spidev1.1 | hidden_rear  | 3      | Same 3 hidden nodes (back-to-back) |
  | spidev1.2 | output       | 2      | output[0], output[1]             |
  """

  alias NeonPerceptron.{Board, NetworkState}

  @topology %{
    layers: ["input", "hidden_0", "output"],
    sizes: %{"input" => 4, "hidden_0" => 3, "output" => 2}
  }

  def topology, do: @topology

  @doc """
  Trainer configuration for the XOR network.
  """
  def trainer_config do
    %{
      build: __MODULE__,
      model_fn: &model/0,
      training_data_fn: &training_data/0,
      topology: @topology
    }
  end

  @doc """
  Column configurations for the 5 SPI channels.

  Requires dtoverlay=spi1-3cs in config.txt (and CAN/audio overlays omitted)
  to make SPI1 CE0/CE1/CE2 available on GPIO 18/17/16.
  """
  def column_configs do
    render = &render_node/2

    [
      %{
        id: :input_left,
        spi_device: "spidev0.0",
        boards: [
          %{layer: "input", node_index: 0},
          %{layer: "input", node_index: 2}
        ],
        render_fn: render,
        render_frame_fn: nil
      },
      %{
        id: :input_right,
        spi_device: "spidev0.1",
        boards: [
          %{layer: "input", node_index: 1},
          %{layer: "input", node_index: 3}
        ],
        render_fn: render,
        render_frame_fn: nil
      },
      %{
        id: :hidden_front,
        spi_device: "spidev1.0",
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
        spi_device: "spidev1.1",
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
        spi_device: "spidev1.2",
        boards: [
          %{layer: "output", node_index: 0},
          %{layer: "output", node_index: 1}
        ],
        render_fn: render,
        render_frame_fn: nil
      }
    ]
  end

  @doc """
  Axon model: 4 inputs → 3 hidden (tanh) → 2 outputs (sigmoid).
  """
  def model do
    Axon.input("bits", shape: {nil, 4})
    |> Axon.dense(3, use_bias: false)
    |> Axon.tanh()
    |> Axon.dense(2, use_bias: false)
    |> Axon.sigmoid()
  end

  @doc """
  XOR training data for a 2x2 grid.

  The 4 inputs form a 2x2 grid read row-major: [top-left, top-right,
  bottom-left, bottom-right]. The 2 outputs are:
  - output[0]: left diagonal active (top-left == bottom-right, others off)
  - output[1]: right diagonal active (top-right == bottom-left, others off)
  """
  def training_data do
    inputs =
      Nx.tensor(
        [
          # all off
          [0, 0, 0, 0],
          # left diagonal
          [1, 0, 0, 1],
          # right diagonal
          [0, 1, 1, 0],
          # all on
          [1, 1, 1, 1],
          # top-left only
          [1, 0, 0, 0],
          # top-right only
          [0, 1, 0, 0],
          # bottom-left only
          [0, 0, 1, 0],
          # bottom-right only
          [0, 0, 0, 1],
          # top row
          [1, 1, 0, 0],
          # bottom row
          [0, 0, 1, 1],
          # left column
          [1, 0, 1, 0],
          # right column
          [0, 1, 0, 1]
        ],
        type: :f32
      )

    targets =
      Nx.tensor(
        [
          # all off → neither diagonal
          [0, 0],
          # left diagonal → output[0]
          [1, 0],
          # right diagonal → output[1]
          [0, 1],
          # all on → both diagonals
          [1, 1],
          # single corners → neither
          [0, 0],
          [0, 0],
          [0, 0],
          [0, 0],
          # rows → neither
          [0, 0],
          [0, 0],
          # columns → neither
          [0, 0],
          [0, 0]
        ],
        type: :f32
      )

    {inputs, targets}
  end

  @doc """
  Render a single node board's 24 PWM channels.

  Current strategy (simple, will evolve):
  - Big LED front: node activation as white brightness
  - Big LED rear: same as front
  - Individual LEDs 0--17: incoming weight contributions (abs value)
  """
  def render_node(%NetworkState{} = state, %{layer: layer, node_index: index}) do
    activation = NetworkState.activation_for_node(state, layer, index)
    brightness = abs(activation)

    channels = Board.blank()

    channels =
      channels
      |> List.replace_at(Board.front_blue(), brightness)
      |> List.replace_at(Board.front_green(), brightness)
      |> List.replace_at(Board.front_red(), brightness)
      |> List.replace_at(Board.rear_blue(), brightness)
      |> List.replace_at(Board.rear_green(), brightness)
      |> List.replace_at(Board.rear_red(), brightness)

    incoming = NetworkState.incoming_contributions(state, layer, index)

    incoming
    |> Enum.take(18)
    |> Enum.with_index()
    |> Enum.reduce(channels, fn {{_weight, _act, contribution}, ch_index}, acc ->
      List.replace_at(acc, ch_index, abs(contribution))
    end)
  end
end
