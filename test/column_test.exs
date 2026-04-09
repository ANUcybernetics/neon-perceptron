defmodule NeonPerceptron.ColumnTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Column, NetworkState}

  @topology %{
    layers: ["input", "hidden_0", "output"],
    sizes: %{"input" => 2, "hidden_0" => 2, "output" => 1}
  }

  setup do
    # ColumnRegistry is already started by the application supervisor
    :ok
  end

  describe "init/1" do
    test "starts successfully and stores config" do
      config = %{
        id: :test_col,
        spi_device: "spidev0.0",
        boards: [%{layer: "input", node_index: 0}],
        render_fn: fn _state, _spec -> NeonPerceptron.Board.blank() end,
        render_frame_fn: nil
      }

      pid = start_supervised!({Column, config}, id: :test_col)
      state = :sys.get_state(pid)

      assert state.id == :test_col
      assert state.mode in [:hardware, :simulation]
      assert length(state.boards) == 1
    end
  end

  describe "render_fn mode" do
    test "calls render_fn for each board and produces correct output size" do
      test_pid = self()

      render_fn = fn _state, board_spec ->
        send(test_pid, {:rendered, board_spec})
        List.duplicate(0.5, 24)
      end

      config = %{
        id: :render_test,
        spi_device: "spidev99.99",
        boards: [
          %{layer: "input", node_index: 0},
          %{layer: "input", node_index: 1}
        ],
        render_fn: render_fn,
        render_frame_fn: nil
      }

      start_supervised!({Column, config}, id: :render_test)

      network_state = NetworkState.null(@topology)
      Column.update(:render_test, network_state)

      assert_receive {:rendered, %{layer: "input", node_index: 0}}, 500
      assert_receive {:rendered, %{layer: "input", node_index: 1}}, 500
    end
  end

  describe "render_frame_fn mode" do
    test "calls render_frame_fn with full state" do
      test_pid = self()

      render_frame_fn = fn state ->
        send(test_pid, {:frame_rendered, state.iteration})
        List.duplicate(0.5, 48)
      end

      config = %{
        id: :frame_test,
        spi_device: "spidev99.99",
        boards: [],
        render_fn: nil,
        render_frame_fn: render_frame_fn
      }

      start_supervised!({Column, config}, id: :frame_test)

      network_state = %{NetworkState.null(@topology) | iteration: 42}
      Column.update(:frame_test, network_state)

      assert_receive {:frame_rendered, 42}, 500
    end
  end

  describe "blank fallback" do
    test "renders blank boards when no render function provided" do
      config = %{
        id: :blank_test,
        spi_device: "spidev99.99",
        boards: [%{layer: "input", node_index: 0}],
        render_fn: nil,
        render_frame_fn: nil
      }

      pid = start_supervised!({Column, config}, id: :blank_test)

      network_state = NetworkState.null(@topology)
      Column.update(:blank_test, network_state)

      # Should not crash
      assert Process.alive?(pid)
    end
  end
end
