defmodule Brainworms.Display.Wires do
  @moduledoc """
  Functions for lighting up the nOOdz wires using PWM.
  """

  alias Brainworms.Utils

  @pwm_controller_count Application.compile_env!(:brainworms, :pwm_controller_count)

  def set_all(spi_bus, value) do
    data =
      value
      |> List.duplicate(24 * @pwm_controller_count)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
    :ok
  end

  def breathe(spi_bus) do
    data =
      Range.new(1, 24 * @pwm_controller_count)
      |> Enum.map(fn x -> 0.5 + 0.5 * Utils.osc(0.1 * (1 + Integer.mod(x, 8))) end)
      |> Utils.pwm_encode()

    Circuits.SPI.transfer!(spi_bus, data)
  end

  @doc """
  Takes the current model state and (bitlist) input and returns a list of the intermediate
  computations and final activations during inference. The list includes
  element-wise multiplications and summed results for each layer, in order.

  Used to map neural network calculations to wire brightness values for visualization.

  The returned list is flattened with each element in [0.0, 1.0] and suitable for sending
  to the PWM controllers.
  """
  def activations_to_brightness_list(model_state, input) do
    weights = Map.get(model_state, :data)
    %{"dense_0" => %{"kernel" => kernel_0}, "dense_1" => %{"kernel" => kernel_1}} = weights

    dense_layers = [kernel_0, kernel_1]
    input_vector = Nx.tensor(input, type: :f32)

    Enum.reduce(dense_layers, {input_vector, []}, fn layer, {current_input, outputs} ->
      intermediate = current_input |> Nx.new_axis(1) |> Nx.multiply(layer)
      result = Nx.sum(intermediate, axes: [0])
      {result, outputs ++ [intermediate, result]}
    end)
    |> elem(1)
    |> Enum.flat_map(fn tensor -> Nx.to_flat_list(tensor) end)
  end
end
