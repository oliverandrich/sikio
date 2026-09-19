defmodule SikioWeb.LocaleTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SikioWeb.Gettext, as: Backend
  alias SikioWeb.Locale

  test "browser header and default determine the language" do
    assert Locale.resolve("de-DE,de;q=0.9,en;q=0.8") == "de"
    assert Locale.resolve("fr-FR,fr") == "en"
    assert Locale.resolve("") == "en"
    assert Locale.resolve(" FR-fr, DE-at;q=0.8") == "de"
  end

  test "stored account and session choices cannot override the browser" do
    conn =
      conn(:get, "/")
      |> init_test_session(%{"locale" => "de"})
      |> assign(:current_account, %{locale: "de"})
      |> put_req_header("accept-language", "en")
      |> Locale.call([])

    assert conn.assigns.locale == "en"
    assert get_session(conn, "locale") == "en"
    assert Gettext.get_locale(Backend) == "en"
  end

  test "header fallback does not need a fetched session or an account" do
    conn = conn(:get, "/") |> put_req_header("accept-language", "de-CH,de")
    assert Locale.accept_locale(conn) == "de"
    assert conn |> init_test_session(%{}) |> Locale.call([]) |> get_session("locale") == "de"
  end

  test "mount restores locale in its own process and validates all candidates" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_account: %{locale: "de"}}
    }

    {:cont, socket} = Locale.on_mount(:set, %{}, %{"locale" => "en"}, socket)
    assert socket.assigns.locale == "en"
    assert Gettext.get_locale(Backend) == "en"

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_account: %{locale: "fr"}}
    }

    {:cont, socket} = Locale.on_mount(:set, %{}, %{"locale" => "de"}, socket)
    assert socket.assigns.locale == "de"
    {:cont, socket} = Locale.on_mount(:set, %{}, %{"locale" => "fr"}, socket)
    assert socket.assigns.locale == "en"
  end
end
