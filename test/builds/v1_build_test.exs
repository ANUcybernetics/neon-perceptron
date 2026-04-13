defmodule NeonPerceptron.Builds.V1Test do
  use ExUnit.Case, async: true

  alias NeonPerceptron.Builds.V1
  alias NeonPerceptron.NetworkState

  describe "topology/0" do
    test "defines a 7→2→10 network" do
      t = V1.topology()
      assert t.layers == ["input", "hidden_0", "output"]
      assert t.sizes == %{"input" => 7, "hidden_0" => 2, "output" => 10}
    end
  end

  describe "chain_configs/0" do
    test "returns 1 chain with render_frame_fn" do
      [config] = V1.chain_configs()
      assert config.id == :v1_display
      assert config.spi_device == "spidev0.0"
      assert is_function(config.render_frame_fn, 1)
      assert config.render_fn == nil
    end
  end

  describe "trainer_config/0" do
    test "uses softmax and categorical cross-entropy" do
      config = V1.trainer_config()
      assert config.output_activation == :softmax
      assert is_function(config.loss_fn, 2)
    end
  end

  describe "model/0" do
    test "returns an Axon model with correct output" do
      model = V1.model()
      {init_fn, predict_fn} = Axon.build(model)
      input = Nx.tensor([[1, 1, 1, 1, 1, 1, 0]], type: :f32)
      params = init_fn.(input, Axon.ModelState.empty())
      output = predict_fn.(params, input)
      assert Nx.shape(output) == {1, 10}
    end
  end

  describe "training_data/0" do
    test "returns correctly shaped tensors" do
      {inputs, targets} = V1.training_data()
      assert Nx.shape(inputs) == {10, 7}
      assert Nx.shape(targets) == {10, 10}
    end
  end

  describe "render_frame/1" do
    test "returns 72 channel values" do
      state = NetworkState.null(V1.topology())
      frame = V1.render_frame(state)
      assert length(frame) == 72
    end

    test "input layer maps to channels 62-68" do
      state = %NetworkState{
        activations: %{
          "input" => [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0],
          "hidden_0" => [0.0, 0.0],
          "output" => List.duplicate(0.0, 10)
        },
        weights: %{
          "dense_0" => List.duplicate(0.0, 14),
          "dense_1" => List.duplicate(0.0, 20)
        },
        topology: V1.topology()
      }

      frame = V1.render_frame(state)
      # channels 62-68 should have the input values
      assert Enum.slice(frame, 62, 7) == [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0]
    end

    test "hidden neurons map to channels 15 and 39" do
      state = %NetworkState{
        activations: %{
          "input" => List.duplicate(0.0, 7),
          "hidden_0" => [0.7, 0.3],
          "output" => List.duplicate(0.0, 10)
        },
        weights: %{
          "dense_0" => List.duplicate(0.0, 14),
          "dense_1" => List.duplicate(0.0, 20)
        },
        topology: V1.topology()
      }

      frame = V1.render_frame(state)
      assert Enum.at(frame, 15) == 0.7
      assert Enum.at(frame, 39) == 0.3
    end
  end
end
