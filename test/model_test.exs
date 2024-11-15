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

    errors =
      0..9
      |> Enum.map(fn digit ->
        predicted = Brainworms.Model.predict_class(model, params, digit)

        if predicted != digit do
          {digit, predicted}
        end
      end)
      |> Enum.reject(&is_nil/1)

    if errors != [] do
      error_messages =
        Enum.map_join(errors, "\n", fn {expected, actual} ->
          "Expected #{expected} but got #{actual}"
        end)

      flunk("Mispredictions found:\n#{error_messages}")
    end
  end
end
