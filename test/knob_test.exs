defmodule NeonPerceptron.KnobTest do
  use ExUnit.Case

  test "knob initializes with nil pins when GPIO unavailable" do
    {:ok, knob_pid} = GenServer.start_link(NeonPerceptron.Knob, [])
    
    state = :sys.get_state(knob_pid)
    
    # On host, GPIO should be unavailable, so pins should be nil
    assert state.pin_a == nil
    assert state.pin_b == nil
    assert is_integer(state.position)
    
    GenServer.stop(knob_pid)
  end

  test "knob handles GPIO interrupts gracefully when hardware unavailable" do
    {:ok, knob_pid} = GenServer.start_link(NeonPerceptron.Knob, [])
    
    # Simulate GPIO interrupts when hardware is not available
    send(knob_pid, {:circuits_gpio, "GPIO17", 123456, 1})
    send(knob_pid, {:circuits_gpio, "GPIO18", 123457, 0})
    
    # Give it time to process
    Process.sleep(10)
    
    # Process should still be alive and not have crashed
    assert Process.alive?(knob_pid)
    
    # Position should be readable
    position = GenServer.call(knob_pid, :position)
    assert is_integer(position)
    
    GenServer.stop(knob_pid)
  end

  test "position/0 returns integer when hardware unavailable" do
    {:ok, knob_pid} = GenServer.start_link(NeonPerceptron.Knob, [])
    
    position = GenServer.call(knob_pid, :position)
    assert is_integer(position)
    
    GenServer.stop(knob_pid)
  end
end
