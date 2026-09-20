# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MobileLayoutTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures
  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Repo

  test "player can be compacted without removing the active media", %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: "listener"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    Library.subscribe(user, preview)
    [entry] = Library.entries(user)
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)
    {:ok, dock, _} = live_isolated(conn, SikioWeb.PlayerDockLive)
    render_hook(dock, "start", %{id: entry.id})
    assert has_element?(dock, "#compact-player[aria-pressed=false]")
    assert has_element?(dock, "audio")
    dock |> element("#compact-player") |> render_click()
    assert has_element?(dock, "#compact-player[aria-pressed=true]")
    assert has_element?(dock, "audio")
    dock |> element("#compact-player") |> render_click()
    assert has_element?(dock, "#compact-player[aria-pressed=false]")
  end
end
