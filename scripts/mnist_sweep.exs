epochs = 20
min_hidden = 8
max_hidden = 12

create_model = fn
  :single, hidden_size ->
    Axon.input("input", shape: {nil, 25})
    |> Axon.dense(hidden_size, use_bias: false, kernel_initializer: :he_normal)
    |> Axon.tanh()
    |> Axon.dense(10, use_bias: false, kernel_initializer: :glorot_uniform)
    |> Axon.softmax()

  :double, {h1, h2} ->
    Axon.input("input", shape: {nil, 25})
    |> Axon.dense(h1, use_bias: false, kernel_initializer: :he_normal)
    |> Axon.tanh()
    |> Axon.dense(h2, use_bias: false, kernel_initializer: :he_normal)
    |> Axon.tanh()
    |> Axon.dense(10, use_bias: false, kernel_initializer: :glorot_uniform)
    |> Axon.softmax()
end

train_model = fn model, {train_images, train_labels}, opts ->
  epochs = Keyword.fetch!(opts, :epochs)
  batch_size = Keyword.get(opts, :batch_size, 128)
  learning_rate = Keyword.get(opts, :learning_rate, 0.005)

  batched_data =
    train_images
    |> Nx.to_batched(batch_size)
    |> Stream.zip(Nx.to_batched(train_labels, batch_size))

  loop =
    model
    |> Axon.Loop.trainer(
      :categorical_cross_entropy,
      Polaris.Optimizers.adam(learning_rate: learning_rate)
    )

  Axon.Loop.run(loop, batched_data, Axon.ModelState.empty(), epochs: epochs)
end

calculate_accuracy = fn model, trained_params, {test_images, test_labels} ->
  {_init_fn, predict_fn} = Axon.build(model)
  predictions = predict_fn.(trained_params, test_images)
  predicted_classes = Nx.argmax(predictions, axis: 1)
  actual_classes = Nx.argmax(test_labels, axis: 1)
  Nx.mean(Nx.equal(predicted_classes, actual_classes)) |> Nx.to_number()
end

process_images = fn images_binary, images_type, images_shape ->
  images_with_channels =
    images_binary
    |> Nx.from_binary(images_type)
    |> Nx.reshape(images_shape)
    |> Nx.as_type(:f32)
    |> Nx.squeeze(axes: [1])
    |> Nx.new_axis(-1)

  resized = NxImage.resize(images_with_channels, {5, 5}, method: :lanczos3, channels: :last)

  resized
  |> Nx.squeeze(axes: [-1])
  |> Nx.reshape({:auto, 25})
  |> Nx.divide(255.0)
end

process_labels = fn labels_binary, labels_type, labels_shape ->
  labels_binary
  |> Nx.from_binary(labels_type)
  |> Nx.reshape(labels_shape)
  |> Nx.as_type(:s64)
  |> then(fn labels ->
    Nx.equal(Nx.new_axis(labels, -1), Nx.tensor(Enum.to_list(0..9)))
    |> Nx.as_type(:f32)
  end)
end

IO.puts("Loading MNIST data...")

{{train_images_binary, train_images_type, train_images_shape},
 {train_labels_binary, train_labels_type, train_labels_shape}} = Scidata.MNIST.download()

{{test_images_binary, test_images_type, test_images_shape},
 {test_labels_binary, test_labels_type, test_labels_shape}} = Scidata.MNIST.download_test()

train_data = {
  process_images.(train_images_binary, train_images_type, train_images_shape),
  process_labels.(train_labels_binary, train_labels_type, train_labels_shape)
}

test_data = {
  process_images.(test_images_binary, test_images_type, test_images_shape),
  process_labels.(test_labels_binary, test_labels_type, test_labels_shape)
}

IO.puts("\n--- Hidden layer size sweep (25 inputs, m hidden, 10 outputs) ---")
IO.puts("Hidden layer range: #{min_hidden}..#{max_hidden}, #{epochs} epochs\n")

for m <- min_hidden..max_hidden do
  model = create_model.(:single, m)
  trained_params = train_model.(model, train_data, epochs: epochs, batch_size: 128)
  accuracy = calculate_accuracy.(model, trained_params, test_data)
  IO.puts("  m=#{m}: #{Float.round(accuracy * 100, 1)}%")
end

IO.puts("\n--- 1HL vs 2HL comparison (#{epochs} epochs, no bias) ---\n")

configs = [
  {"1×8 (280 params)", :single, 8},
  {"2×4 (156 params)", :double, {4, 4}},
  {"2×7 (294 params)", :double, {7, 7}}
]

for {label, type, size} <- configs do
  model = create_model.(type, size)
  trained_params = train_model.(model, train_data, epochs: epochs, batch_size: 128)
  accuracy = calculate_accuracy.(model, trained_params, test_data)
  IO.puts("  #{label}: #{Float.round(accuracy * 100, 1)}%")
end
