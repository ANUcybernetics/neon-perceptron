defmodule NeonPerceptron.TrainerTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Trainer, NetworkState, Builds.V2}

  setup do
    # Trainer is already started by the application supervisor with V2 config.
    # Wait for it to have run a few training steps.
    Process.sleep(100)
    :ok
  end

  describe "init and training" do
    test "is running and training" do
      iteration = Trainer.iteration()
      assert iteration > 0
    end

    test "network_state returns a valid NetworkState" do
      state = Trainer.network_state()
      assert %NetworkState{} = state
      assert length(state.activations["input"]) == 4
      assert length(state.activations["hidden_0"]) == 3
      assert length(state.activations["output"]) == 3
      assert map_size(state.weights) == 2
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
      Trainer.set_web_input([1.0, 0.0, 0.0, 1.0])
      Process.sleep(100)

      state = Trainer.network_state()
      assert state.activations["input"] == [1.0, 0.0, 0.0, 1.0]

      # Reset so other tests aren't affected
      Trainer.set_web_input(nil)
    end
  end

  describe "predict/1" do
    test "returns prediction tensor" do
      result = Trainer.predict([1, 0, 0, 1])
      assert {1, 3} = Nx.shape(result)
    end
  end

  describe "topology/0" do
    test "returns the build topology" do
      topology = Trainer.topology()
      assert topology == V2.topology()
    end
  end
end
