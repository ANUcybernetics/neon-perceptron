defmodule NeonPerceptronWeb.DigitalTwinLive do
  @moduledoc """
  LiveView for the Three.js digital twin visualisation.

  Receives weight updates from the training server and pushes them to the JS client.
  The client owns the input state and calculates all activations locally.
  """

  use NeonPerceptronWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "network_state")
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="digital-twin" phx-hook="DigitalTwin" phx-update="ignore" style="width: 100vw; height: 100vh;"></div>
    """
  end

  @impl true
  def handle_event("set_input", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:network_state, network_state}, socket) do
    data = %{
      weights: network_state.weights,
      topology: %{
        input_size: network_state.topology.sizes["input"],
        hidden_size: network_state.topology.sizes["hidden_0"],
        output_size: network_state.topology.sizes["output"]
      }
    }

    {:noreply, push_event(socket, "weights", data)}
  end
end
