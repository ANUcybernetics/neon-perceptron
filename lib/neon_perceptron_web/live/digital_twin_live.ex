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
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "weights")
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
  def handle_info({:weights, data}, socket) do
    {:noreply, push_event(socket, "weights", data)}
  end
end
