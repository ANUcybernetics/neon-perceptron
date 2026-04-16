defmodule NeonPerceptron.MixProject do
  use Mix.Project

  @app :neon_perceptron
  @version "0.1.0"
  @all_targets [:reterminal_dm, :rpi4, :rpi5]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      archives: [nerves_bootstrap: "~> 1.14"],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {NeonPerceptron.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.11", runtime: false},
      {:shoehorn, "~> 0.9.3"},
      {:ring_logger, "~> 0.11.4"},
      {:toolshed, "~> 0.4.2"},
      {:req, "~> 0.5"},
      {:input_event, "~> 1.4"},

      # might not need all of these, can thin out later
      {:circuits_uart, "~> 1.5"},
      {:circuits_gpio, "~> 2.1"},
      {:circuits_i2c, "~> 2.1"},
      {:circuits_spi, "~> 2.0"},

      # AI stuff
      {:axon, "~> 0.7"},
      {:emlx, github: "elixir-nx/emlx", branch: "main", targets: :host},
      {:scidata, "~> 0.1", only: :test},
      {:nx_image, "~> 0.1.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},

      # Phoenix (web UI on host and kiosk on target)
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:esbuild, "~> 0.8", runtime: false},
      {:jason, "~> 1.4"},
      {:plug_cowboy, "~> 2.7"},

      # Kiosk display (Weston + Cog browser management)
      {:muontrap, "~> 1.7"},

      # Development tools
      {:igniter, "~> 0.5", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.5", only: :dev},
      {:usage_rules, "~> 1.2", only: [:dev, :test], runtime: false},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.9"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:reterminal_dm, "~> 2.0",
       github: "ANUcybernetics/reterminal_dm",
       tag: "v2.2.0",
       runtime: false,
       targets: :reterminal_dm},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
