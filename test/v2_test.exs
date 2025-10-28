defmodule Brainworms.V2Test do
  use ExUnit.Case

  @image_size 5

  def download_training_set() do
    # download the MNIST dataset
    base_url = "https://storage.googleapis.com/cvdf-datasets/mnist/"
    %{body: train_images} = Req.get!(base_url <> "train-images-idx3-ubyte.gz")
    %{body: train_labels} = Req.get!(base_url <> "train-labels-idx1-ubyte.gz")

    # pull apart the binary data
    <<_::32, n_images::32, n_rows::32, n_cols::32, images::binary>> = train_images
    <<_::32, _n_labels::32, labels::binary>> = train_labels

    # turn into a tensor of "images"
    images =
      images
      |> Nx.from_binary({:u, 8})
      |> Nx.reshape({n_images, 1, n_rows, n_cols}, names: [:images, :channels, :height, :width])
      |> Nx.divide(255)
      # resize images for the apparatus
      |> Nx.vectorize(:images)
      |> NxImage.resize({@image_size, @image_size}, channels: :first)
      |> Nx.devectorize()

    targets =
      labels
      |> Nx.from_binary({:u, 8})
      |> Nx.new_axis(-1)
      |> Nx.equal(Nx.tensor(Enum.to_list(0..9)))

    {images, targets}
  end
end
