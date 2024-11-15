defmodule BrainwormsTest.DisplayTest do
  use ExUnit.Case

  test "correctly replaces sublist" do
    original = [1, 2, 3, 4, 5, 6]
    expected = [1, 2, :a, :b, 5, 6]
    result = Brainworms.Display.replace_sublist(original, {2, 2}, [:a, :b])
    assert result == expected
  end
end
