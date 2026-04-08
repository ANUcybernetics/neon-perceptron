defmodule NeonPerceptron.Kiosk.WestonServer do
  use GenServer

  require Logger

  @xdg_runtime_dir "/run"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case System.find_executable("weston") do
      nil ->
        Logger.warning("Weston not found - running in simulation mode")
        {:ok, %{mode: :simulation, pid: nil}}

      _path ->
        Process.sleep(500)
        args = ["--shell=kiosk", "--log=/tmp/weston.log"]
        env = [{"XDG_RUNTIME_DIR", @xdg_runtime_dir}]

        Logger.info("Starting Weston compositor")
        {:ok, pid} = MuonTrap.Daemon.start_link("weston", args, env: env, log_output: :debug)
        {:ok, %{mode: :hardware, pid: pid}}
    end
  end
end
