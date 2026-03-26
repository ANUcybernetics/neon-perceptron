defmodule NeonPerceptron.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = common_children() ++ target_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :rest_for_one, name: NeonPerceptron.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp common_children do
    [
      NeonPerceptron.Knob,
      NeonPerceptron.Display
    ]
  end

  # List all child processes to be supervised
  defp phoenix_children do
    [
      {Phoenix.PubSub, name: NeonPerceptron.PubSub},
      NeonPerceptronWeb.Endpoint
    ]
  end

  if Mix.target() == :host do
    defp target_children do
      [
        {NeonPerceptron.Model25, [hidden_size: 9]}
        | phoenix_children()
      ]
    end
  else
    defp target_children do
      [
        NeonPerceptron.Model
        | phoenix_children() ++ kiosk_children()
      ]
    end

    defp kiosk_children do
      [NeonPerceptron.Kiosk.Supervisor]
    end
  end
end
