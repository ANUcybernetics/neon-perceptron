defmodule NeonPerceptron.Kiosk.WestonServer do
  use GenServer

  require Logger

  @xdg_runtime_dir "/run"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # The reTerminal DM's DSI display requires a vc4 driver reload to fully
  # initialise the DRM device. See https://github.com/formrausch/frio_rpi4
  defp reload_vc4_driver do
    Logger.info("Reloading vc4 driver for DSI display")
    System.cmd("modprobe", ["-r", "vc4"])
    Process.sleep(500)
    System.cmd("modprobe", ["vc4"])
    Process.sleep(1000)
  end

  @impl true
  def init(_opts) do
    case System.find_executable("weston") do
      nil ->
        Logger.warning("Weston not found - running in simulation mode")
        {:ok, %{mode: :simulation, pid: nil}}

      _path ->
        reload_vc4_driver()

        args = ["--shell=kiosk", "--continue-without-input"]
        env = [{"XDG_RUNTIME_DIR", @xdg_runtime_dir}]

        Logger.info("Starting Weston compositor")
        {:ok, pid} = MuonTrap.Daemon.start_link("weston", args, env: env, log_output: :debug)
        {:ok, %{mode: :hardware, pid: pid}}
    end
  end
end
