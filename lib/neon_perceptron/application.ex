defmodule NeonPerceptron.Application do
  @moduledoc false

  use Application

  alias NeonPerceptron.{Trainer, Column}

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
      {Registry, keys: :unique, name: NeonPerceptron.ColumnRegistry},
      NeonPerceptron.Knob,
      NeonPerceptron.Touch
    ]
  end

  defp build_children(build, role) do
    trainer =
      if role == :trainer do
        [{Trainer, build.trainer_config()}]
      else
        []
      end

    columns =
      build.column_configs()
      |> Enum.map(fn config -> {Column, config} end)

    trainer ++ columns
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

    defp platform_children do
      [NeonPerceptron.Kiosk.Supervisor]
    end
  end
end
