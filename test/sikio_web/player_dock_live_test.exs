# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlayerDockLiveTest do
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
  alias SikioWeb.PlayerDockLive

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, sub} = Library.subscribe(user, preview)
    [entry] = Library.entries(user)

    %{
      conn: conn |> init_test_session(%{}) |> Gate.log_in(user),
      user: user,
      entry: entry,
      sub: sub
    }
  end

  test "the authenticated root layout owns an independent player outside routed content", c do
    for path <- [~p"/", ~p"/subscriptions", ~p"/invitations", ~p"/library/#{c.entry.id}"] do
      html = c.conn |> get(path) |> html_response(200)
      document = Floki.parse_document!(html)

      assert [_] =
               Floki.find(
                 document,
                 "body > #player-dock > [data-phx-session]:not([data-phx-main])"
               )

      assert Floki.find(document, "#main-content #player-dock") == []
      assert Floki.find(document, "audio, iframe") == []
    end

    # An unclaimed instance answers /setup here; what matters is that a visitor without an
    # account is served no dock at all, on whichever public screen answers.
    html = build_conn() |> get(~p"/setup") |> html_response(200)
    assert Floki.find(Floki.parse_document!(html), "#player-dock") == []
  end

  # The dock renders from the root layout, so it belongs to no live_session and inherits no hook
  # from one. Without its own it answers a German session in English.
  test "the dock speaks the language the session asked for", c do
    conn = Plug.Conn.put_session(c.conn, "locale", "de")
    {:ok, dock, _} = live_isolated(conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})

    assert has_element?(dock, "#compact-player[aria-label='Player verkleinern']")
    assert has_element?(dock, "label", "Geschwindigkeit")
  end

  test "one active player saves and closes without losing progress", c do
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    assert has_element?(dock, "#player-panel", c.entry.title)
    assert has_element?(dock, "audio[controls]")
    session = Library.entry(c.user, c.entry.id).playback.session_id
    render_hook(dock, "progress", sample(session, 1, 41))
    render_hook(dock, "start", %{id: c.entry.id})
    assert Library.entry(c.user, c.entry.id).playback.session_id == session
    render_hook(dock, "close", %{})
    refute has_element?(dock, "audio")
    assert %{playback: %{position: 41.0, session_id: nil}} = Library.entry(c.user, c.entry.id)
    render_hook(dock, "progress", sample(session, 2, 90))
    assert Library.entry(c.user, c.entry.id).playback.position == 41
  end

  test "manual status changes and removed subscriptions stop the player immediately", c do
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    Playback.mark(c.user, c.entry.id, :completed)
    refute has_element?(dock, "audio")
    assert has_element?(dock, "#dock-notice", "changed")
    render_hook(dock, "start", %{id: c.entry.id})
    assert has_element?(dock, "audio")
    Library.unsubscribe(c.user, c.sub.id)
    refute has_element?(dock, "audio")
  end

  test "switching to a different episode invalidates the old session", c do
    {:ok, preview} = Parser.parse(podcast("Another show"), "https://other.example.org/rss")
    {:ok, second_sub} = Library.subscribe(c.user, preview)
    second = Enum.find(Library.entries(c.user), &(&1.feed_id == second_sub.feed_id))
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    old = Library.entry(c.user, c.entry.id).playback.session_id
    render_hook(dock, "progress", sample(old, 1, 23))
    render_hook(dock, "start", %{id: second.id})
    assert %{playback: %{session_id: nil, position: 23.0}} = Library.entry(c.user, c.entry.id)
    assert has_element?(dock, "#player-panel", "Another show")
    assert length(Floki.find(Floki.parse_fragment!(render(dock)), "audio")) == 1
    render_hook(dock, "progress", sample(old, 2, 50))
    assert Library.entry(c.user, second.id).playback.position == 0
  end

  test "unauthenticated and unrelated accounts cannot start this item", c do
    assert {:error, {:redirect, %{to: "/login"}}} = live_isolated(build_conn(), PlayerDockLive)
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = build_conn() |> init_test_session(%{}) |> Gate.log_in(other)
    {:ok, dock, _} = live_isolated(conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    refute has_element?(dock, "audio")
    assert has_element?(dock, "#dock-notice", "no longer")
  end

  defp sample(session, sequence, position),
    do: %{
      "session" => session,
      "sequence" => sequence,
      "position" => position,
      "duration" => 100,
      "ended" => false
    }

  # The instance plays its own video, so the dock points at the embed the feed named and adds
  # only what the api needs: permission to talk, and the place to resume from. What the feed
  # names may already carry a query, and a second question mark hides everything after it.
  test "a PeerTube entry is framed by the instance that holds it", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, _} = Library.subscribe(user, preview)

    entry = Enum.find(Library.entries(user), &(&1.feed.kind == :peertube))

    {:ok, dock, _html} = live_isolated(conn, PlayerDockLive)
    render_hook(dock, "start", %{"id" => entry.id})
    html = render(dock)

    assert html =~ "https://video.example.org/videos/embed/mSh0rtUu1d"
    assert html =~ "api=1"
    src = Regex.run(~r|src="(https://video[^"]+)"|, html) |> Enum.at(1)
    assert String.contains?(src, "api=1")
    assert length(String.split(src, "?")) == 2, "an address gets one question mark, not two"
    assert html =~ ~s(data-kind="peertube")
    refute html =~ "youtube-nocookie", "nothing of YouTube's is loaded for a PeerTube video"
  end

  # What the feed names is the instance's own address and may already carry a query. A second
  # question mark hides everything after it, so the embed never sees that it may speak.
  test "an embed address that already has a query still gets one question mark", %{
    conn: conn,
    user: user
  } do
    body =
      String.replace(
        peertube(),
        ~s|url="https://video.example.org/videos/embed/mSh0rtUu1d"|,
        ~s|url="https://video.example.org/videos/embed/mSh0rtUu1d?title=0"|
      )

    {:ok, preview} = Parser.parse(body, peertube_feed_url())
    {:ok, _} = Library.subscribe(user, preview)
    entry = Enum.find(Library.entries(user), &(&1.feed.kind == :peertube))

    {:ok, dock, _html} = live_isolated(conn, PlayerDockLive)
    render_hook(dock, "start", %{"id" => entry.id})

    src = Regex.run(~r|src="(https://video[^"]+)"|, render(dock)) |> Enum.at(1)

    assert length(String.split(src, "?")) == 2
    assert src =~ "title=0"
    assert src =~ "api=1"
  end
end
