# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SettingsLiveTest do
  @moduledoc """
  The settings page holds a member's preferences. Each change saves at once.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Preferences
  alias Sikio.Preferences.Preference
  alias Sikio.Repo
  alias Sikio.Tags

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    %{conn: conn |> init_test_session(%{}) |> Gate.log_in(user), user: user}
  end

  # The gear menu holds the settings, the shortcuts and the about dialog. Account pages are
  # rows on the settings page, and their back links lead there.
  test "the gear menu leads to the settings, which lead to the account pages", c do
    {:ok, view, _} = live(c.conn, ~p"/library")
    assert has_element?(view, ~s|#user-menu a#settings-link[href="/account/settings"]|)
    refute has_element?(view, ~s|#user-menu a[href="/invitations"]|)
    refute has_element?(view, ~s|#user-menu a[href="/account/passkeys"]|)

    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    assert has_element?(view, ~s|#settings-account a[href="/account/passkeys"]|, "0")
    assert has_element?(view, ~s|#settings-account a[href="/account/recovery-codes"]|, "0")
    assert has_element?(view, ~s|#settings-account a[href="/invitations"]|)

    {:ok, view, _} = live(c.conn, ~p"/invitations")
    assert has_element?(view, ~s|#nav-back[href="/account/settings"]|)
  end

  # Play on lives here alone. The queue has no switch for it.
  test "Play on is saved as soon as it changes", c do
    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    assert has_element?(view, ~s|#settings-form input[name="play_on"][role="switch"][checked]|)

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
    Repo.update_all(Preference, set: [locale: "fr"])

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

  # The start page is the queue, the inbox or one of the account's tags. / opens it.
  test "the chosen start page opens at /", c do
    {:ok, preview} =
      Parser.parse(podcast(), feed_url())

    {:ok, sub} = Library.subscribe(c.user, preview)
    {:ok, [tag]} = Tags.set(c.user, sub.id, ["Tech"])

    {:ok, view, _} = live(c.conn, ~p"/account/settings")

    assert has_element?(
             view,
             ~s|#settings-form select[name="start"] option[value="queue"][selected]|
           )

    view |> form("#settings-form", %{"start" => "inbox"}) |> render_change()
    {:ok, view, _} = live(c.conn, ~p"/")
    assert has_element?(view, "#view-inbox[aria-current=page]")

    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    view |> form("#settings-form", %{"start" => "tag-#{tag.id}"}) |> render_change()
    {:ok, view, _} = live(c.conn, ~p"/")
    assert has_element?(view, "#library-heading", "Tech")

    # A deleted start tag falls back to the list chosen before it.
    Tags.delete(c.user, tag.id)
    {:ok, view, _} = live(c.conn, ~p"/")
    assert has_element?(view, "#view-inbox[aria-current=page]")
  end

  # A change saves only its own field. A start tag deleted in another tab leaves the select
  # on its first option, which must not overwrite the start page.
  test "a change saves its own field and keeps a start page the form shows stale", c do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, sub} = Library.subscribe(c.user, preview)
    {:ok, [tag]} = Tags.set(c.user, sub.id, ["Tech"])
    {:ok, _} = Preferences.update(c.user, %{start_view: "inbox", start_tag_id: tag.id})

    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    Tags.delete(c.user, tag.id)

    # The browser names the changed field in `_target`; the test helper sends it only on request.
    view
    |> form("#settings-form", %{"play_on" => "false"})
    |> render_change(%{"_target" => ["play_on"]})

    assert %{play_on: false, start_view: "inbox", start_tag_id: nil} = Preferences.get(c.user)
  end
end
