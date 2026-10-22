# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionConnectTest do
  @moduledoc """
  Connecting a browser extension from its sign-in window, and disconnecting it.

  The extension opens `/extension/connect` with its redirect URI, state and PKCE challenge.
  Connecting needs a passkey confirmation from the last five minutes. A sign-in in that window
  counts as one, and returns to the page. The code then reaches the redirect URI, and the
  extension exchanges it at `POST /api/v1/token`.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.ExtensionFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Extensions
  alias Sikio.Repo
  alias SikioWeb.Auth

  @verifier String.duplicate("v", 43)

  setup do
    ada = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    redirect = firefox_redirect()
    %{ada: ada, redirect: redirect, connect: connect_path(redirect)}
  end

  defp connect_path(redirect, extra \\ %{}) do
    query =
      Map.merge(
        %{
          "redirect_uri" => redirect,
          "state" => "st4te",
          "code_challenge" =>
            :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false),
          "client" => "Firefox"
        },
        extra
      )

    "/extension/connect?" <> URI.encode_query(query)
  end

  defp signed_in(account, confirmed) do
    conn = build_conn() |> init_test_session(%{}) |> Gate.log_in(account)

    if confirmed,
      do:
        conn
        |> put_session(:confirmed_account_id, account.id)
        |> put_session(:confirmed_at, System.system_time(:second)),
      else: conn
  end

  # The sign-in window may open signed out. The passkey sign-in there returns to the page and
  # counts as the confirmation, so nobody confirms twice in a row.
  test "a sign-in in the window returns to the page and counts as the confirmation", c do
    conn = get(build_conn(), c.connect)
    assert redirected_to(conn) == "/login"

    {:ok, signed} =
      build_conn()
      |> init_test_session(get_session(conn))
      |> Auth.authenticate(c.ada)

    assert json_response(signed, 200)["redirect"] == c.connect

    {:ok, view, _} = live(build_conn() |> init_test_session(get_session(signed)), c.connect)
    assert has_element?(view, "#extension-connect button", "Connect")
  end

  test "without a recent confirmation the page asks for the passkey first", c do
    conn = signed_in(c.ada, false)
    {:ok, view, _} = live(conn, c.connect)
    refute has_element?(view, "#extension-connect button")
    # A pushed event without the confirmation issues no code either.
    assert is_binary(render_hook(view, "connect", %{}))

    confirm = view |> element("#extension-confirm") |> render() |> Floki.parse_fragment!()
    [href] = Floki.attribute(confirm, "href")

    conn = get(conn, href)
    assert redirected_to(conn) == "/account/verify"
    assert get_session(conn, :reauth_target) == c.connect

    {:ok, confirmed} =
      build_conn()
      |> init_test_session(get_session(conn))
      |> assign(:current_account, c.ada)
      |> Auth.authenticate(c.ada)

    assert json_response(confirmed, 200)["redirect"] == c.connect
  end

  test "connecting hands the extension a code that the API exchanges for a token", c do
    {:ok, view, _} = live(signed_in(c.ada, true), c.connect)

    assert {:error, {:redirect, %{to: to}}} =
             view |> element("#extension-connect button") |> render_click()

    %{"code" => code, "state" => "st4te"} = URI.decode_query(URI.parse(to).query)
    assert String.starts_with?(to, c.redirect <> "?")

    conn =
      post(build_conn(), "/api/v1/token", %{
        "code" => code,
        "code_verifier" => @verifier,
        "redirect_uri" => c.redirect
      })

    assert %{"token" => token} = json_response(conn, 200)
    assert {:ok, %User{id: id}} = Extensions.authenticate(token)
    assert id == c.ada.id

    again =
      post(build_conn(), "/api/v1/token", %{
        "code" => code,
        "code_verifier" => @verifier,
        "redirect_uri" => c.redirect
      })

    assert json_response(again, 400) == %{"error" => "invalid_grant"}
  end

  test "declining tells the extension so", c do
    {:ok, view, _} = live(signed_in(c.ada, true), c.connect)

    assert {:error, {:redirect, %{to: to}}} =
             view |> element("#extension-decline") |> render_click()

    assert URI.decode_query(URI.parse(to).query) == %{
             "error" => "access_denied",
             "state" => "st4te"
           }
  end

  # The five minutes count when the code is issued, not when the page was opened.
  test "a confirmation that expired while the page was open issues no code", c do
    conn = signed_in(c.ada, true)
    {:ok, view, _} = live(conn, c.connect)

    stale = %{
      "confirmed_account_id" => c.ada.id,
      "confirmed_at" => System.system_time(:second) - 301
    }

    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.confirmation, stale)
    end)

    html = view |> element("#extension-connect button") |> render_click()
    assert is_binary(html)
    assert html =~ "Confirm your identity"
  end

  # An abandoned visit must not take over a later ordinary sign-in.
  test "a remembered connect page expires after ten minutes", c do
    conn = get(build_conn(), c.connect)
    {at, path} = get_session(conn, :extension_return)
    assert path == c.connect

    stale =
      build_conn()
      |> init_test_session(get_session(conn))
      |> put_session(:extension_return, {at - 601, path})

    {:ok, signed} = Auth.authenticate(stale, c.ada)
    assert json_response(signed, 200)["redirect"] == "/"
    refute get_session(signed, :confirmed_at)
  end

  test "a request without a valid challenge goes back to the extension", c do
    path =
      connect_path(c.redirect, %{"code_challenge" => "short"})

    {:ok, view, html} = live(signed_in(c.ada, true), path)
    assert html =~ "request is incomplete"
    refute has_element?(view, "#extension-connect button")

    assert {:error, {:redirect, %{to: to}}} =
             view |> element("#extension-decline") |> render_click()

    assert URI.decode_query(URI.parse(to).query)["error"] == "invalid_request"
  end

  test "the page names the extension as it is stored", c do
    {:ok, _view, html} =
      live(signed_in(c.ada, true), connect_path(c.redirect, %{"client" => "  "}))

    assert html =~ "Browser extension can then add"
  end

  # The page never redirects to an address that is not an extension's.
  test "a foreign redirect URI is refused on the page", c do
    {:ok, view, html} =
      live(
        signed_in(c.ada, true),
        connect_path(c.redirect, %{"redirect_uri" => foreign_redirect()})
      )

    assert html =~ "cannot be connected"
    refute has_element?(view, "#extension-connect button")
    refute has_element?(view, "#extension-decline")
  end

  test "a confirmation returns only to the connect page", c do
    conn = signed_in(c.ada, false)
    assert conn |> get("/account/confirm/extension?return=/accounts") |> response(404)
    assert conn |> get("/account/confirm/extension?return=//evil.example/x") |> response(404)
  end

  test "the settings list connected extensions and disconnect one", c do
    {:ok, code} =
      Extensions.authorize(c.ada, %{
        "redirect_uri" => c.redirect,
        "code_challenge" => :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false),
        "client" => "Firefox on macOS"
      })

    {:ok, token} = Extensions.exchange(code, @verifier, c.redirect)
    conn = signed_in(c.ada, false)

    {:ok, view, _} = live(conn, ~p"/account/settings")
    assert has_element?(view, ~s|a[href="/account/extensions"]|)

    {:ok, view, _} = live(conn, ~p"/account/extensions")
    assert has_element?(view, "#extensions", "Firefox on macOS")

    view |> element("#extensions button", "Disconnect") |> render_click()
    refute has_element?(view, "#extensions", "Firefox on macOS")
    assert Extensions.authenticate(token) == :error
  end
end
