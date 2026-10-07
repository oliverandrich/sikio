# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthNavigationTest do
  use SikioWeb.ConnCase

  alias SikioWeb.Auth

  defp claim do
    conn = claiming_conn()
    attrs = %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}
    {:ok, conn} = Auth.register(conn, attrs, "ada", %{})
    conn
  end

  test "anonymous home redirects to login", %{conn: conn} do
    assert conn |> get("/") |> redirected_to() == "/login"
  end

  # A setup code protects the instance claim. The setup page shows only the code field.
  test "an empty instance sends login to the setup page, which asks for the code", %{conn: conn} do
    assert conn |> get("/login") |> redirected_to() == "/setup"
    html = conn |> get("/setup") |> html_response(200)
    assert html =~ "setup-code-form"
    assert html =~ "name=\"setup_code\""
    refute html =~ "name=\"username\""
    refute html =~ "name=\"email\""
    refute html =~ "recovery-form"
  end

  test "login and recovery are separate screens after setup", %{conn: conn} do
    claim()
    login = conn |> get("/login") |> html_response(200)
    assert login =~ "Sign in with a passkey"
    assert login =~ "href=\"/recover\""
    refute login =~ "recovery-form"
    refute login =~ "claim-form"

    recovery = conn |> get("/recover") |> html_response(200)
    assert recovery =~ "recovery-form"
    assert recovery =~ "href=\"/login\""
    refute recovery =~ "phx-click=\"sign-in\""
    assert conn |> get("/setup") |> redirected_to() == "/login"
  end

  # Without `viewport-fit=cover`, iOS reports no safe-area insets for the bars.
  test "a page asks for the whole screen", %{conn: conn} do
    html = conn |> get("/setup") |> html_response(200)
    assert html =~ ~r/<meta name="viewport" content="[^"]*viewport-fit=cover/
  end

  test "members land on the library and do not see login again" do
    conn = build_conn() |> Plug.Test.init_test_session(get_session(claim()))
    library = conn |> get("/") |> html_response(200)
    assert library =~ ~s(id="library-heading")
    assert library =~ ~s(title="ada")
    assert conn |> get("/login") |> redirected_to() == "/"
  end
end
