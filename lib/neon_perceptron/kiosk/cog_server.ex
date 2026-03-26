defmodule NeonPerceptron.Kiosk.CogServer do
  use GenServer

  require Logger

  @default_url "http://localhost:4000/ui"
  @xdg_runtime_dir "/run"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def change_url(url) do
    GenServer.call(__MODULE__, {:change_url, url})
  end

  @impl true
  def init(opts) do
    url = Keyword.get(opts, :url, @default_url)

    case System.find_executable("cog") do
      nil ->
        Logger.warning("Cog not found - running in simulation mode")
        {:ok, %{mode: :simulation, url: url, pid: nil}}

      _path ->
        {:ok, %{mode: :hardware, url: url, pid: nil}, {:continue, :start_cog}}
    end
  end

  @impl true
  def handle_continue(:start_cog, state) do
    {:noreply, start_cog(state)}
  end

  @impl true
  def handle_call({:change_url, url}, _from, %{mode: :simulation} = state) do
    Logger.info("Simulation: would navigate to #{url}")
    {:reply, :ok, %{state | url: url}}
  end

  def handle_call({:change_url, url}, _from, state) do
    stop_cog(state)
    new_state = start_cog(%{state | url: url})
    {:reply, :ok, new_state}
  end

  defp start_cog(state) do
    args = ["--platform=wl", state.url]

    env = [
      {"XDG_RUNTIME_DIR", @xdg_runtime_dir},
      {"WAYLAND_DISPLAY", "wayland-1"}
    ]

    Logger.info("Starting Cog browser at #{state.url}")
    {:ok, pid} = MuonTrap.Daemon.start_link("cog", args, env: env, log_output: :debug)
    %{state | pid: pid}
  end

  defp stop_cog(%{pid: nil}), do: :ok

  defp stop_cog(%{pid: pid}) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end
end
