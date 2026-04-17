defmodule NeonPerceptron.PythonBench do
  @moduledoc """
  Byte-for-byte Elixir port of Brendan's `bench_test.py` /
  `brendan-spi-test.py`. Diagnostic tool for TASK-23: lets us compare
  a known-working Python reference against our `Chain`/`Board`
  abstractions on the same Nerves hardware, without needing to ship
  Python on the Nerves rootfs.

  Drives a SINGLE TLC5947 chip on `:main` (the first chip in the
  chain, MOSI-side). Packs bytes exactly the way Brendan's Python
  does. No gamma correction, no reversal, no chain-wide rendering.

  ## Usage

      # Stop the main app's Chain on :main first so we don't race
      # for the SPI bus and GPIO 18. pause_ticker is not enough --- the
      # Chain GenServer still holds the handles.
      Supervisor.terminate_child(NeonPerceptron.Supervisor, {NeonPerceptron.Chain, :main})

      # Run the sweep (blocks the calling process)
      NeonPerceptron.PythonBench.run()
      # ctrl-C out of it

      # Restart Chain when done
      Supervisor.restart_child(NeonPerceptron.Supervisor, {NeonPerceptron.Chain, :main})

  ## Why this exists

  If this port flickers identically to `Chain.ex`: the flicker is
  chain-level (ribbon SI / power) and not an Elixir bug. If this is
  clean but `Chain.ex` flickers, the bug is in our abstraction ---
  audit `Board.encode/1` packing, the `Enum.reverse` in
  `Chain.render_and_send/2`, or gamma correction.

  See `backlog/tasks/task-23 - Port-Brendans-Python-bench-test-to-Elixir-for-debugging.md`.
  """

  import Bitwise

  # Brendan's Python config, verbatim where possible.
  @spi_device "spidev1.0"
  @spi_speed_hz 10_000_000
  @xlat_gpio "GPIO18"
  @pwm_max 4095
  @num_channels 24

  # PWM sweep parameters from brendan-spi-test.py lines 77-100.
  @initial_rgb %{r: 2048, g: 2048, b: 2048}
  @deltas %{r: 384, g: 221, b: 140}
  @sweep_hi 3700
  @sweep_lo 400
  @offset 3800

  # Frame rate: Python uses `time.sleep(0.1)` (10 Hz). Match that.
  @frame_ms 100

  @doc """
  Run the RGB sweep. Blocks the calling process; interrupt with
  Ctrl-C or `Process.exit(self(), :kill)` from another shell.
  """
  def run do
    {:ok, spi} = Circuits.SPI.open(@spi_device, speed_hz: @spi_speed_hz, mode: 0)
    {:ok, xlat} = Circuits.GPIO.open(@xlat_gpio, :output, initial_value: 0)

    state = %{
      spi: spi,
      xlat: xlat,
      rgb: @initial_rgb,
      deltas: @deltas
    }

    loop(state)
  end

  @doc """
  Pack + transfer + XLAT-pulse a 24-element PWM value list. Exposed
  so it can be called directly for one-shot tests.
  """
  def set_leds(spi, xlat, led_array) when length(led_array) == @num_channels do
    buffer = pack(led_array)
    Circuits.SPI.transfer!(spi, buffer)

    # Brendan pulses XLAT HIGH, sleeps 1 µs, LOW. BEAM's finest
    # sleep resolution is ~1 ms via :timer.sleep, but two back-to-back
    # Circuits.GPIO.write calls already take longer than 1 µs, so
    # :timer.sleep/1 is unnecessary --- we match his intent by just
    # doing the two GPIO writes.
    Circuits.GPIO.write(xlat, 1)
    Circuits.GPIO.write(xlat, 0)
    :ok
  end

  # Byte-for-byte port of brendan-spi-test.py's `set_leds` packing
  # loop (lines 44-63). Produces a 36-byte buffer for one TLC5947.
  #
  # Python reference:
  #
  #     buffer = [0] * 36
  #     byte_idx = 35
  #     for i in range(0, 23, 2):
  #         val1 = min(led_array[i], 4096)
  #         val2 = min(led_array[i+1], 4096)
  #         buffer[byte_idx]   = (val1 & 0xFF)
  #         buffer[byte_idx-1] = ((val1 >> 8) & 0x0F) | ((val2 << 4) & 0xF0)
  #         buffer[byte_idx-2] = (val2 >> 4) & 0xFF
  #         byte_idx -= 3
  defp pack(leds) do
    # Python iterates i = 0, 2, 4, ..., 22 (pairs of channels), writing
    # into the buffer from the tail backward. Same effect in Elixir:
    # reduce over [{0,1}, {2,3}, ..., {22,23}] and build up the 36-byte
    # buffer via a list of bytes in wire-order (byte 0 first).
    #
    # wire byte index (Python i=22 pair writes buffer[2..0], i.e. wire
    # bytes 0, 1, 2). Python i=0 pair writes buffer[35..33], i.e. wire
    # bytes 33, 34, 35.
    #
    # So channel pair (i, i+1) with i=22 goes to wire bytes 0-2, pair
    # with i=0 goes to wire bytes 33-35.
    #
    # Order on wire (byte 0 first): ch23-ch22 triplet, ch21-ch20
    # triplet, ..., ch1-ch0 triplet.
    22..0//-2
    |> Enum.flat_map(fn i ->
      val1 = min(Enum.at(leds, i), @pwm_max)
      val2 = min(Enum.at(leds, i + 1), @pwm_max)

      # Byte layout for each pair (wire-order: b2, b1, b0):
      #   b2 = val2 >> 4 & 0xFF   (upper 8 bits of val2)
      #   b1 = (val1 >> 8 & 0x0F) | (val2 << 4 & 0xF0)
      #   b0 = val1 & 0xFF        (lower 8 bits of val1)
      [
        val2 >>> 4 &&& 0xFF,
        val1 >>> 8 &&& 0x0F ||| val2 <<< 4 &&& 0xF0,
        val1 &&& 0xFF
      ]
    end)
    |> :erlang.list_to_binary()
  end

  defp loop(state) do
    %{r: r, g: g, b: b} = state.rgb

    leds =
      List.duplicate(0, @num_channels)
      |> List.replace_at(23, r)
      |> List.replace_at(20, @offset - r)
      |> List.replace_at(22, g)
      |> List.replace_at(19, @offset - g)
      |> List.replace_at(21, b)
      |> List.replace_at(18, @offset - b)

    set_leds(state.spi, state.xlat, leds)

    Process.sleep(@frame_ms)
    {rgb, deltas} = step_rgb(state.rgb, state.deltas)
    loop(%{state | rgb: rgb, deltas: deltas})
  end

  defp step_rgb(%{r: r, g: g, b: b}, %{r: dr, g: dg, b: db}) do
    {r1, dr1} = bounce(r, dr)
    {g1, dg1} = bounce(g, dg)
    {b1, db1} = bounce(b, db)
    {%{r: r1, g: g1, b: b1}, %{r: dr1, g: dg1, b: db1}}
  end

  defp bounce(val, delta) do
    next = val + delta
    if next > @sweep_hi or next < @sweep_lo, do: {next, -delta}, else: {next, delta}
  end
end
