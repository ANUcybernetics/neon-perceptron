defmodule NeonPerceptron.Builds.TestPattern do
  @moduledoc """
  Hardware test build: blinks both big LEDs on every chip across both SPI
  chains, with a hue that varies along each chain's length. No neural
  network, no training --- just a blink test to verify SPI wiring.

  A chip that stays dark, or flashes out of sync with its neighbours,
  points at a bad solder joint, ribbon connector, or TLC5947 in that
  chain position.
  """

  alias NeonPerceptron.Board

  @blink_period_ms 1000

  def topology, do: %{layers: [], sizes: %{}}
  def trainer_config, do: nil

  def extra_children do
    ids = Enum.map(chain_configs(), & &1.id)
    [{__MODULE__.Ticker, ids}]
  end

  @doc """
  Two chains mirroring the Builds.V2 wiring, so a passing test pattern
  directly validates V2's SPI setup.
  """
  def chain_configs do
    [
      chain(:input_left, "spidev0.0", 2, "GPIO8"),
      chain(:main, "spidev1.0", 9, "GPIO18")
    ]
  end

  defp chain(id, spi_device, board_count, xlat_gpio) do
    %{
      id: id,
      spi_device: spi_device,
      xlat_gpio: xlat_gpio,
      boards: List.duplicate({"_", 0}, board_count),
      render_fn: nil,
      render_frame_fn: fn _state -> render_frame(board_count) end
    }
  end

  @doc """
  Render one full chain: all chips on (hue varying along the chain) or
  all chips off, depending on the blink phase.
  """
  def render_frame(board_count) do
    on? = rem(div(System.system_time(:millisecond), @blink_period_ms), 2) == 0

    Enum.flat_map(0..(board_count - 1), fn index ->
      hue = index / max(board_count, 1) * 360
      {r, g, b} = if on?, do: hsv_to_rgb(hue), else: {0.0, 0.0, 0.0}

      Board.blank()
      |> List.replace_at(Board.front_red(), r)
      |> List.replace_at(Board.front_green(), g)
      |> List.replace_at(Board.front_blue(), b)
      |> List.replace_at(Board.rear_red(), r)
      |> List.replace_at(Board.rear_green(), g)
      |> List.replace_at(Board.rear_blue(), b)
    end)
  end

  @doc false
  def hsv_to_rgb(h) do
    h_prime = h / 60
    c = 1.0
    x = c * (1 - abs(fmod(h_prime, 2) - 1))

    case trunc(h_prime) do
      0 -> {c, x, 0.0}
      1 -> {x, c, 0.0}
      2 -> {0.0, c, x}
      3 -> {0.0, x, c}
      4 -> {x, 0.0, c}
      _ -> {c, 0.0, x}
    end
  end

  defp fmod(a, b), do: a - Float.floor(a / b) * b

  defmodule Ticker do
    @moduledoc false
    use GenServer

    @frame_interval 33

    def start_link(chain_ids) do
      GenServer.start_link(__MODULE__, chain_ids, name: __MODULE__)
    end

    @impl true
    def init(chain_ids) do
      Process.send_after(self(), :tick, @frame_interval)
      {:ok, %{chain_ids: chain_ids}}
    end

    @impl true
    def handle_info(:tick, state) do
      for id <- state.chain_ids do
        NeonPerceptron.Chain.update(id, nil)
      end

      Process.send_after(self(), :tick, @frame_interval)
      {:noreply, state}
    end
  end
end
