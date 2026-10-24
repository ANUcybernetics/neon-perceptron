defmodule NeonPerceptron.LabTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Board, Chain, FakeCircuits, Lab}

  setup context do
    # Lab is the application's singleton; start every test from scratch.
    :ok = Lab.release()
    FakeCircuits.install(readback: Map.get(context, :readback, :echo))
    start_chain(:lab_a, "spidev7.0", "GPIO8", 2)
    start_chain(:lab_b, "spidev7.1", "GPIO18", 1)
    :ok
  end

  defp start_chain(id, spi_device, xlat_gpio, chips) do
    config = %{
      id: id,
      spi_device: spi_device,
      xlat_gpio: xlat_gpio,
      boards: List.duplicate({"_", 0}, chips),
      render_fn: nil,
      render_frame_fn: & &1,
      pubsub_subscribe: false
    }

    start_supervised!({Chain, config}, id: id)
    assert_receive {:gpio_open, ^xlat_gpio, :output, 0}
  end

  defp wire(levels), do: levels |> Enum.reverse() |> Board.pack()

  defp drain(bus, acc \\ []) do
    receive do
      {:spi, ^bus, data} -> drain(bus, [{:spi, data} | acc])
      {:gpio, "GPIO8", value} -> drain(bus, [{:xlat, value} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "fill latches every chain and holds it against the build's updates" do
    assert :ok = Lab.fill(4095)

    data = wire(List.duplicate(4095, 48))
    assert_receive {:spi, "spidev7.0", ^data}
    assert_receive {:gpio, "GPIO8", 1}
    assert_receive {:spi, "spidev7.1", _}
    assert Chain.status(:lab_a).held

    Chain.update_sync(:lab_a, List.duplicate(0.5, 48))
    refute_receive {:spi, "spidev7.0", _}, 50

    assert :ok = Lab.release()
    refute Chain.status(:lab_a).held
  end

  test "light_one lights a single channel and darkens every other chain" do
    assert :ok = Lab.light_one(:lab_a, 1, 18, 2048)

    expected = List.duplicate(0, 48) |> List.replace_at(24 + 18, 2048)
    data = wire(expected)
    assert_receive {:spi, "spidev7.0", ^data}
    dark = wire(List.duplicate(0, 24))
    assert_receive {:spi, "spidev7.1", ^dark}

    assert {:error, {:bad_chip, 2}} = Lab.light_one(:lab_a, 2, 18, 2048)
    assert {:error, {:bad_level, 4096}} = Lab.light_one(:lab_a, 0, 18, 4096)
    assert {:error, {:unknown_chain, :nope}} = Lab.light_one(:nope, 0, 18, 1)
  end

  test "relatch re-sends and latches the same frame at the requested rate" do
    :ok = Lab.fill(:lab_a, 1000)
    _ = drain("spidev7.0")

    :ok = Lab.start(%{kind: :relatch, rate_hz: 50, chains: [:lab_a]})
    Process.sleep(210)
    assert %{kind: :relatch, ticks: ticks} = Lab.stop()

    events = drain("spidev7.0")
    data = wire(List.duplicate(1000, 48))
    assert ticks in 8..12
    assert Enum.count(events, &(&1 == {:spi, data})) == ticks
    assert Enum.count(events, &(&1 == {:xlat, 1})) == ticks
  end

  test "jitter moves ticks off their even spacing, within half a period" do
    :ok = Lab.fill(:lab_a, 1000)

    assert {:error, {:bad_jitter, 10}} =
             Lab.start(%{kind: :relatch, rate_hz: 50, jitter_ms: 10, chains: [:lab_a]})

    _ = drain("spidev7.0")
    :ok = Lab.start(%{kind: :relatch, rate_hz: 50, jitter_ms: 8, chains: [:lab_a]})
    arrivals = for _ <- 1..10, do: receive_spi_time("spidev7.0")
    Lab.stop()

    gaps = arrivals |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
    assert Enum.max(gaps) - Enum.min(gaps) > 4
  end

  defp receive_spi_time(bus) do
    receive do
      {:spi, ^bus, _data} -> System.monotonic_time(:millisecond)
    after
      500 -> flunk("no transfer on #{bus}")
    end
  end

  test "reshift re-sends the frame without latching it" do
    :ok = Lab.fill(:lab_a, 1000)
    _ = drain("spidev7.0")

    :ok = Lab.start(%{kind: :reshift, rate_hz: 50, chains: [:lab_a]})
    Process.sleep(110)
    assert %{ticks: ticks} = Lab.stop()

    events = drain("spidev7.0")
    assert ticks >= 3
    assert Enum.count(events, &match?({:spi, _}, &1)) == ticks
    refute Enum.any?(events, &match?({:xlat, _}, &1))
  end

  test "wobble varies one channel around its level" do
    :ok = Lab.light_one(:lab_a, 0, 5, 2000)
    _ = drain("spidev7.0")

    spec = %{
      kind: :wobble,
      chain: :lab_a,
      chip: 0,
      channel: 5,
      depth: 0.05,
      freq_hz: 5,
      rate_hz: 100
    }

    :ok = Lab.start(spec)
    Process.sleep(210)
    Lab.stop()

    levels =
      for {:spi, data} <- drain("spidev7.0") do
        # The wire carries chip 1 first, then chip 0 from channel 23 down.
        <<_chip1::binary-size(36), _::bitstring-size(18 * 12), level::12, _::bitstring>> = data
        level
      end

    assert length(levels) >= 10
    assert Enum.all?(levels, &(&1 in 1900..2100))
    assert Enum.max(levels) - Enum.min(levels) > 100

    assert {:error, :dark_channel} = Lab.start(%{spec | channel: 6})
  end

  test "blank-pulsed conditions need a BLANK GPIO" do
    :ok = Lab.fill(1000)

    assert {:error, :no_blank_gpio} =
             Lab.start(%{kind: :relatch, rate_hz: 30, latch: :blank_pulse, chains: [:lab_a]})

    :ok = Lab.configure(:lab_a, blank_gpio: "GPIO17")
    :ok = Lab.start(%{kind: :relatch, rate_hz: 30, latch: :blank_pulse, chains: [:lab_a]})
    assert_receive {:gpio, "GPIO17", 1}, 200
    Lab.stop()
  end

  test "a condition whose shifts fail stops, and stop/0 says why" do
    :ok = Lab.fill(1000)
    :ok = Lab.configure(:lab_a, blank_gpio: "GPIO17")
    :ok = Lab.start(%{kind: :relatch, rate_hz: 50, latch: :blank_pulse, chains: [:lab_a]})

    :ok = Lab.configure(:lab_a, blank_gpio: nil)
    Process.sleep(60)

    assert {:error, {:condition_failed, {:relatch, :no_blank_gpio}}} = Lab.stop()
    assert {:error, :not_running} = Lab.stop()
  end

  test "conditions that can't run as asked are refused" do
    :ok = Lab.light_one(:lab_a, 0, 5, 4000)

    assert {:error, {:bad_condition, _}} = Lab.start(%{kind: :relatch, rate_hz: 1.0e-12})

    assert {:error, {:bad_chains, :lab_a}} =
             Lab.start(%{kind: :relatch, rate_hz: 30, chains: :lab_a})

    wobble = %{kind: :wobble, chain: :lab_a, chip: 0, channel: 5, depth: 0.05}
    assert {:error, :wobble_clips} = Lab.start(wobble)

    assert {:error, :bad_rate} =
             Lab.start(%{wobble | depth: 0.01} |> Map.merge(%{freq_hz: 20, rate_hz: 30}))

    assert :ok = Lab.start(%{wobble | depth: 0.01})
    assert %{kind: :wobble} = Lab.stop()
  end

  test "probe_gpio drives a pin until it is released as an input" do
    assert :ok = Lab.probe_gpio("GPIO22", 1)
    assert_receive {:gpio_open, "GPIO22", :output, 1}
    assert :ok = Lab.probe_gpio("GPIO22", 0)
    assert_receive {:gpio, "GPIO22", 0}
    assert %{gpios: ["GPIO22"]} = Lab.status()

    assert :ok = Lab.release_gpio("GPIO22")
    assert_receive {:gpio_close, "GPIO22"}
    assert_receive {:gpio_open, "GPIO22", :input, 0}
    assert {:error, :not_driven} = Lab.release_gpio("GPIO22")
  end

  test "readback finds every frame intact when MISO echoes the chain" do
    assert %{frames: 8, matched: 8, bit_errors: 0} = Lab.readback(:lab_a, 8)
  end

  @tag readback: {:flip, 0}
  test "readback counts corrupted bits" do
    assert %{frames: 8, matched: 0, bit_errors: 8} = Lab.readback(:lab_a, 8)
  end

  test "reply inspects as one LAB line with a JSON envelope" do
    assert inspect(Lab.reply(%{ticks: 3, kind: :relatch})) ==
             ~s(LAB {"ok":{"kind":"relatch","ticks":3}})

    assert inspect(Lab.reply({:error, :no_frames})) == ~s(LAB {"error":":no_frames"})
  end
end
