defmodule AIBrainwormsTest do
  use ExUnit.Case
  doctest AIBrainworms

  test "greets the world" do
    assert AIBrainworms.hello() == :world
  end
end
