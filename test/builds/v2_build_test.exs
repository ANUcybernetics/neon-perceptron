defmodule NeonPerceptron.Builds.V2Test do
  use ExUnit.Case, async: true

  alias NeonPerceptron.Builds.V2
  alias NeonPerceptron.NetworkState

  describe "topology/0" do
    test "defines a 4->2->3 network" do
      t = V2.topology()
      assert t.layers == ["input", "hidden_0", "output"]
      assert t.sizes == %{"input" => 4, "hidden_0" => 2, "output" => 3}
    end
  end

  describe "chain_configs/0" do
    test "returns 2 chains" do
      configs = V2.chain_configs()
      assert length(configs) == 2
    end

    test "chains have correct board counts" do
      configs = V2.chain_configs()
      board_counts = Enum.map(configs, &length(&1.boards))
      assert Enum.sort(board_counts) == [2, 9]
    end

    test "total boards is 11" do
      total = V2.chain_configs() |> Enum.flat_map(& &1.boards) |> length()
      assert total == 11
    end

    test "all chains have render_fn" do
      for config <- V2.chain_configs() do
        assert is_function(config.render_fn, 2)
      end
    end

    test "main chain is on spidev1.0 and input_left on spidev0.0" do
      by_id = V2.chain_configs() |> Map.new(&{&1.id, &1})
      assert by_id[:input_left].spi_device == "spidev0.0"
      assert by_id[:main].spi_device == "spidev1.0"
    end

    test "both chains have xlat_gpio configured" do
      by_id = V2.chain_configs() |> Map.new(&{&1.id, &1})
      assert by_id[:input_left].xlat_gpio == "GPIO8"
      assert by_id[:main].xlat_gpio == "GPIO18"
    end

    test "every board entry references a valid layer and node index" do
      %{layers: layers, sizes: sizes} = V2.topology()

      for %{boards: boards} <- V2.chain_configs(),
          %{node: {layer, index}} <- boards do
        assert layer in layers, "unknown layer #{inspect(layer)}"
        assert index in 0..(sizes[layer] - 1), "index #{index} out of range for #{layer}"
      end
    end

    test "main chain follows logical-top-to-bottom convention" do
      by_id = V2.chain_configs() |> Map.new(&{&1.id, &1})
      nodes = Enum.map(by_id[:main].boards, & &1.node)

      assert nodes == [
               {"input", 1},
               {"input", 3},
               {"hidden_0", 1},
               {"hidden_0", 0},
               {"hidden_0", 0},
               {"hidden_0", 1},
               {"output", 2},
               {"output", 1},
               {"output", 0}
             ]
    end

    test "hidden boards have no noodles" do
      for %{boards: boards} <- V2.chain_configs(),
          %{node: {"hidden_0", _}, noodles: noodles} <- boards do
        assert noodles == []
      end
    end

    test "input boards have two noodle pairs targeting hidden_0[0] and hidden_0[1]" do
      for %{boards: boards} <- V2.chain_configs(),
          %{node: {"input", _}, noodles: noodles} <- boards do
        assert length(noodles) == 2
        targets = Enum.map(noodles, & &1.target) |> Enum.sort()
        assert targets == [{"hidden_0", 0}, {"hidden_0", 1}]
      end
    end

    test "output boards have two noodle pairs targeting hidden_0[0] and hidden_0[1]" do
      for %{boards: boards} <- V2.chain_configs(),
          %{node: {"output", _}, noodles: noodles} <- boards do
        assert length(noodles) == 2
        targets = Enum.map(noodles, & &1.target) |> Enum.sort()
        assert targets == [{"hidden_0", 0}, {"hidden_0", 1}]
      end
    end

    test "every noodle's blue_ch and red_ch are within its pads tuple" do
      for %{boards: boards} <- V2.chain_configs(),
          %{noodles: noodles} <- boards,
          noodle <- noodles do
        {a, b} = noodle.pads
        assert noodle.blue_ch in [a, b]
        assert noodle.red_ch in [a, b]
        assert noodle.blue_ch != noodle.red_ch
      end
    end
  end

  describe "model/0" do
    test "returns an Axon model" do
      model = V2.model()
      assert %Axon{} = model
    end

    test "model has correct output shape" do
      model = V2.model()
      {init_fn, predict_fn} = Axon.build(model)
      params = init_fn.(Nx.tensor([[0, 0, 0, 0]], type: :f32), Axon.ModelState.empty())
      output = predict_fn.(params, Nx.tensor([[1, 0, 0, 1]], type: :f32))
      assert Nx.shape(output) == {1, 3}
    end

    test "model has no biases" do
      model = V2.model()
      {init_fn, _} = Axon.build(model)
      %{data: data} = init_fn.(Nx.tensor([[0, 0, 0, 0]], type: :f32), Axon.ModelState.empty())

      for {_layer_name, params} <- data do
        refute Map.has_key?(params, "bias")
      end
    end
  end

  describe "training_data/0" do
    test "returns correctly shaped tensors" do
      {inputs, targets} = V2.training_data()
      {n, input_size} = Nx.shape(inputs)
      {^n, output_size} = Nx.shape(targets)
      assert input_size == 4
      assert output_size == 3
      assert n == 6
    end
  end

  describe "output_labels/0" do
    test "returns 3 class labels" do
      labels = V2.output_labels()
      assert labels == ["diagonal", "row", "column"]
    end
  end

  describe "render_node/2" do
    defp input_spec(index) do
      %{
        node: {"input", index},
        noodles: [
          %{pads: {0, 1}, target: {"hidden_0", 1}, blue_ch: 1, red_ch: 0},
          %{pads: {9, 10}, target: {"hidden_0", 0}, blue_ch: 9, red_ch: 10}
        ]
      }
    end

    defp hidden_spec(index), do: %{node: {"hidden_0", index}, noodles: []}

    defp output_spec(index) do
      %{
        node: {"output", index},
        noodles: [
          %{pads: {5, 6}, target: {"hidden_0", 0}, blue_ch: 6, red_ch: 5},
          %{pads: {14, 15}, target: {"hidden_0", 1}, blue_ch: 14, red_ch: 15}
        ]
      }
    end

    test "returns 24 channel values for each layer" do
      state = NetworkState.null(V2.topology())
      assert length(V2.render_node(state, input_spec(0))) == 24
      assert length(V2.render_node(state, hidden_spec(0))) == 24
      assert length(V2.render_node(state, output_spec(0))) == 24
    end

    test "input big LEDs reflect activation brightness on all six channels" do
      state = %NetworkState{
        activations: %{
          "input" => [0.8, 0.0, 0.0, 0.0],
          "hidden_0" => [0.0, 0.0],
          "output" => [0.0, 0.0, 0.0]
        },
        weights: %{
          "dense_0" => List.duplicate(0.0, 4 * 2),
          "dense_1" => List.duplicate(0.0, 2 * 3)
        },
        topology: V2.topology()
      }

      channels = V2.render_node(state, input_spec(0))
      for ch <- 18..23, do: assert(Enum.at(channels, ch) == 0.8)
    end

    test "input noodles light positive contribution on blue channel, zero red" do
      # input[0] activation = 1.0, outgoing weights to hidden = [0.5, -0.25]
      # hidden_0[0] noodle at pads (9,10): contrib = +0.5 → blue=ch 9, red=ch 10 = 0
      # hidden_0[1] noodle at pads (0,1): contrib = -0.25 → red=ch 0 = 0.25, blue=ch 1 = 0
      state = %NetworkState{
        activations: %{
          "input" => [1.0, 0.0, 0.0, 0.0],
          "hidden_0" => [0.0, 0.0],
          "output" => [0.0, 0.0, 0.0]
        },
        weights: %{
          # kernel layout: [w_i0h0, w_i0h1, w_i1h0, w_i1h1, ...]
          "dense_0" => [0.5, -0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
          "dense_1" => List.duplicate(0.0, 2 * 3)
        },
        topology: V2.topology()
      }

      channels = V2.render_node(state, input_spec(0))
      assert Enum.at(channels, 9) == 0.5
      assert Enum.at(channels, 10) == 0.0
      assert Enum.at(channels, 0) == 0.25
      assert Enum.at(channels, 1) == 0.0
    end

    test "hidden boards never drive noodle channels 0..17" do
      state = NetworkState.null(V2.topology())
      channels = V2.render_node(state, hidden_spec(0))
      for ch <- 0..17, do: assert(Enum.at(channels, ch) == 0.0)
    end
  end
end
