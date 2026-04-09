defmodule NeonPerceptron.Builds.TestPattern do
  @moduledoc """
  Hardware test build: cycles both big LEDs through full-saturation hues at
  ~0.25 Hz on all 5 SPI columns. No neural network, no training --- just a
  colour wheel to verify SPI wiring.
  """

  alias NeonPerceptron.Board

  def topology, do: %{layers: [], sizes: %{}}
  def trainer_config, do: nil

  def extra_children do
    ids = [:input_left, :input_right, :hidden_front, :hidden_rear, :output]
    [{__MODULE__.Ticker, ids}]
  end

  def column_configs do
    [
      column(:input_left, "spidev0.0", 2),
      column(:input_right, "spidev0.1", 2),
      column(:hidden_front, "spidev1.0", 3),
      column(:hidden_rear, "spidev1.1", 3),
      column(:output, "spidev1.2", 2)
    ]
  end

  defp column(id, spi_device, board_count) do
    %{
      id: id,
      spi_device: spi_device,
      boards: List.duplicate(%{}, board_count),
      render_fn: nil,
      render_frame_fn: fn _state -> render_frame(board_count) end
    }
  end

  def render_frame(board_count) do
    {r, g, b} = current_rgb()

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

  defp current_rgb do
    ms = System.system_time(:millisecond)
    hue = rem(ms, 4000) / 4000 * 360
    hsv_to_rgb(hue)
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
