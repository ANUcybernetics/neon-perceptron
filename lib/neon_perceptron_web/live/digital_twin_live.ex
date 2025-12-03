defmodule NeonPerceptronWeb.DigitalTwinLive do
  use NeonPerceptronWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "activations")
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
  def handle_info({:activations, data}, socket) do
    {:noreply, push_event(socket, "activations", data)}
  end

  @impl true
  def handle_event("set_input", %{"input" => input}, socket) do
    input_floats = Enum.map(input, fn v -> if v == 1, do: 1.0, else: 0.0 end)
    NeonPerceptron.Model25.set_web_input(input_floats)
    {:noreply, socket}
  end
end
