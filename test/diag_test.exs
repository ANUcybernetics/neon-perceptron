defmodule NeonPerceptron.DiagTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Chain, Diag}

  setup do
    config = %{
      id: :diag_test,
      spi_device: "spidev99.99",
      boards: [{"input", 0}, {"input", 1}, {"input", 2}],
      render_fn: fn _state, _spec -> NeonPerceptron.Board.blank() end,
      render_frame_fn: nil
    }

    start_supervised!({Chain, config}, id: :diag_test)
    :ok
  end

  describe "chip_count/1" do
    test "returns the number of boards on a running chain" do
      assert Diag.chip_count(:diag_test) == 3
    end
  end
end
