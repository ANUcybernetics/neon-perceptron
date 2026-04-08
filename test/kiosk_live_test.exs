defmodule NeonPerceptronTest.KioskLiveTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint NeonPerceptronWeb.Endpoint

  test "kiosk page mounts and renders touch canvas" do
    conn = build_conn()
    {:ok, _view, html} = live(conn, "/ui")
    assert html =~ ~s(id="touch-canvas")
    assert html =~ "TouchPulse"
  end
end
