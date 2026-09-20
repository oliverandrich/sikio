# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LocaleIntegrationTest do
  use SikioWeb.ConnCase

  import Phoenix.LiveViewTest

  alias SikioWeb.Gettext, as: Backend

  test "browser requests set html language and follow changed browser preferences", %{conn: conn} do
    conn = conn |> put_req_header("accept-language", "de-DE,de;q=0.9") |> get("/setup")
    assert html_response(conn, 200) =~ "lang=\"de\""
    assert get_session(conn, "locale") == "de"
    assert Gettext.get_locale(Backend) == "de"

    conn = conn |> recycle() |> put_req_header("accept-language", "en") |> get("/setup")
    assert html_response(conn, 200) =~ "lang=\"en\""
  end

  test "ceremony requests resolve the locale as well", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "de")
      |> post("/auth/registration/challenge", %{"username" => "ada"})

    assert json_response(conn, 200)["challenge"]
    assert get_session(conn, "locale") == "de"
    assert Gettext.get_locale(Backend) == "de"
  end

  test "connected auth screens and failures are translated", %{conn: conn} do
    conn = put_req_header(conn, "accept-language", "de")
    {:ok, view, html} = live(conn, "/setup")
    assert html =~ "Erstelle deinen Passkey"

    assert view
           |> element("#passkey")
           |> render_hook("ithibati:failed", %{"error" => "invalid_code"}) =~
             "Dieser Wiederherstellungscode ist ungültig."
  end

  test "one-time codes carry translated clipboard messages", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{recovery_codes: ["test-code"]})
      |> put_req_header("accept-language", "de")

    html = conn |> get("/recovery-codes") |> html_response(200)
    assert html =~ "Wiederherstellungscodes kopieren"
    assert html =~ "Wiederherstellungscodes kopiert."
  end
end
