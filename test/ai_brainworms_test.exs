defmodule AIBrainwormsTest do
  use ExUnit.Case

  doctest AIBrainworms

  test "end-to-end test" do
    model = AIBrainworms.Model.new([4])
    {inputs, targets} = AIBrainworms.Train.training_set()
    params = AIBrainworms.Train.run(model, inputs, targets)
  end
end
