defmodule NeonPerceptron.Builds.TestPattern do
  @moduledoc """
  Hardware test build: blinks both big LEDs on all 5 SPI columns, each with a
  different fully-saturated hue (evenly spaced around the colour wheel). No
  neural network, no training --- just a blink test to verify SPI wiring.
  """

  alias NeonPerceptron.Board

  @column_count 5
  @blink_period_ms 1000

  def topology, do: %{layers: [], sizes: %{}}
  def trainer_config, do: nil

  def extra_children do
    ids = Enum.map(column_configs(), & &1.id)
    [{__MODULE__.Ticker, ids}]
  end

  def column_configs do
    # TEST CONFIG: temporary board counts for bench testing (3 daisy-chained on
    # spidev0.0, 1 each on the rest). Restore to Build.V2 counts (2/2/3/3/3)
    # once hardware verification is complete.
    columns = [
      {:input_left, "spidev0.0", 3},
      {:input_right, "spidev0.1", 1},
      {:hidden_front, "spidev1.0", 1},
      {:hidden_rear, "spidev1.1", 1},
      {:output, "spidev1.2", 1}
    ]

    columns
    |> Enum.with_index()
    |> Enum.map(fn {{id, spi_device, board_count}, index} ->
      hue = index / @column_count * 360
      column(id, spi_device, board_count, hue)
    end)
  end

  defp column(id, spi_device, board_count, hue) do
    %{
      id: id,
      spi_device: spi_device,
      boards: List.duplicate(%{}, board_count),
      render_fn: nil,
      render_frame_fn: fn _state -> render_frame(board_count, hue) end
    }
  end

  def render_frame(board_count, hue) do
    on? = rem(div(System.system_time(:millisecond), @blink_period_ms), 2) == 0
    {r, g, b} = if on?, do: hsv_to_rgb(hue), else: {0.0, 0.0, 0.0}

    board =
      Board.blank()
      |> List.replace_at(Board.front_red(), r)
      |> List.replace_at(Board.front_green(), g)
      |> List.replace_at(Board.front_blue(), b)
      |> List.replace_at(Board.rear_red(), r)
      |> List.replace_at(Board.rear_green(), g)
      |> List.replace_at(Board.rear_blue(), b)

    List.duplicate(board, board_count) |> List.flatten()
  end

  @doc false
  def hsv_to_rgb(h) do
    h_prime = h / 60
    c = 1.0
    x = c * (1 - abs(fmod(h_prime, 2) - 1))

    {r, g, b} =
      case trunc(h_prime) do
        0 -> {c, x, 0.0}
        1 -> {x, c, 0.0}
        2 -> {0.0, c, x}
        3 -> {0.0, x, c}
        4 -> {x, 0.0, c}
        _ -> {c, 0.0, x}
      end

    {r, g, b}
  end

  defp fmod(a, b), do: a - Float.floor(a / b) * b

  defmodule Ticker do
    @moduledoc false
    use GenServer

    @frame_interval 33

    def start_link(column_ids) do
      GenServer.start_link(__MODULE__, column_ids, name: __MODULE__)
    end

    @impl true
    def init(column_ids) do
      Process.send_after(self(), :tick, @frame_interval)
      {:ok, %{column_ids: column_ids}}
    end

    @impl true
    def handle_info(:tick, state) do
      for id <- state.column_ids do
        NeonPerceptron.Column.update(id, nil)
      end

      Process.send_after(self(), :tick, @frame_interval)
      {:noreply, state}
    end
  end
end
