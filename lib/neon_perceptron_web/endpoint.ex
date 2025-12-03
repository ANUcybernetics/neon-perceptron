defmodule NeonPerceptronWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :neon_perceptron

  @session_options [
    store: :cookie,
    key: "_neon_perceptron_key",
    signing_salt: "digital_twin",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :neon_perceptron,
    gzip: not code_reloading?,
    only: NeonPerceptronWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug NeonPerceptronWeb.Router
end
