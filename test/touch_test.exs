defmodule NeonPerceptron.TouchTest do
  use ExUnit.Case

  test "initialises with nil device when hardware unavailable" do
    {:ok, pid} = GenServer.start_link(NeonPerceptron.Touch, [])

    state = :sys.get_state(pid)
    assert state.device == nil
    assert state.touching == false

    GenServer.stop(pid)
  end

  test "processes touch down event" do
    {:ok, pid} = GenServer.start_link(NeonPerceptron.Touch, callback: self())

    send(pid, {:input_event, "/dev/input/event0", [
      {:ev_abs, :abs_mt_position_x, 100},
      {:ev_abs, :abs_mt_position_y, 200},
      {:ev_key, :btn_touch, 1},
      {:ev_syn, :syn_report, 0}
    ]})

    assert_receive {:touch, :down, {100, 200}}
    assert_receive {:touch, :move, {100, 200}}

    state = :sys.get_state(pid)
    assert state.touching == true
    assert state.x == 100
    assert state.y == 200

    GenServer.stop(pid)
  end

  test "processes touch move events" do
    {:ok, pid} = GenServer.start_link(NeonPerceptron.Touch, callback: self())

    send(pid, {:input_event, "/dev/input/event0", [
      {:ev_abs, :abs_mt_position_x, 100},
      {:ev_abs, :abs_mt_position_y, 200},
      {:ev_key, :btn_touch, 1},
      {:ev_syn, :syn_report, 0}
    ]})

    assert_receive {:touch, :down, _}
    assert_receive {:touch, :move, _}

    send(pid, {:input_event, "/dev/input/event0", [
      {:ev_abs, :abs_mt_position_x, 150},
      {:ev_abs, :abs_mt_position_y, 250},
      {:ev_syn, :syn_report, 0}
    ]})

    assert_receive {:touch, :move, {150, 250}}

    GenServer.stop(pid)
  end

  test "processes touch up event" do
    {:ok, pid} = GenServer.start_link(NeonPerceptron.Touch, callback: self())

    send(pid, {:input_event, "/dev/input/event0", [
      {:ev_key, :btn_touch, 1},
      {:ev_syn, :syn_report, 0}
    ]})

    assert_receive {:touch, :down, _}

    send(pid, {:input_event, "/dev/input/event0", [
      {:ev_key, :btn_touch, 0},
      {:ev_syn, :syn_report, 0}
    ]})

    assert_receive {:touch, :up, {0, 0}}

    state = :sys.get_state(pid)
    assert state.touching == false

    GenServer.stop(pid)
  end

  test "does not emit move when not touching" do
    {:ok, pid} = GenServer.start_link(NeonPerceptron.Touch, callback: self())

    send(pid, {:input_event, "/dev/input/event0", [
      {:ev_abs, :abs_mt_position_x, 100},
      {:ev_abs, :abs_mt_position_y, 200},
      {:ev_syn, :syn_report, 0}
    ]})

    refute_receive {:touch, :move, _}, 50

    GenServer.stop(pid)
  end

  test "ignores unknown event types" do
    {:ok, pid} = GenServer.start_link(NeonPerceptron.Touch, callback: self())

    send(pid, {:input_event, "/dev/input/event0", [
      {:ev_msc, :msc_scan, 42},
      {:ev_syn, :syn_report, 0}
    ]})

    refute_receive {:touch, _, _}, 50
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end
end
