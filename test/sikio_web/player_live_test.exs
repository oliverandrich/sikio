# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlayerLiveTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures
  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, _} = Library.subscribe(user, preview)
    [entry] = Library.entries(user)
    %{conn: conn |> init_test_session(%{}) |> Gate.log_in(user), user: user, entry: entry}
  end

  test "library opens a player and shows reversible personal status", c do
    {:ok, view, _} = live(c.conn, ~p"/")
    assert has_element?(view, "#play-#{c.entry.id}[href='/library/#{c.entry.id}']")
    view |> element("#complete-#{c.entry.id}") |> render_click()
    assert has_element?(view, "#entries-#{c.entry.id}", "Listened")
    view |> element("#reset-#{c.entry.id}") |> render_click()
    assert %{playback: %{status: :new}} = Library.entry(c.user, c.entry.id)
  end

  test "audio loads on request, resumes and saves only the active entry", c do
    {:ok, state} = Playback.start(c.user, c.entry.id)
    Playback.save(c.user, c.entry.id, state.session_id, sample(1, 42))
    {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")
    refute has_element?(view, "audio")
    assert has_element?(view, "#start-playback", "Resume")
    assert view |> element("#start-playback") |> render() =~ "sikio:play"
    {:ok, dock, _} = live_isolated(c.conn, SikioWeb.PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    assert has_element?(dock, "[phx-hook='MediaPlayer'][data-position='42.0'] audio[controls]")
    assert has_element?(dock, "#playback-speed")
    session = Library.entry(c.user, c.entry.id).playback.session_id

    render_hook(
      dock,
      "progress",
      Map.merge(sample(2, 65), %{"session" => session, "entry_id" => "999999"})
    )

    assert %{playback: %{position: 65.0}} = Library.entry(c.user, c.entry.id)
    view |> element("#mark-completed") |> render_click()
    refute has_element?(dock, "audio")
    render_hook(dock, "progress", Map.put(sample(3, 80), "session", session))
    assert %{playback: %{status: :completed, position: 65.0}} = Library.entry(c.user, c.entry.id)
    view |> element("#mark-new") |> render_click()
    assert has_element?(view, "#playback-status", "New")
  end

  test "YouTube is not contacted before play and iframe identifies only the origin", c do
    {:ok, preview} =
      Parser.parse(
        youtube(),
        youtube_feed_url()
      )

    {:ok, sub} = Library.subscribe(c.user, preview)
    entry = Enum.find(Library.entries(c.user), &(&1.feed_id == sub.feed_id))
    {:ok, view, _} = live(c.conn, ~p"/library/#{entry.id}")
    refute has_element?(view, "iframe")
    refute has_element?(view, "[phx-hook='MediaPlayer']")
    {:ok, dock, _} = live_isolated(c.conn, SikioWeb.PlayerDockLive)
    render_hook(dock, "start", %{id: entry.id})

    assert has_element?(
             dock,
             "iframe[referrerpolicy='strict-origin-when-cross-origin'][src*='youtube-nocookie.com/embed/abcdefghijk']"
           )

    assert has_element?(
             view,
             "#open-original[href='https://www.youtube.com/watch?v=abcdefghijk']"
           )
  end

  test "another player makes old progress visibly stale", c do
    {:ok, dock, _} = live_isolated(c.conn, SikioWeb.PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    old = Library.entry(c.user, c.entry.id).playback
    Playback.start(c.user, c.entry.id)
    render_hook(dock, "progress", Map.put(sample(1, 30), "session", old.session_id))
    assert has_element?(dock, "#dock-notice", "another player")
    refute has_element?(dock, "audio")
  end

  test "late notifications cannot undo a manual status change on the detail page", c do
    {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")
    {:ok, old} = Playback.start(c.user, c.entry.id)
    view |> element("#mark-completed") |> render_click()
    send(view.pid, {:playback_changed, old})
    assert has_element?(view, "#playback-status", "Listened")
  end

  test "private entries and malformed IDs cannot be opened", c do
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = build_conn() |> init_test_session(%{}) |> Gate.log_in(other)
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/library/#{c.entry.id}")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(c.conn, ~p"/library/invalid")
  end

  defp sample(sequence, position),
    do: %{"sequence" => sequence, "position" => position, "duration" => 100, "ended" => false}
end
