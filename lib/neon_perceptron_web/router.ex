defmodule NeonPerceptronWeb.Router do
  use NeonPerceptronWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NeonPerceptronWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", NeonPerceptronWeb do
    pipe_through(:browser)

    live("/", DigitalTwinLive)
  end
end
