defmodule NeonPerceptronTest.UtilsTest do
  use ExUnit.Case
  alias NeonPerceptron.Utils

  test "conversion is reversible for all digits" do
    for digit <- 0..9 do
      assert digit
             |> Utils.digit_to_bitlist()
             |> Utils.bitlist_to_digit() == digit
    end
  end
end
