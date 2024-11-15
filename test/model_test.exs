defmodule Brainworms.ModelTest do
  use ExUnit.Case

  test "end-to-end test" do
    model = Brainworms.Model.new(2)
    training_data = Brainworms.Model.training_set()
    params = Brainworms.Model.train(model, training_data, epochs: 10000)

    dense_0_sum = Map.get(params, :data)["dense_0"]["kernel"] |> Nx.sum()
    dense_1_sum = Map.get(params, :data)["dense_1"]["kernel"] |> Nx.sum()

    assert dense_0_sum != 0.0
    assert dense_1_sum != 0.0

    IO.puts("Ok, now for testing the predictions")

    Enum.each(0..9, fn digit ->
      assert Brainworms.Model.predict_class(model, params, digit) == digit
    end)
  end
end
