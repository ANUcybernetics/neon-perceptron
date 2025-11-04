defmodule NeonPerceptronTest.DisplayTest do
  use ExUnit.Case

  test "correctly replaces sublist" do
    original = [1, 2, 3, 4, 5, 6]
    expected = [1, 2, :a, :b, 5, 6]
    result = NeonPerceptron.Display.replace_sublist(original, 2, [:a, :b])
    assert result == expected
  end

  test "display initializes gracefully regardless of SPI availability" do
    # Start a display instance
    {:ok, display_pid} = GenServer.start_link(NeonPerceptron.Display, :ok)

    # Get the state to verify it initialized successfully
    state = :sys.get_state(display_pid)

    # Should be in either hardware or simulation mode
    assert state.mode in [:hardware, :simulation]

    # If in simulation mode, spi should be nil; if hardware, spi should be present
    if state.mode == :simulation do
      assert state.spi == nil
    else
      assert state.spi != nil
    end

    GenServer.stop(display_pid)
  end

  test "display handles update in simulation mode" do
    {:ok, display_pid} = GenServer.start_link(NeonPerceptron.Display, :ok)

    activations = %{
      input: List.duplicate(0.5, 7),
      dense_0: List.duplicate(0.5, 14),
      hidden_0: List.duplicate(0.5, 2),
      dense_1: List.duplicate(0.5, 20),
      output: List.duplicate(0.5, 10)
    }

    # This should not crash even in simulation mode
    GenServer.cast(display_pid, {:update, activations})

    # Give it time to process
    Process.sleep(10)

    # Process should still be alive
    assert Process.alive?(display_pid)

    GenServer.stop(display_pid)
  end

  test "set_activations works in simulation mode" do
    activations = %{
      input: List.duplicate(0.5, 7),
      dense_0: List.duplicate(0.5, 14),
      hidden_0: List.duplicate(0.5, 2),
      dense_1: List.duplicate(0.5, 20),
      output: List.duplicate(0.5, 10)
    }

    # Should not crash in simulation mode
    result = NeonPerceptron.Display.set_activations(nil, :simulation, activations)
    assert result == :ok
  end

  test "demo functions work in simulation mode" do
    # All demo functions should work in simulation mode without crashing
    assert NeonPerceptron.Display.breathe_demo(nil, :simulation) == :ok
    assert NeonPerceptron.Display.layer_demo(nil, :simulation) == :ok
    assert NeonPerceptron.Display.step_demo(nil, :simulation) == :ok
    assert NeonPerceptron.Display.set_one(nil, :simulation, 0, 1.0) == :ok
    assert NeonPerceptron.Display.set_all(nil, :simulation, 0.5) == :ok
  end
end
