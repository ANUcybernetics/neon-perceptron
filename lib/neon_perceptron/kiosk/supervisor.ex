defmodule NeonPerceptron.Kiosk.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      NeonPerceptron.Kiosk.WestonServer,
      NeonPerceptron.Kiosk.CogServer
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
