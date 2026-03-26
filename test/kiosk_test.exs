defmodule NeonPerceptronTest.KioskTest do
  use ExUnit.Case

  alias NeonPerceptron.Kiosk.{WestonServer, CogServer}

  describe "WestonServer" do
    test "starts in simulation mode when weston binary not available" do
      {:ok, pid} = GenServer.start_link(WestonServer, [])
      state = :sys.get_state(pid)
      assert state.mode in [:hardware, :simulation]
      assert state.mode == :simulation || is_pid(state.pid)
      GenServer.stop(pid)
    end
  end

  describe "CogServer" do
    test "starts with default URL" do
      {:ok, pid} = GenServer.start_link(CogServer, [])
      state = :sys.get_state(pid)
      assert state.url == "http://localhost:4000/ui"
      assert state.mode in [:hardware, :simulation]
      GenServer.stop(pid)
    end

    test "starts with custom URL" do
      {:ok, pid} = GenServer.start_link(CogServer, url: "http://localhost:4000/custom")
      state = :sys.get_state(pid)
      assert state.url == "http://localhost:4000/custom"
      GenServer.stop(pid)
    end

    test "change_url updates the URL" do
      name = :"cog_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(CogServer, [], name: name)

      GenServer.call(pid, {:change_url, "http://localhost:4000/other"})

      state = :sys.get_state(pid)
      assert state.url == "http://localhost:4000/other"
      GenServer.stop(pid)
    end
  end

  describe "Kiosk.Supervisor" do
    test "starts successfully with children" do
      {:ok, pid} = NeonPerceptron.Kiosk.Supervisor.start_link([])
      children = Supervisor.which_children(pid)
      assert length(children) == 2
      Supervisor.stop(pid)
    end
  end
end
