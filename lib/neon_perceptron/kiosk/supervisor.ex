defmodule NeonPerceptron.Kiosk.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = seatd_child() ++ [
      NeonPerceptron.Kiosk.WestonServer,
      NeonPerceptron.Kiosk.CogServer
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp seatd_child do
    if System.find_executable("seatd") do
      File.rm("/run/seatd.sock")

      [%{
        id: :seatd,
        start: {MuonTrap.Daemon, :start_link,
          ["seatd", ["-g", "root"], [env: [{"SEATD_VTBOUND", "0"}], log_output: :debug]]}
      }]
    else
      []
    end
  end
end
