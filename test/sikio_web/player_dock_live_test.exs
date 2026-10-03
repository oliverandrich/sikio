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

  setup :sign_in_with_episode

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
    assert has_element?(dock, "[data-audio-speed][aria-label='Wiedergabegeschwindigkeit']")
  end

  test "one active player saves and closes without losing progress", c do
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    assert has_element?(dock, "#player-panel", c.entry.title)
    assert has_element?(dock, "[data-audio-face]")
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

  # LiveView mounts the dock again after every reconnect. The browser names the player it still
  # holds, and the dock takes it back only while that session still owns the entry.
  test "a reconnect restores the player the browser still holds", c do
    session = started_session(c)

    {:ok, rejoined, _} = c.conn |> rejoining(c.entry.id, session) |> live_isolated(PlayerDockLive)

    assert has_element?(rejoined, "#player-#{session}")
    render_hook(rejoined, "progress", sample(session, 1, 30))
    assert Library.entry(c.user, c.entry.id).playback.position == 30
  end

  test "a reconnect after another player took over says why this one stopped", c do
    session = started_session(c)
    {:ok, _} = Playback.start(c.user, c.entry.id)

    {:ok, rejoined, _} = c.conn |> rejoining(c.entry.id, session) |> live_isolated(PlayerDockLive)

    assert has_element?(rejoined, "#player-panel", c.entry.title)
    assert has_element?(rejoined, "#dock-notice", "changed")
    refute has_element?(rejoined, "audio")
  end

  test "a reconnect cannot take over another account's player", c do
    session = started_session(c)
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = build_conn() |> init_test_session(%{}) |> Gate.log_in(other)

    {:ok, rejoined, _} = conn |> rejoining(c.entry.id, session) |> live_isolated(PlayerDockLive)

    refute has_element?(rejoined, "#player-panel")
  end

  test "a reconnect with a malformed player is an empty dock", c do
    {:ok, rejoined, _} =
      c.conn
      |> put_connect_params(%{"player_entry" => "nope", "player_session" => 7})
      |> live_isolated(PlayerDockLive)

    refute has_element?(rejoined, "#player-panel")
  end

  defp started_session(c) do
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    Library.entry(c.user, c.entry.id).playback.session_id
  end

  defp rejoining(conn, id, session),
    do: put_connect_params(conn, %{"player_entry" => to_string(id), "player_session" => session})

  defp sample(session, sequence, position),
    do: %{
      "session" => session,
      "sequence" => sequence,
      "position" => position,
      "duration" => 100,
      "ended" => false
    }

  # The card's player starts where it was dragged to.
  test "a start may name the place to begin at", c do
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{"id" => c.entry.id, "position" => 600})
    assert has_element?(dock, "[phx-hook='MediaPlayer'][data-position='600.0']")
    assert has_element?(dock, "input[data-audio-seek][value='600']")
  end

  # Audio plays under Sikio's own face. A video brings its own player inside its frame.
  test "audio gets Sikio's face and a video does not", %{conn: conn, user: user} = c do
    {:ok, dock, _} = live_isolated(conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    assert has_element?(dock, "[data-audio-face]")

    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, _} = Library.subscribe(user, preview)
    video = Enum.find(Library.entries(user), &(&1.feed.kind == :peertube))
    render_hook(dock, "start", %{id: video.id})
    refute has_element?(dock, "[data-audio-face]")
  end

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
    # Without peer to peer the instance alone serves the video: no mirror that may fail, and no
    # other viewer who learns this one's address.
    assert src
           |> String.replace("&amp;", "&")
           |> URI.parse()
           |> Map.fetch!(:query)
           |> URI.decode_query()
           |> Map.get("p2p") == "0"

    assert html =~ ~s(data-kind="peertube")
    refute html =~ "youtube-nocookie", "nothing of YouTube's is loaded for a PeerTube video"
  end

  # Pressing play on the detail's cue is the one click. The embed starts on its own, instead of
  # showing its own picture with a second play button.
  test "both embeds start playing once they load", %{conn: conn, user: user} do
    for {body, url} <- [{peertube(), peertube_feed_url()}, {youtube(), youtube_feed_url()}] do
      {:ok, preview} = Parser.parse(body, url)
      {:ok, _} = Library.subscribe(user, preview)
    end

    {:ok, dock, _html} = live_isolated(conn, PlayerDockLive)

    for kind <- [:peertube, :youtube] do
      entry = Enum.find(Library.entries(user), &(&1.feed.kind == kind))
      render_hook(dock, "start", %{"id" => entry.id})
      [_, src] = Regex.run(~r|src="([^"]+)"|, dock |> element("iframe") |> render())
      src = String.replace(src, "&amp;", "&")

      assert src
             |> URI.parse()
             |> Map.fetch!(:query)
             |> URI.decode_query()
             |> Map.get("autoplay") == "1"
    end
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
