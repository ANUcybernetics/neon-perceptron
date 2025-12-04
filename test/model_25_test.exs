defmodule NeonPerceptron.Model25Test do
  use ExUnit.Case

  describe "model architecture" do
    test "model has no biases" do
      model = NeonPerceptron.Model25.new(8)
      {init_fn, _predict_fn} = Axon.build(model)
      model_state = init_fn.(Nx.template({1, 25}, :f32), Axon.ModelState.empty())

      %{data: data} = model_state

      assert Map.has_key?(data["dense_0"], "kernel")
      refute Map.has_key?(data["dense_0"], "bias")

      assert Map.has_key?(data["dense_1"], "kernel")
      refute Map.has_key?(data["dense_1"], "bias")
    end

    test "model has correct layer structure (no layer_norm)" do
      model = NeonPerceptron.Model25.new(8)
      {init_fn, _predict_fn} = Axon.build(model)
      model_state = init_fn.(Nx.template({1, 25}, :f32), Axon.ModelState.empty())

      %{data: data} = model_state

      layer_names = Map.keys(data)
      assert "dense_0" in layer_names
      assert "dense_1" in layer_names
      refute Enum.any?(layer_names, &String.contains?(&1, "norm"))
    end
  end

  describe "weight extraction" do
    test "extracts weights with correct shapes" do
      hidden_size = 8
      model = NeonPerceptron.Model25.new(hidden_size)
      {init_fn, _predict_fn} = Axon.build(model)
      model_state = init_fn.(Nx.template({1, 25}, :f32), Axon.ModelState.empty())

      %{data: data} = model_state
      dense_0 = data["dense_0"]["kernel"] |> Nx.to_flat_list()
      dense_1 = data["dense_1"]["kernel"] |> Nx.to_flat_list()

      assert length(dense_0) == 25 * hidden_size
      assert length(dense_1) == hidden_size * 10
    end

    test "weight shapes scale with hidden size" do
      for hidden_size <- [4, 8, 12] do
        model = NeonPerceptron.Model25.new(hidden_size)
        {init_fn, _predict_fn} = Axon.build(model)
        model_state = init_fn.(Nx.template({1, 25}, :f32), Axon.ModelState.empty())

        %{data: data} = model_state
        dense_0 = data["dense_0"]["kernel"] |> Nx.to_flat_list()
        dense_1 = data["dense_1"]["kernel"] |> Nx.to_flat_list()

        assert length(dense_0) == 25 * hidden_size,
               "dense_0 should be 25×#{hidden_size} = #{25 * hidden_size}"

        assert length(dense_1) == hidden_size * 10,
               "dense_1 should be #{hidden_size}×10 = #{hidden_size * 10}"
      end
    end
  end

  describe "forward pass" do
    test "model produces valid softmax output" do
      model = NeonPerceptron.Model25.new(8)
      {init_fn, predict_fn} = Axon.build(model)
      model_state = init_fn.(Nx.template({1, 25}, :f32), Axon.ModelState.empty())

      input = Nx.broadcast(1.0, {1, 25})
      output = predict_fn.(model_state, input)

      assert Nx.shape(output) == {1, 10}

      output_list = Nx.to_flat_list(output)
      sum = Enum.sum(output_list)
      assert_in_delta sum, 1.0, 0.0001, "softmax output should sum to 1"

      assert Enum.all?(output_list, &(&1 >= 0 and &1 <= 1)),
             "softmax outputs should be in [0, 1]"
    end
  end
end
