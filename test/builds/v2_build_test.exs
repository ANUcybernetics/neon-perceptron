defmodule NeonPerceptron.Builds.V2Test do
  use ExUnit.Case, async: true

  alias NeonPerceptron.Builds.V2
  alias NeonPerceptron.NetworkState

  describe "topology/0" do
    test "defines a 4->3->3 network" do
      t = V2.topology()
      assert t.layers == ["input", "hidden_0", "output"]
      assert t.sizes == %{"input" => 4, "hidden_0" => 3, "output" => 3}
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
      assert Enum.sort(board_counts) == [2, 11]
    end

    test "total boards is 13" do
      total = V2.chain_configs() |> Enum.flat_map(& &1.boards) |> length()
      assert total == 13
    end

    test "all chains have render_fn" do
      for config <- V2.chain_configs() do
        assert is_function(config.render_fn, 2)
      end
    end

    test "main chain is on spidev0.0 and input_left on spidev1.0" do
      by_id = V2.chain_configs() |> Map.new(&{&1.id, &1})
      assert by_id[:input_left].spi_device == "spidev1.0"
      assert by_id[:main].spi_device == "spidev0.0"
    end

    test "every board entry references a valid layer and node index" do
      %{layers: layers, sizes: sizes} = V2.topology()

      for %{boards: boards} <- V2.chain_configs(),
          {layer, index} <- boards do
        assert layer in layers, "unknown layer #{inspect(layer)}"
        assert index in 0..(sizes[layer] - 1), "index #{index} out of range for #{layer}"
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
    test "returns 24 channel values" do
      state = NetworkState.null(V2.topology())
      channels = V2.render_node(state, {"input", 0})
      assert length(channels) == 24
    end

    test "big LEDs reflect activation brightness" do
      state = %NetworkState{
        activations: %{
          "input" => [0.8, 0.0, 0.0, 0.0],
          "hidden_0" => [0, 0, 0],
          "output" => [0, 0, 0]
        },
        weights: %{
          "dense_0" => List.duplicate(0.0, 12),
          "dense_1" => List.duplicate(0.0, 9)
        },
        topology: V2.topology()
      }

      channels = V2.render_node(state, {"input", 0})
      assert Enum.at(channels, 18) == 0.8
      assert Enum.at(channels, 19) == 0.8
      assert Enum.at(channels, 20) == 0.8
    end
  end
end
