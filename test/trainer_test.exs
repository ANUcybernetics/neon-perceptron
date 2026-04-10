defmodule NeonPerceptron.TrainerTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Trainer, NetworkState}

  @build Application.compile_env!(:neon_perceptron, :build)

  setup do
    Process.sleep(100)
    :ok
  end

  describe "init and training" do
    test "is running and training" do
      iteration = Trainer.iteration()
      assert iteration > 0
    end

    test "network_state returns a valid NetworkState" do
      topology = @build.topology()
      state = Trainer.network_state()
      assert %NetworkState{} = state

      for layer <- topology.layers do
        assert length(state.activations[layer]) == topology.sizes[layer]
      end
    end

    test "broadcasts network_state via PubSub" do
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "network_state")
      assert_receive {:network_state, %NetworkState{}}, 1000
    end
  end

  describe "reset/0" do
    test "resets training state" do
      Process.sleep(50)
      iter_before = Trainer.iteration()
      assert iter_before > 0

      Trainer.reset()
      Process.sleep(50)
      iter_after = Trainer.iteration()
      assert iter_after < iter_before
    end
  end

  describe "set_web_input/1" do
    test "overrides input for activation computation" do
      topology = @build.topology()
      input_size = topology.sizes["input"]
      web_input = List.duplicate(1.0, input_size)

      Trainer.set_web_input(web_input)
      Process.sleep(100)

      state = Trainer.network_state()
      assert state.activations["input"] == web_input

      Trainer.set_web_input(nil)
    end
  end

  describe "predict/1" do
    test "returns prediction tensor" do
      topology = @build.topology()
      input_size = topology.sizes["input"]
      output_size = topology.sizes["output"]

      result = Trainer.predict(List.duplicate(1, input_size))
      assert {1, ^output_size} = Nx.shape(result)
    end
  end

  describe "topology/0" do
    test "returns the build topology" do
      topology = Trainer.topology()
      assert topology == @build.topology()
    end
  end
end
