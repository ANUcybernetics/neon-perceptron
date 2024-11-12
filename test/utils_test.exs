defmodule BrainwormsTest.UtilsTest do
  use ExUnit.Case
  alias Brainworms.Utils

  describe "digit_to_bitlist!/1" do
    test "converts valid digits (0-9) to correct bitlists" do
      assert Utils.digit_to_bitlist!(0) == [1, 1, 1, 0, 1, 1, 1]
      assert Utils.digit_to_bitlist!(1) == [0, 0, 1, 0, 0, 1, 0]
      assert Utils.digit_to_bitlist!(2) == [1, 0, 1, 1, 1, 0, 1]
      assert Utils.digit_to_bitlist!(3) == [1, 0, 1, 1, 0, 1, 1]
      assert Utils.digit_to_bitlist!(4) == [0, 1, 1, 1, 0, 1, 0]
      assert Utils.digit_to_bitlist!(5) == [1, 1, 0, 1, 0, 1, 1]
      assert Utils.digit_to_bitlist!(6) == [1, 1, 0, 1, 1, 1, 1]
      assert Utils.digit_to_bitlist!(7) == [1, 0, 1, 0, 0, 1, 0]
      assert Utils.digit_to_bitlist!(8) == [1, 1, 1, 1, 1, 1, 1]
      assert Utils.digit_to_bitlist!(9) == [1, 1, 1, 1, 0, 1, 1]
    end

    test "raises error for invalid digits" do
      assert_raise RuntimeError, "digit must be 0-9", fn ->
        Utils.digit_to_bitlist!(-1)
      end

      assert_raise RuntimeError, "digit must be 0-9", fn ->
        Utils.digit_to_bitlist!(10)
      end
    end
  end

  describe "bitlist_to_digit!/1" do
    test "converts valid bitlists to correct digits" do
      assert Utils.bitlist_to_digit!([1, 1, 1, 0, 1, 1, 1]) == 0
      assert Utils.bitlist_to_digit!([0, 0, 1, 0, 0, 1, 0]) == 1
      assert Utils.bitlist_to_digit!([1, 0, 1, 1, 1, 0, 1]) == 2
      assert Utils.bitlist_to_digit!([1, 0, 1, 1, 0, 1, 1]) == 3
      assert Utils.bitlist_to_digit!([0, 1, 1, 1, 0, 1, 0]) == 4
      assert Utils.bitlist_to_digit!([1, 1, 0, 1, 0, 1, 1]) == 5
      assert Utils.bitlist_to_digit!([1, 1, 0, 1, 1, 1, 1]) == 6
      assert Utils.bitlist_to_digit!([1, 0, 1, 0, 0, 1, 0]) == 7
      assert Utils.bitlist_to_digit!([1, 1, 1, 1, 1, 1, 1]) == 8
      assert Utils.bitlist_to_digit!([1, 1, 1, 1, 0, 1, 1]) == 9
    end

    test "raises error for invalid bitlists" do
      assert_raise RuntimeError, "bitlist did not correspond to a digit 0-9", fn ->
        Utils.bitlist_to_digit!([0, 0, 0, 0, 0, 0, 0])
      end

      assert_raise RuntimeError, "bitlist did not correspond to a digit 0-9", fn ->
        Utils.bitlist_to_digit!([1, 1, 1, 1, 1, 1, 0])
      end
    end
  end

  test "conversion is reversible for all digits" do
    for digit <- 0..9 do
      assert digit
             |> Utils.digit_to_bitlist!()
             |> Utils.bitlist_to_digit!() == digit
    end
  end
end
