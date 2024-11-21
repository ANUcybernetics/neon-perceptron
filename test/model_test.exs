defmodule Brainworms.ModelTest do
  use ExUnit.Case

  test "end-to-end test" do
    model = Brainworms.Model.new(2)
    {inputs, targets} = Brainworms.Model.training_set()
    training_data = Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))
    params = Brainworms.Model.train(model, training_data, epochs: 10_000)

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

  test "model halting" do
    model = Brainworms.Model.new(2)
    {inputs, targets} = Brainworms.Model.training_set()
    training_data = Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))

    model
    |> Axon.Loop.trainer(:categorical_cross_entropy, :adam)
    |> Axon.Loop.metric(:accuracy, "Accuracy")
    |> Axon.Loop.handle_event(:epoch_completed, fn loop_state ->
      {:halt_loop, loop_state}
    end)
    |> Axon.Loop.run(training_data, Axon.ModelState.empty())
  end

  test "printing activations" do
    model = Brainworms.Model.new(2)
    {inputs, targets} = Brainworms.Model.training_set()
    training_data = Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))
    {_init_fn, predict_fn} = Axon.build(model, print_values: true)

    # train from go to whoa, get params
    params = Brainworms.Model.train(model, training_data)

    # predict input
    # Utils.digit_to_bitlist(0)
    input = [1, 0, 0, 0, 0, 0, 0]
    prediction = predict_fn.(params, input |> Nx.tensor() |> Nx.new_axis(0)) |> Nx.to_flat_list()

    activations = Brainworms.Model.activations_from_model_state(params, input)

    # this is a pretty big eplison - not sure why it's differing
    assert epsilon = 1.0e-4

    Enum.zip(prediction, List.last(activations))
    |> Enum.each(fn {pred, act} ->
      assert abs(pred - act) < epsilon
    end)
  end
end
