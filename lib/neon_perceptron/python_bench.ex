defmodule NeonPerceptron.PythonBench do
  @moduledoc """
  Byte-for-byte Elixir port of Brendan's `bench_test.py` /
  `brendan-spi-test.py`. Diagnostic tool for TASK-23: lets us compare
  a known-working Python reference against our `Chain`/`Board`
  abstractions on the same Nerves hardware, without needing to ship
  Python on the Nerves rootfs.

  Drives chip 0 of `:main` (MOSI-side) with the RGB sweep. Packs
  bytes for that chip exactly the way Brendan's Python does --- no
  gamma correction, no reversal, no chain-wide rendering --- and
  prepends 8 chips' worth of zeros so chips 1-8 latch dark each
  frame (otherwise they cascade random shifts and visually drown out
  chip 0; see comment on `@chain_chips`).

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
  audit `Board.encode/1` packing, the `Enum.reverse` in `Chain`'s
  update path, or gamma correction.

  See `backlog/tasks/task-23 - Port-Brendans-Python-bench-test-to-Elixir-for-debugging.md`.
  """

  import Bitwise

  # Brendan's Python config, verbatim where possible.
  #
  # Two deliberate deviations from `brendan-spi-test.py`, matching the
  # SPI envelope `Chain.ex` uses for `:main` so PythonBench and
  # Chain.ex differ only in Elixir-side abstractions (gamma, reverse,
  # chain rendering), not in SPI timing:
  #
  # 1. `@spi_speed_hz` is 1 MHz, not Brendan's 10 MHz. Brendan tests
  #    on a single chip; we drive a 9-chip ribbon-linked chain off
  #    SPI1. Chain.ex bench-tested 25 MHz failing past chip 3 on this
  #    chain (commit 6993b9f's predecessor) and settled on 1 MHz.
  # 2. We busy-wait 100 µs between `Circuits.SPI.transfer!` and the
  #    XLAT pulse, as `Chain` does. See `@xlat_delay_us` there for why
  #    that wait is a precaution rather than a fix.
  @spi_device "spidev1.0"
  @spi_speed_hz 1_000_000
  @xlat_gpio "GPIO18"
  @xlat_delay_us 100
  @pwm_max 4095
  @num_channels 24

  # `:main` has 9 daisy-chained TLC5947s. Chip 0 is closest to MOSI;
  # chip 8 is at chain end. XLAT is global, so all chips latch
  # simultaneously. If we send only 36 bytes (one chip's worth) into a
  # 9-chip chain, chip 0 gets correct new data, but chips 1-8 each
  # latch a snapshot of their upstream neighbour's previous GS register
  # contents --- they cascade random shifts every frame and strobe
  # visibly, making it look like chip 0 itself is flickering. To
  # observe chip 0 in isolation we prepend 8 chips' worth of zeros so
  # chips 1-8 latch all-zero (dark) each frame.
  @chain_chips 9

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
    # Bytes for chip 8 (farthest from MOSI) clock out first, bytes for
    # chip 0 last. So zeros for chips 1..8 first, then chip 0 RGB last.
    blanks = :binary.copy(<<0>>, (@chain_chips - 1) * 36)
    buffer = blanks <> pack(led_array)
    Circuits.SPI.transfer!(spi, buffer)
    busy_wait_us(@xlat_delay_us)
    Circuits.GPIO.write(xlat, 1)
    Circuits.GPIO.write(xlat, 0)
    :ok
  end

  defp busy_wait_us(us) do
    deadline = System.monotonic_time(:microsecond) + us
    spin_until(deadline)
  end

  defp spin_until(deadline) do
    if System.monotonic_time(:microsecond) < deadline do
      spin_until(deadline)
    else
      :ok
    end
  end

  @doc """
  Pack a 24-element list of 12-bit PWM values into a 36-byte TLC5947
  SPI buffer, byte-for-byte equivalent to `brendan-spi-test.py`'s
  `set_leds` packing loop (lines 44-63):

      buffer = [0] * 36
      byte_idx = 35
      for i in range(0, 23, 2):
          val1 = min(led_array[i], 4096)
          val2 = min(led_array[i+1], 4096)
          buffer[byte_idx]   = (val1 & 0xFF)
          buffer[byte_idx-1] = ((val1 >> 8) & 0x0F) | ((val2 << 4) & 0xF0)
          buffer[byte_idx-2] = (val2 >> 4) & 0xFF
          byte_idx -= 3

  Public so the equivalence test can hit it without opening SPI.
  """
  def pack(leds) when length(leds) == @num_channels do
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
        (val1 >>> 8 &&& 0x0F) ||| (val2 <<< 4 &&& 0xF0),
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
