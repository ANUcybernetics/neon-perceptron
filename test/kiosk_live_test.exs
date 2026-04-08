defmodule NeonPerceptronTest.KioskLiveTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint NeonPerceptronWeb.Endpoint

  test "kiosk page renders touch UI" do
    conn = build_conn()
    {:ok, _view, html} = live(conn, "/ui")
    assert html =~ "Neon Perceptron"
    assert html =~ "Touch anywhere"
  end
end
