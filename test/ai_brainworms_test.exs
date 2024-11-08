defmodule AIBrainwormsTest do
  use ExUnit.Case
  alias AIBrainworms.SevenSegment

  doctest AIBrainworms

  test "end-to-end test" do
    model = SevenSegment.Model.new([4])
    {inputs, targets} = SevenSegment.Train.training_set()
    params = SevenSegment.Train.run(model, inputs, targets)
  end
end
