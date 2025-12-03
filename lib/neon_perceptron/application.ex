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
  if Mix.target() == :host do
    defp target_children do
      [
        # Use 25-input model for digital twin on host
        {NeonPerceptron.Model25, [hidden_size: 9]},
        {Phoenix.PubSub, name: NeonPerceptron.PubSub},
        NeonPerceptronWeb.Endpoint
      ]
    end
  else
    defp target_children do
      [
        # Use 7-input model on device (for physical hardware)
        NeonPerceptron.Model
      ]
    end
  end
end
