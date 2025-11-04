defmodule NeonPerceptron.MNISTTest do
  use ExUnit.Case

  @moduletag :mnist
  @moduletag timeout: 600_000

  test "train MNIST models with varying hidden layer sizes" do
    {train_data, test_data} = load_mnist_data()

    results =
      for m <- 9..25 do
        model = create_model(m)
        trained_params = train_model(model, train_data, epochs: 10, batch_size: 128)
        accuracy = calculate_accuracy(model, trained_params, test_data)
        {m, accuracy}
      end
      |> Map.new()

    IO.puts("\nMNIST Test Results (25 inputs, m hidden, 10 outputs, 10 epochs)")
    IO.inspect(results, label: "Hidden neurons (m) -> Accuracy")

    assert map_size(results) == 17, "Should have trained 17 models (m=9 to m=25)"
  end

  defp create_model(hidden_size) do
    Axon.input("input", shape: {nil, 25})
    |> Axon.dense(hidden_size, activation: :relu, use_bias: false, kernel_initializer: :glorot_uniform)
    |> Axon.dense(10, use_bias: false, kernel_initializer: :glorot_uniform)
  end

  defp load_mnist_data do
    {{train_images_binary, train_images_type, train_images_shape},
     {train_labels_binary, train_labels_type, train_labels_shape}} = Scidata.MNIST.download()

    train_images =
      train_images_binary
      |> Nx.from_binary(train_images_type)
      |> Nx.reshape(train_images_shape)
      |> Nx.as_type(:f32)

    train_labels =
      train_labels_binary
      |> Nx.from_binary(train_labels_type)
      |> Nx.reshape(train_labels_shape)
      |> Nx.as_type(:s64)

    train_images =
      train_images
      |> Nx.squeeze(axes: [1])
      |> resize_images_to_5x5()
      |> Nx.reshape({:auto, 25})

    train_images = Nx.divide(train_images, 255.0)

    train_labels_one_hot =
      Nx.equal(
        Nx.new_axis(train_labels, -1),
        Nx.tensor(Enum.to_list(0..9))
      )
      |> Nx.as_type(:f32)

    total_samples = Nx.axis_size(train_images, 0)
    train_size = trunc(total_samples * 0.9)

    train_data = {
      Nx.slice_along_axis(train_images, 0, train_size, axis: 0),
      Nx.slice_along_axis(train_labels_one_hot, 0, train_size, axis: 0)
    }

    test_data = {
      Nx.slice_along_axis(train_images, train_size, total_samples - train_size, axis: 0),
      Nx.slice_along_axis(train_labels_one_hot, train_size, total_samples - train_size, axis: 0)
    }

    {train_data, test_data}
  end

  defp resize_images_to_5x5(images) do
    indices = Nx.tensor([0, 6, 11, 17, 22])

    images
    |> Nx.take(indices, axis: 1)
    |> Nx.take(indices, axis: 2)
  end

  defp train_model(model, train_data, opts) do
    epochs = Keyword.get(opts, :epochs, 10)
    batch_size = Keyword.get(opts, :batch_size, 128)
    learning_rate = Keyword.get(opts, :learning_rate, 0.005)

    {train_images, train_labels} = train_data

    batched_data =
      train_images
      |> Nx.to_batched(batch_size)
      |> Stream.zip(Nx.to_batched(train_labels, batch_size))

    loop =
      model
      |> Axon.Loop.trainer(:mean_squared_error, Polaris.Optimizers.adam(learning_rate: learning_rate))
      |> Axon.Loop.metric(:accuracy)

    Axon.Loop.run(loop, batched_data, %{}, epochs: epochs)
  end

  defp calculate_accuracy(model, trained_params, test_data) do
    {test_images, test_labels} = test_data

    {_init_fn, predict_fn} = Axon.build(model)
    predictions = predict_fn.(trained_params, test_images)

    predicted_classes = Nx.argmax(predictions, axis: 1)
    actual_classes = Nx.argmax(test_labels, axis: 1)

    Nx.mean(Nx.equal(predicted_classes, actual_classes)) |> Nx.to_number()
  end
end
