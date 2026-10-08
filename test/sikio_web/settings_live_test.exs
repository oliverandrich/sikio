# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SettingsLiveTest do
  @moduledoc """
  The settings page holds a member's preferences. Each change saves at once.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Preferences
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    %{conn: conn |> init_test_session(%{}) |> Gate.log_in(user), user: user}
  end

  test "the gear menu leads to the settings", c do
    {:ok, view, _} = live(c.conn, ~p"/library")
    assert has_element?(view, ~s|#user-menu a#settings-link[href="/account/settings"]|)
  end

  # Play on lives here alone. The queue has no switch for it.
  test "Play on is saved as soon as it changes", c do
    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    assert has_element?(view, ~s|#settings-form input[name="play_on"][type="checkbox"][checked]|)

    assert view
           |> element("#settings-saved")
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.text()
           |> String.trim() == ""

    view |> form("#settings-form", %{"play_on" => "false"}) |> render_change()
    refute Preferences.play_on?(c.user)
    assert has_element?(view, "#settings-saved", "Saved.")

    {:ok, view, _} = live(c.conn, ~p"/queue")
    refute has_element?(view, "#play-on")
  end

  # A chosen language overrides the browser's on every member page, from the first render.
  test "a chosen language reloads the page in it", c do
    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    view |> form("#settings-form", %{"locale" => "de"}) |> render_change()
    assert_redirect(view, ~p"/account/settings")
    assert Preferences.get(c.user).locale == "de"

    html =
      c.conn |> put_req_header("accept-language", "en") |> get(~p"/library") |> html_response(200)

    assert html =~ ~s(lang="de")

    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    assert has_element?(view, "h1", "Einstellungen")

    # Pages outside LiveView follow the choice too, since the request already knows it.
    html =
      c.conn |> put_req_header("accept-language", "en") |> get(~p"/library") |> html_response(200)

    assert html =~ "Einstellungen"

    # The browser's language applies again once the choice is cleared.
    view |> form("#settings-form", %{"locale" => ""}) |> render_change()
    assert_redirect(view, ~p"/account/settings")
    assert Preferences.get(c.user).locale == nil
  end

  # A stored language that the instance no longer offers falls back to the browser's.
  test "an unsupported stored language follows the browser", c do
    {:ok, _} = Preferences.update(c.user, %{locale: "de"})
    Repo.update_all(Sikio.Preferences.Preference, set: [locale: "fr"])

    conn = c.conn |> put_req_header("accept-language", "en") |> get(~p"/library")
    assert get_session(conn, "locale") == "en"
  end

  # The request resolves the chosen language and hands it to the LiveView in the session.
  test "the request carries the chosen language in the session", c do
    {:ok, _} = Preferences.update(c.user, %{locale: "de"})
    conn = c.conn |> put_req_header("accept-language", "en") |> get(~p"/library")
    assert get_session(conn, "locale") == "de"
  end

  # A failed save shows the stored values and no confirmation.
  test "a value the instance does not offer is not saved", c do
    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    view |> form("#settings-form", %{"play_on" => "false"}) |> render_change()
    assert has_element?(view, "#settings-saved", "Saved.")

    render_change(view, "save", %{"play_on" => "true", "locale" => "fr"})
    refute has_element?(view, "#settings-saved", "Saved.")
    assert render(view) =~ "The settings could not be saved."
    refute has_element?(view, ~s|#settings-form input[name="play_on"][type="checkbox"][checked]|)
  end
end
