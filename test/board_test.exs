defmodule NeonPerceptron.BoardTest do
  use ExUnit.Case, async: true

  alias NeonPerceptron.Board

  test "channels_per_board is 24" do
    assert Board.channels_per_board() == 24
  end

  test "blank returns 24 zeroes" do
    blank = Board.blank()
    assert length(blank) == 24
    assert Enum.all?(blank, &(&1 == 0.0))
  end

  test "channel constants are correct" do
    assert Board.front_blue() == 18
    assert Board.front_green() == 19
    assert Board.front_red() == 20
    assert Board.rear_blue() == 21
    assert Board.rear_green() == 22
    assert Board.rear_red() == 23
  end

  describe "encode/1" do
    test "encodes all zeros" do
      result = Board.encode([0, 0, 0, 0])
      assert result == <<0, 0, 0, 0, 0, 0>>
    end

    test "encodes all ones" do
      result = Board.encode([1, 1, 1, 1])
      assert result == <<255, 255, 255, 255, 255, 255>>
    end

    test "matches Utils.pwm_encode output" do
      values = [0, 1, 0, 1]
      assert Board.encode(values) == NeonPerceptron.Utils.pwm_encode(values)
    end

    test "clamps values outside 0-1 range" do
      result = Board.encode([-0.5, 1.5])
      assert result == Board.encode([0.0, 1.0])
    end

    test "applies gamma correction" do
      # With gamma=2.8, 0.5^2.8 ≈ 0.144, so the 12-bit value should be ~590
      # rather than ~2048 (half of 4095)
      <<raw::unsigned-integer-size(12)>> = Board.encode([0.5])
      assert raw < 700
      assert raw > 400
    end
  end

  describe "pack/1" do
    test "packs 12-bit values MSB-first" do
      assert Board.pack([0xABC, 0x123]) == <<0xAB, 0xC1, 0x23>>
    end

    test "matches Brendan's Python packing for one chip sent in wire order" do
      leds = for i <- 0..23, do: rem(i * 173 + 41, 4096)
      assert Board.pack(Enum.reverse(leds)) == NeonPerceptron.PythonBench.pack(leds)
    end

    test "rejects values that don't fit in 12 bits" do
      for bad <- [4096, -1, 1.0] do
        assert_raise ArgumentError, fn -> Board.pack([bad, 0]) end
      end
    end
  end
end
