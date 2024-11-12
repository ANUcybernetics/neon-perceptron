defmodule BrainwormsTest do
  use ExUnit.Case

  doctest Brainworms

  test "end-to-end test" do
    model = Brainworms.Model.new([4])
    {inputs, targets} = Brainworms.Train.training_set()
    params = Brainworms.Train.run(model, inputs, targets)
    IO.inspect(params |> Map.keys())
    IO.inspect(params |> Map.get(:data))
  end
end
