defmodule NeonPerceptron.Kiosk.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    platform = Application.get_env(:neon_perceptron, :kiosk_platform, :wl)

    children =
      seatd_child() ++
        weston_child(platform) ++
        [NeonPerceptron.Kiosk.CogServer]

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

  defp weston_child(:wl) do
    [NeonPerceptron.Kiosk.WestonServer]
  end

  defp weston_child(:drm) do
    []
  end
end
