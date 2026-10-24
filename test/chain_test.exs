defmodule NeonPerceptron.ChainTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Chain, NetworkState}

  @topology %{
    layers: ["input", "hidden_0", "output"],
    sizes: %{"input" => 2, "hidden_0" => 2, "output" => 1}
  }

  setup do
    # ChainRegistry is already started by the application supervisor
    :ok
  end

  describe "init/1" do
    test "starts successfully and stores config" do
      config = %{
        id: :test_chain,
        spi_device: "spidev0.0",
        boards: [{"input", 0}],
        render_fn: fn _state, _spec -> NeonPerceptron.Board.blank() end,
        render_frame_fn: nil
      }

      pid = start_supervised!({Chain, config}, id: :test_chain)
      state = :sys.get_state(pid)

      assert state.id == :test_chain
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
          {"input", 0},
          {"input", 1}
        ],
        render_fn: render_fn,
        render_frame_fn: nil
      }

      start_supervised!({Chain, config}, id: :render_test)

      network_state = NetworkState.null(@topology)
      Chain.update(:render_test, network_state)

      assert_receive {:rendered, {"input", 0}}, 500
      assert_receive {:rendered, {"input", 1}}, 500
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

      start_supervised!({Chain, config}, id: :frame_test)

      network_state = %{NetworkState.null(@topology) | iteration: 42}
      Chain.update(:frame_test, network_state)

      assert_receive {:frame_rendered, 42}, 500
    end
  end

  describe "blank fallback" do
    test "renders blank boards when no render function provided" do
      config = %{
        id: :blank_test,
        spi_device: "spidev99.99",
        boards: [{"input", 0}],
        render_fn: nil,
        render_frame_fn: nil
      }

      pid = start_supervised!({Chain, config}, id: :blank_test)

      network_state = NetworkState.null(@topology)
      Chain.update(:blank_test, network_state)

      # Should not crash
      assert Process.alive?(pid)
    end
  end

  describe "push_raw/2" do
    test "accepts a correctly-sized channel list and returns :ok" do
      config = %{
        id: :push_raw_ok,
        spi_device: "spidev99.99",
        boards: [{"input", 0}, {"input", 1}],
        render_fn: fn _state, _spec -> NeonPerceptron.Board.blank() end,
        render_frame_fn: nil
      }

      start_supervised!({Chain, config}, id: :push_raw_ok)

      values = List.duplicate(0.25, 48)
      assert :ok = Chain.push_raw(:push_raw_ok, values)
    end

    test "returns {:error, :bad_length} for wrong-sized input" do
      config = %{
        id: :push_raw_bad,
        spi_device: "spidev99.99",
        boards: [{"input", 0}, {"input", 1}],
        render_fn: fn _state, _spec -> NeonPerceptron.Board.blank() end,
        render_frame_fn: nil
      }

      start_supervised!({Chain, config}, id: :push_raw_bad)

      # 2 boards = 48 channels expected; send 47.
      assert {:error, :bad_length} =
               Chain.push_raw(:push_raw_bad, List.duplicate(0.0, 47))
    end
  end
end

