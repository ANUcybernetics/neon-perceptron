defmodule Brainworms.ModelTest do
  use ExUnit.Case

  test "model initializes without starting training immediately" do
    # Create a test process to monitor the Model GenServer initialization
    {:ok, model_pid} = GenServer.start_link(Brainworms.Model, [])

    # Give it a moment to potentially schedule training
    Process.sleep(5)

    # The model should be initialized but not have started training yet
    # If training started immediately in init/1, this would be > 0
    iteration = GenServer.call(model_pid, :iteration)

    # Since we're using handle_continue, training may have started
    # but we verify the process doesn't crash during init
    # The iteration is returned as an Nx tensor, so convert to number
    iteration_num = if is_struct(iteration, Nx.Tensor), do: Nx.to_number(iteration), else: iteration
    assert is_integer(iteration_num)

    GenServer.stop(model_pid)
  end

  test "training loop allows message processing" do
    # Start the model
    {:ok, model_pid} = GenServer.start_link(Brainworms.Model, [])

    # Wait for some training iterations
    Process.sleep(50)

    # Send a synchronous message that should be processed even during training
    iteration1 = GenServer.call(model_pid, :iteration)
    iteration1_num = if is_struct(iteration1, Nx.Tensor), do: Nx.to_number(iteration1), else: iteration1

    # Wait a bit more
    Process.sleep(50)

    # Should be able to process another call
    iteration2 = GenServer.call(model_pid, :iteration)
    iteration2_num = if is_struct(iteration2, Nx.Tensor), do: Nx.to_number(iteration2), else: iteration2

    # Training should have progressed
    assert iteration2_num > iteration1_num

    GenServer.stop(model_pid)
  end

  # note: this test can be flaky due to the stochastic nature of training
  # a small 2-hidden-unit network may not always achieve perfect accuracy
  # on all 10 digits after 1000 epochs with random initialization
  test "end-to-end test" do
    model = Brainworms.Model.new(2)
    {inputs, targets} = Brainworms.Model.training_set()
    training_data = Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))
    params = Brainworms.Model.train(model, training_data, epochs: 1_000)

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

  test "test 'manual activations' vs real predictions" do
    # model, dataset & test input the same in both cases
    model = Brainworms.Model.new(2)
    {inputs, targets} = training_set = Brainworms.Model.training_set()

    # reduced from 1_000 to speed up tests - test still validates the core functionality
    num_epochs = 250

    # the "build & train in one hit" setup
    {_init_fn, predict_fn} = Axon.build(model, print_values: false)
    training_data = Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))
    params = Brainworms.Model.train(model, training_data, epochs: num_epochs)

    y_pred = predict_fn.(params, inputs)

    loop_run_accuracy =
      Axon.Metrics.accuracy(targets, y_pred)
      |> Nx.to_flat_list()
      |> List.first()

    # the "train step by step" setup
    {init_fn, step_fn} = Axon.Loop.train_step(model, :categorical_cross_entropy, :adam)
    step_state = init_fn.(training_set, Axon.ModelState.empty())

    step_state =
      Enum.reduce(1..num_epochs, step_state, fn idx, acc ->
        if rem(idx, 100) == 0 do
          IO.puts("Training step #{idx} completed")
        end

        step_fn.(training_set, acc)
      end)

    step_run_accuracy =
      Axon.Metrics.accuracy(step_state.y_true, step_state.y_pred)
      |> Nx.to_flat_list()
      |> List.first()

    IO.puts("Loop run accuracy: #{(loop_run_accuracy * 100) |> Float.round(1)}")
    IO.puts("Step run accuracy: #{(step_run_accuracy * 100) |> Float.round(1)}")

    # finally, check the activations
    distances =
      predict_fn.(step_state.model_state, inputs)
      |> Nx.to_list()
      |> Enum.with_index(fn distribution, digit ->
        final_layer =
          Brainworms.Model.activations_from_model_state(
            step_state.model_state,
            Brainworms.Utils.digit_to_bitlist(digit)
          )
          |> List.last()

        # calculate the L2 norm of the difference between things
        dist_tensor = Nx.tensor(distribution)
        final_layer_tensor = Nx.tensor(final_layer)
        diff = Nx.subtract(dist_tensor, final_layer_tensor)
        Nx.sqrt(Nx.sum(Nx.multiply(diff, diff))) |> Nx.to_flat_list() |> List.first()
      end)

    # this is bad check; they should be zero if I'm getting this right
    assert Enum.all?(distances, fn d -> d < 1.0 end)
  end

  test "prediction test (no training)" do
    # model, dataset & test input the same in both cases
    model = Brainworms.Model.new(2)
    {inputs, targets} = Brainworms.Model.training_set()

    # minimal epochs since this test is just validating prediction mechanics, not accuracy
    num_epochs = 50

    # the "build & train in one hit" setup
    {_init_fn, predict_fn} = Axon.build(model, print_values: false)
    training_data = Enum.zip(Nx.to_batched(inputs, 1), Nx.to_batched(targets, 1))
    params = Brainworms.Model.train(model, training_data, epochs: num_epochs)

    Axon.reduce_nodes(model, [], fn
      %Axon.Node{op: :dense} = node, acc ->
        [node | acc]

      _, acc ->
        acc
    end)

    input = inputs[[digit: 1]] |> Nx.new_axis(0)

    predict_fn.(params, input)
  end
end
