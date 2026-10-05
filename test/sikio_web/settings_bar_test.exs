# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SettingsBarTest do
  @moduledoc """
  The pages beside the library on a phone: each names itself in the bar once its heading has
  scrolled away, and the bar leads back to where it belongs.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    %{conn: conn |> init_test_session(%{}) |> Gate.log_in(user)}
  end

  test "each page names itself and leads back", c do
    for {path, title, back, label} <- [
          {"/invitations", "Invitations", "/library", "Library"},
          {"/account/passkeys", "Passkeys", "/library", "Library"},
          {"/account/recovery-codes", "Recovery codes", "/library", "Library"},
          {"/add", "Add a source", "/library", "Library"},
          {"/subscriptions", "Subscriptions", "/library", "Library"},
          {"/subscriptions/import", "Import OPML", "/subscriptions", "Subscriptions"}
        ] do
      {:ok, view, _} = live(c.conn, path)
      assert has_element?(view, "#nav-title", title), path
      assert has_element?(view, ~s|#nav-back[href="#{back}"]|, label), path
      assert has_element?(view, "h1[data-large-title]"), path
    end
  end

  test "the invitations page opens on what it is for", c do
    {:ok, view, _} = live(c.conn, ~p"/invitations")
    assert has_element?(view, "h1", "Invitations")
    refute render(view) =~ "Welcome home"
  end
end