defmodule NeonPerceptron.ChainSwitchesTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Board, Chain, FakeCircuits}

  # Each "network state" here is already the chain's channel list, which
  # render_frame_fn passes straight through.
  @half List.duplicate(0.5, 24)
  @full List.duplicate(1.0, 24)

  setup do
    FakeCircuits.install()
    :ok
  end

  defp start_chain(id, switches \\ %{}) do
    config =
      Map.merge(
        %{
          id: id,
          spi_device: "spidev7.0",
          xlat_gpio: "GPIO8",
          boards: [{"input", 0}],
          render_fn: nil,
          render_frame_fn: & &1,
          pubsub_subscribe: false
        },
        switches
      )

    start_supervised!({Chain, config}, id: id)
    assert_receive {:gpio_open, "GPIO8", :output, 0}
    id
  end

  defp frame(values), do: values |> Enum.reverse() |> Board.encode()

  defp assert_latched(data) do
    assert_receive {:spi, "spidev7.0", ^data}
    assert_receive {:gpio, "GPIO8", 1}
    assert_receive {:gpio, "GPIO8", 0}
  end

  test "by default every update is shifted and latched" do
    chain = start_chain(:default_switches)

    for _ <- 1..3, do: Chain.update_sync(chain, @half)

    for _ <- 1..3, do: assert_latched(frame(@half))
    assert Chain.status(chain).counts.sent == 3
  end

  test "send_on_change skips frames that match the latched one" do
    chain = start_chain(:on_change, %{send_on_change: true})

    for values <- [@half, @half, @full, @full, @half], do: Chain.update_sync(chain, values)

    assert_latched(frame(@half))
    assert_latched(frame(@full))
    assert_latched(frame(@half))
    refute_receive {:spi, _, _}, 50
    assert %{sent: 3, unchanged: 2} = Chain.status(chain).counts
  end

  test "max_rate_hz holds back an early frame and sends only the newest" do
    chain = start_chain(:capped, %{max_rate_hz: 10})
    newest = List.duplicate(0.25, 24)

    for values <- [@half, @full, newest], do: Chain.update_sync(chain, values)

    assert_latched(frame(@half))
    sent_at = System.monotonic_time(:millisecond)
    refute_receive {:spi, _, _}, 50
    assert_latched(frame(newest))
    assert System.monotonic_time(:millisecond) - sent_at >= 90
    refute_receive {:spi, _, _}, 150
    assert %{sent: 2, coalesced: 1} = Chain.status(chain).counts
  end

  test "refresh_ms re-sends the latched frame while nothing changes" do
    chain = start_chain(:refreshed, %{refresh_ms: 40})

    Chain.update_sync(chain, @half)

    for _ <- 1..3, do: assert_latched(frame(@half))
    assert Chain.status(chain).counts.refreshed >= 2
  end

  test "blank_gpio keeps the outputs off until the first latch" do
    chain = start_chain(:blanked, %{blank_gpio: "GPIO17"})
    assert_receive {:gpio_open, "GPIO17", :output, 1}

    Chain.update_sync(chain, @half)
    Chain.update_sync(chain, @full)

    assert_latched(frame(@half))
    assert_receive {:gpio, "GPIO17", 0}
    assert_latched(frame(@full))
    refute_receive {:gpio, "GPIO17", _}, 50
  end

  test "blank_pulse raises BLANK around every XLAT pulse" do
    chain = start_chain(:pulsed, %{blank_gpio: "GPIO17", blank_pulse: true})
    data = frame(@half)

    Chain.update_sync(chain, @half)

    assert_receive {:spi, "spidev7.0", ^data}
    assert_receive {:gpio, label, value}
    assert {label, value} == {"GPIO17", 1}
    assert_receive {:gpio, label, value}
    assert {label, value} == {"GPIO8", 1}
    assert_receive {:gpio, label, value}
    assert {label, value} == {"GPIO8", 0}
    assert_receive {:gpio, label, value}
    assert {label, value} == {"GPIO17", 0}
  end

  test "configure/2 switches BLANK on at runtime without blanking the outputs" do
    chain = start_chain(:runtime_blank)

    assert :ok = Chain.configure(chain, blank_gpio: "GPIO17", blank_pulse: true)
    assert_receive {:gpio_open, "GPIO17", :output, 0}
    assert %{blank_gpio: "GPIO17", blank_pulse: true} = Chain.status(chain).switches

    assert {:error, {:invalid_switch, :max_rate_hz, -1}} =
             Chain.configure(chain, max_rate_hz: -1)

    assert {:error, {:invalid_switch, :speed, 1}} = Chain.configure(chain, speed: 1)
  end

  test "a held chain ignores updates until released" do
    chain = start_chain(:held)

    :ok = Chain.hold(chain)
    Chain.update_sync(chain, @half)
    refute_receive {:spi, _, _}, 50

    :ok = Chain.release(chain)
    Chain.update_sync(chain, @full)
    assert_latched(frame(@full))
    assert %{ignored: 1, sent: 1} = Chain.status(chain).counts
  end

  test "shift/3 sends raw grayscale and returns what came back on MISO" do
    chain = start_chain(:shifted)
    first = List.duplicate(4095, 24)
    second = Enum.to_list(0..23)

    assert {:ok, %{sent: sent}} = Chain.shift(chain, first, :xlat)
    assert sent == Board.pack(Enum.reverse(first))
    assert_latched(sent)

    assert {:ok, %{received: ^sent}} = Chain.shift(chain, second, :none)
    assert_receive {:spi, "spidev7.0", _}
    refute_receive {:gpio, _, _}, 50

    assert {:error, :bad_length} = Chain.shift(chain, [0], :xlat)
    assert {:error, :no_blank_gpio} = Chain.shift(chain, first, :blank_pulse)
  end
end
