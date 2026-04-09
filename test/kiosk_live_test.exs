defmodule NeonPerceptronTest.KioskLiveTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint NeonPerceptronWeb.Endpoint

  test "kiosk page mounts and renders input grid" do
    conn = build_conn()
    {:ok, _view, html} = live(conn, "/ui")
    assert html =~ ~s(id="kiosk")
    assert html =~ "tap_input"
    assert html =~ "Reset weights"
  end

  test "tapping input increments brightness" do
    conn = build_conn()
    {:ok, view, _html} = live(conn, "/ui")

    html = render_click(view, "tap_input", %{"index" => "0"})
    assert html =~ "10%"

    html = render_click(view, "tap_input", %{"index" => "0"})
    assert html =~ "20%"
  end
end
