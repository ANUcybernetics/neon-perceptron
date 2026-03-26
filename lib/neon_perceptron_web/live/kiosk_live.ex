defmodule NeonPerceptronWeb.KioskLive do
  use NeonPerceptronWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; justify-content: center; width: 100vw; height: 100vh; color: #0f0; font-family: monospace; font-size: 2rem;">
      <div style="text-align: center;">
        <h1 style="font-size: 3rem; margin-bottom: 1rem;">Neon Perceptron</h1>
        <p>Kiosk UI placeholder</p>
      </div>
    </div>
    """
  end
end
