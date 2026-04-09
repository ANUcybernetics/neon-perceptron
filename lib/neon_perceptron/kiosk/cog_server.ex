defmodule NeonPerceptron.Kiosk.CogServer do
  use GenServer

  require Logger

  @default_url "http://localhost:4000/ui"
  @xdg_runtime_dir "/run"
  @crash_threshold_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def change_url(url) do
    GenServer.call(__MODULE__, {:change_url, url})
  end

  @impl true
  def init(opts) do
    url = Keyword.get(opts, :url, @default_url)
    platform = Application.get_env(:neon_perceptron, :kiosk_platform, :wl)

    case System.find_executable("cog") do
      nil ->
        Logger.warning("Cog not found - running in simulation mode")
        {:ok, %{mode: :simulation, url: url, platform: platform, pid: nil, monitor_ref: nil}}

      _path ->
        state = %{mode: :hardware, url: url, platform: platform, pid: nil, monitor_ref: nil, started_at: nil}
        {:ok, state, {:continue, :start_cog}}
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

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at

    if elapsed < @crash_threshold_ms and state.platform == :drm do
      Logger.warning(
        "Cog (drm) exited after #{elapsed}ms (#{inspect(reason)}), falling back to --platform=wl"
      )

      ensure_weston()
      {:noreply, start_cog(%{state | platform: :wl})}
    else
      Logger.error("Cog (#{state.platform}) exited: #{inspect(reason)}")
      {:stop, {:cog_crashed, reason}, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_cog(state) do
    {args, env} = cog_config(state.platform, state.url)

    Logger.info("Starting Cog browser (#{state.platform}) at #{state.url}")
    {:ok, pid} = MuonTrap.Daemon.start_link("cog", args, env: env, log_output: :debug)
    ref = Process.monitor(pid)

    %{state | pid: pid, monitor_ref: ref, started_at: System.monotonic_time(:millisecond)}
  end

  defp cog_config(:drm, url) do
    {["--platform=drm", url],
     [{"XDG_RUNTIME_DIR", @xdg_runtime_dir}]}
  end

  defp cog_config(:wl, url) do
    {["--platform=wl", url],
     [{"XDG_RUNTIME_DIR", @xdg_runtime_dir}, {"WAYLAND_DISPLAY", "wayland-1"}]}
  end

  defp stop_cog(%{pid: nil}), do: :ok

  defp stop_cog(%{monitor_ref: ref, pid: pid}) do
    Process.demonitor(ref, [:flush])
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp ensure_weston do
    case Process.whereis(NeonPerceptron.Kiosk.WestonServer) do
      nil ->
        Logger.info("Starting Weston for Wayland fallback")
        NeonPerceptron.Kiosk.WestonServer.start_link()

      _pid ->
        :ok
    end
  end
end
