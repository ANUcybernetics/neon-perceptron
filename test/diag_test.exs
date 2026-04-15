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

  describe "frame helpers (smoke, :host simulation)" do
    test "dark, light, light_all, light_chip all return :ok" do
      assert :ok = Diag.dark(:diag_test)
      assert :ok = Diag.light(:diag_test, 0, 18, 1.0)
      assert :ok = Diag.light_all(:diag_test, 20, 0.5)
      assert :ok = Diag.light_chip(:diag_test, 2, 1.0)
    end

    test "light with out-of-range chip_index raises" do
      assert_raise ArgumentError, fn ->
        Diag.light(:diag_test, 99, 18, 1.0)
      end
    end

    test "light with out-of-range channel raises" do
      assert_raise ArgumentError, fn ->
        Diag.light(:diag_test, 0, 24, 1.0)
      end
    end
  end
end
