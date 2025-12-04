import Config

# Add configuration that is only needed when running on the host here.

config :nx, default_backend: EMLX.Backend

# Hardware configuration for host environment (development/testing)
# When running on host, hardware is typically not available, so modules
# should gracefully degrade to simulation mode
config :neon_perceptron, hardware_required: false

# Phoenix configuration (host only)
config :neon_perceptron, NeonPerceptronWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  secret_key_base: "neon_perceptron_dev_secret_key_base_at_least_64_bytes_long_for_security",
  live_view: [signing_salt: "neon_perceptron_salt"],
  render_errors: [formats: [html: NeonPerceptronWeb.ErrorHTML], layout: false],
  pubsub_server: NeonPerceptron.PubSub,
  server: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:neon_perceptron, ~w(--sourcemap=inline --watch)]}
  ]

config :esbuild,
  version: "0.17.11",
  neon_perceptron: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../assets/node_modules", __DIR__)}
  ]

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://hexdocs.pm/nerves_runtime/readme.html#using-nerves_runtime-in-tests
       # https://hexdocs.pm/nerves_runtime/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}
