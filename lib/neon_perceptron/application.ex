defmodule NeonPerceptron.Application do
  @moduledoc false

  use Application

  alias NeonPerceptron.{Chain, Trainer}

  @impl true
  def start(_type, _args) do
    prepare_hardware()
    Nerves.Runtime.validate_firmware()

    build = Application.get_env(:neon_perceptron, :build)
    role = Application.get_env(:neon_perceptron, :role, :trainer)

    children =
      common_children() ++
        build_children(build, role) ++
        phoenix_children() ++
        platform_children()

    opts = [strategy: :rest_for_one, name: NeonPerceptron.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp common_children do
    [
      {Registry, keys: :unique, name: NeonPerceptron.ChainRegistry},
      NeonPerceptron.Touch
    ]
  end

  defp build_children(build, role) do
    trainer =
      if role == :trainer do
        case build.trainer_config() do
          nil -> []
          config -> [{Trainer, config}]
        end
      else
        []
      end

    chains =
      build.chain_configs()
      |> Enum.map(fn config -> {Chain, config} end)

    extra =
      if function_exported?(build, :extra_children, 0),
        do: build.extra_children(),
        else: []

    trainer ++ chains ++ extra
  end

  defp phoenix_children do
    [
      {Phoenix.PubSub, name: NeonPerceptron.PubSub},
      NeonPerceptronWeb.Endpoint
    ]
  end

  if Mix.target() == :host do
    defp prepare_hardware, do: :ok
    defp platform_children, do: []
  else
    defp prepare_hardware do
      if System.find_executable("udevd") do
        System.cmd("udevd", ["--daemon"])
        System.cmd("udevadm", ["trigger"])
        System.cmd("udevadm", ["settle"])
      end

      if System.find_executable("modprobe") do
        System.cmd("modprobe", ["-r", "vc4"])
        Process.sleep(500)
        System.cmd("modprobe", ["vc4"])
        Process.sleep(1000)
      end

      :os.cmd(~c"dmesg -n 1")

      if System.find_executable("udevadm") do
        System.cmd("udevadm", ["trigger"])
        System.cmd("udevadm", ["settle"])
      end
    end

    if Mix.target() == :reterminal_dm do
      defp platform_children, do: [NeonPerceptron.Kiosk.Supervisor]
    else
      defp platform_children, do: []
    end
  end
end
