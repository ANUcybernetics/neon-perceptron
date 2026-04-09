defmodule NeonPerceptron.NetworkStateTest do
  use ExUnit.Case, async: true

  alias NeonPerceptron.NetworkState

  @topology %{
    layers: ["input", "hidden_0", "output"],
    sizes: %{"input" => 4, "hidden_0" => 3, "output" => 2}
  }

  describe "null/1" do
    test "creates zeroed state with correct shapes" do
      state = NetworkState.null(@topology)

      assert length(state.activations["input"]) == 4
      assert length(state.activations["hidden_0"]) == 3
      assert length(state.activations["output"]) == 2

      assert length(state.weights["dense_0"]) == 4 * 3
      assert length(state.weights["dense_1"]) == 3 * 2

      assert state.iteration == 0
      assert Enum.all?(state.activations["input"], &(&1 == 0.0))
      assert Enum.all?(state.weights["dense_0"], &(&1 == 0.0))
    end

    test "topology is preserved" do
      state = NetworkState.null(@topology)
      assert state.topology == @topology
    end
  end

  describe "activation_for_node/3" do
    test "returns the correct activation" do
      state = %NetworkState{
        activations: %{"input" => [0.1, 0.2, 0.3, 0.4]},
        topology: @topology
      }

      assert NetworkState.activation_for_node(state, "input", 0) == 0.1
      assert NetworkState.activation_for_node(state, "input", 3) == 0.4
    end
  end

  describe "incoming_weights/3" do
    setup do
      state = %NetworkState{
        activations: %{
          "input" => [1.0, 0.0, 1.0, 0.0],
          "hidden_0" => [0.5, -0.3, 0.8],
          "output" => [0.6, 0.4]
        },
        weights: %{
          "dense_0" => [
            # row-major: input[0]→h[0], input[0]→h[1], input[0]→h[2],
            #            input[1]→h[0], input[1]→h[1], input[1]→h[2], ...
            0.1, 0.2, 0.3,
            0.4, 0.5, 0.6,
            0.7, 0.8, 0.9,
            1.0, 1.1, 1.2
          ],
          "dense_1" => [
            # hidden[0]→out[0], hidden[0]→out[1],
            # hidden[1]→out[0], hidden[1]→out[1],
            # hidden[2]→out[0], hidden[2]→out[1]
            0.3, 0.4,
            0.5, 0.6,
            0.7, 0.8
          ]
        },
        topology: @topology
      }

      [state: state]
    end

    test "returns empty list for input layer", %{state: state} do
      assert NetworkState.incoming_weights(state, "input", 0) == []
    end

    test "returns weights from input to hidden node", %{state: state} do
      weights = NetworkState.incoming_weights(state, "hidden_0", 0)
      assert weights == [0.1, 0.4, 0.7, 1.0]
    end

    test "returns weights from hidden to output node", %{state: state} do
      weights = NetworkState.incoming_weights(state, "output", 1)
      assert weights == [0.4, 0.6, 0.8]
    end
  end

  describe "outgoing_weights/3" do
    setup do
      state = %NetworkState{
        activations: %{
          "input" => [1.0, 0.0, 1.0, 0.0],
          "hidden_0" => [0.5, -0.3, 0.8],
          "output" => [0.6, 0.4]
        },
        weights: %{
          "dense_0" => [
            0.1, 0.2, 0.3,
            0.4, 0.5, 0.6,
            0.7, 0.8, 0.9,
            1.0, 1.1, 1.2
          ],
          "dense_1" => [
            0.3, 0.4,
            0.5, 0.6,
            0.7, 0.8
          ]
        },
        topology: @topology
      }

      [state: state]
    end

    test "returns empty list for output layer", %{state: state} do
      assert NetworkState.outgoing_weights(state, "output", 0) == []
    end

    test "returns weights from input node to hidden layer", %{state: state} do
      weights = NetworkState.outgoing_weights(state, "input", 0)
      assert weights == [0.1, 0.2, 0.3]
    end

    test "returns weights from hidden node to output layer", %{state: state} do
      weights = NetworkState.outgoing_weights(state, "hidden_0", 1)
      assert weights == [0.5, 0.6]
    end
  end

  describe "incoming_contributions/3" do
    test "returns weighted activation contributions" do
      state = %NetworkState{
        activations: %{
          "input" => [1.0, 0.5],
          "output" => [0.8]
        },
        weights: %{
          "dense_0" => [0.3, 0.7]
        },
        topology: %{
          layers: ["input", "output"],
          sizes: %{"input" => 2, "output" => 1}
        }
      }

      contributions = NetworkState.incoming_contributions(state, "output", 0)

      assert contributions == [
               {0.3, 1.0, 0.3},
               {0.7, 0.5, 0.35}
             ]
    end

    test "returns empty list for input layer" do
      state = NetworkState.null(@topology)
      assert NetworkState.incoming_contributions(state, "input", 0) == []
    end
  end
end
