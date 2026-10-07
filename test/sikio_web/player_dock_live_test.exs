# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlayerDockLiveTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures
  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.FeedFixtures
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Repo
  alias SikioWeb.PlayerDockLive

  setup :sign_in_with_episode

  test "the authenticated root layout owns an independent player outside routed content", c do
    for path <- [~p"/", ~p"/subscriptions", ~p"/invitations", item_path(c.entry)] do
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

    # An unclaimed test instance serves /setup. A response for a signed-out visitor has no dock.
    html = build_conn() |> get(~p"/setup") |> html_response(200)
    assert Floki.find(Floki.parse_document!(html), "#player-dock") == []
  end

  # The dock renders in the root layout outside any live_session and inherits no `on_mount` hook.
  # Without its own `SikioWeb.Locale` hook it renders in English.
  test "the dock speaks the language the session asked for", c do
    conn = Plug.Conn.put_session(c.conn, "locale", "de")
    {:ok, dock, _} = live_isolated(conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})

    assert has_element?(dock, "#capsule-play[aria-label='Abspielen oder anhalten']")
    assert has_element?(dock, "[data-audio-speed][aria-label='Wiedergabegeschwindigkeit']")
  end

  # These data attributes fill the Media Session metadata in assets/js/media_player.mjs.
  # Artwork is proxied through `/pictures/`, like every other image.
  test "the player carries what the system shows of the episode", c do
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})

    assert has_element?(
             dock,
             ~s|[phx-hook="MediaPlayer"][data-title="#{c.entry.title}"][data-source="#{c.entry.feed.title}"]|
           )

    assert has_element?(dock, ~s|[phx-hook="MediaPlayer"][data-artwork^="/pictures/"]|)
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
    Playback.mark(c.user, c.entry.id, :heard)
    refute has_element?(dock, "audio")
    refute has_element?(dock, "#dock-notice")
    render_hook(dock, "start", %{id: c.entry.id})
    assert has_element?(dock, "audio")
    Library.unsubscribe(c.user, c.sub.id)
    refute has_element?(dock, "audio")
  end

  # The dock receives the account's library broadcasts.
  # A subscription update must not stop playback.
  test "a subscription changed elsewhere leaves the player playing", c do
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    {:ok, _} = Library.update_subscription(c.user, c.sub.id, %{"name" => "Renamed"})
    assert has_element?(dock, "audio")
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

  # LiveView remounts the dock after a reconnect.
  # Connect params carry the client's entry and session.
  # The dock restores the player only while that session owns the entry.
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

  # With play-on enabled, `next` after an ended item starts the queue head.
  # With play-on disabled, the dock keeps the ended item.
  test "the dock plays on with the queue when an item ends, unless told not to", c do
    {:ok, preview} = Parser.parse(FeedFixtures.podcast("Next"), FeedFixtures.feed_url("next"))
    {:ok, _} = Library.subscribe(c.user, preview)

    [following] =
      Library.entries(c.user, %{"status" => "inbox"}) |> Enum.reject(&(&1.id == c.entry.id))

    {:ok, _} = Playback.enqueue(c.user, following.id, :last)

    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    session = Library.entry(c.user, c.entry.id).playback.session_id
    render_hook(dock, "progress", %{sample(session, 1, 100) | "ended" => true})

    render_hook(dock, "next", %{})
    assert has_element?(dock, "#player-panel", following.title)

    {:ok, _} = Playback.play_on(c.user, false)
    session = Library.entry(c.user, following.id).playback.session_id
    render_hook(dock, "progress", %{sample(session, 1, 100) | "ended" => true})
    render_hook(dock, "next", %{})
    assert has_element?(dock, ~s|[phx-hook="MediaPlayer"][data-title="#{following.title}"]|)
  end

  # Marking the playing item archived or heard acts like its end.
  # With play-on the queue head starts. Without it the dock closes.
  # Marking it new closes the dock without starting the queue.
  # The archive case shows no `#dock-notice`. A takeover by another player shows one.
  test "an item marked by hand while it plays is done with quietly", c do
    {:ok, preview} = Parser.parse(FeedFixtures.podcast("Next"), FeedFixtures.feed_url("next"))
    {:ok, _} = Library.subscribe(c.user, preview)

    [following] =
      Library.entries(c.user, %{"status" => "inbox"}) |> Enum.reject(&(&1.id == c.entry.id))

    {:ok, _} = Playback.enqueue(c.user, following.id, :last)
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)

    render_hook(dock, "start", %{id: c.entry.id})
    {:ok, _} = Playback.mark(c.user, c.entry.id, :archived)
    assert has_element?(dock, ~s|[phx-hook="MediaPlayer"][data-title="#{following.title}"]|)
    refute has_element?(dock, "#dock-notice")

    {:ok, _} = Playback.play_on(c.user, false)
    {:ok, _} = Playback.mark(c.user, following.id, :heard)
    refute has_element?(dock, "#player-panel")

    {:ok, _} = Playback.play_on(c.user, true)
    {:ok, _} = Playback.enqueue(c.user, following.id, :last)
    render_hook(dock, "start", %{id: c.entry.id})
    {:ok, _} = Playback.mark(c.user, c.entry.id, :new)
    refute has_element?(dock, "#player-panel")

    render_hook(dock, "start", %{id: c.entry.id})
    {:ok, _} = Playback.start(c.user, c.entry.id)
    assert has_element?(dock, "#dock-notice", "changed")
  end

  test "playing on is the account's own setting, on until turned off", c do
    assert Playback.play_on?(c.user)
    assert {:ok, %{play_on: false}} = Playback.play_on(c.user, false)
    refute Playback.play_on?(c.user)
    assert {:ok, %{play_on: true}} = Playback.play_on(c.user, true)
    assert Playback.play_on?(c.user)
  end

  defp sample(session, sequence, position),
    do: %{
      "session" => session,
      "sequence" => sequence,
      "position" => position,
      "duration" => 100,
      "ended" => false
    }

  # Shift plus an arrow key seeks between chapters, so the player needs chapter starts.
  # Chapters in show notes are parsed by the same rule as on the detail page.
  test "the player knows the chapters of what it plays", c do
    body =
      String.replace(
        podcast("Chapters"),
        ~r|<content:encoded>.*?</content:encoded>|s,
        "<content:encoded><![CDATA[<p>0:00 Intro<br>1:58 Akkus<br>4:51 Solar</p>]]></content:encoded>"
      )

    {:ok, preview} = Parser.parse(body, feed_url())
    {:ok, _} = Library.subscribe(c.user, preview)
    entry = Enum.find(Library.entries(c.user), &(&1.feed.title == "Chapters"))

    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{"id" => entry.id})

    chapters =
      dock
      |> element("[phx-hook='MediaPlayer']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[phx-hook='MediaPlayer']")
      |> LazyHTML.attribute("data-chapters")

    assert [~s|[{"at":0,"title":"Intro"},{"at":118,"title":"Akkus"},{"at":291,"title":"Solar"}]|] ==
             chapters

    # The audio face marks chapter starts on its seek bar and shows the current chapter title.
    assert has_element?(dock, ~s|[data-audio-face] [data-audio-mark][data-at="118"]|)
    assert has_element?(dock, "[data-audio-face] [data-audio-chapter]", "Intro")
  end

  # A chapters file is fetched on first use.
  # Starting playback before the detail page was opened triggers the fetch.
  test "the player fetches the chapters file of what it plays", c do
    tag =
      ~s|<podcast:chapters href="https://example.org/dock/chapters.json" type="application/json+chapters"/>|

    body = String.replace(podcast("File"), "<itunes:duration>", tag <> "<itunes:duration>")
    {:ok, preview} = Parser.parse(body, feed_url())
    {:ok, _} = Library.subscribe(c.user, preview)
    entry = Enum.find(Library.entries(c.user), &(&1.feed.title == "File"))

    Sikio.PictureFixtures.serving(%{
      "/dock/chapters.json" =>
        {"application/json",
         ~s|{"chapters":[{"startTime":0,"title":"A"},{"startTime":90,"title":"B"}]}|}
    })

    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{"id" => entry.id})
    render_async(dock)

    assert render(dock) =~
             ~s|data-chapters="[{&quot;at&quot;:0,&quot;title&quot;:&quot;A&quot;},{&quot;at&quot;:90,&quot;title&quot;:&quot;B&quot;}]"|
  end

  # The card's seek bar sends `position` with `start`. Playback begins there.
  test "a start may name the place to begin at", c do
    {:ok, dock, _} = live_isolated(c.conn, PlayerDockLive)
    render_hook(dock, "start", %{"id" => c.entry.id, "position" => 600})
    assert has_element?(dock, "[phx-hook='MediaPlayer'][data-position='600.0']")
    assert has_element?(dock, "input[data-audio-seek][value='600']")
  end

  # Audio gets Sikio's controls. A video uses the embed's own controls inside the iframe.
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

  # The iframe uses the embed URL from the feed and adds `api=1` for the player API.
  # The URL must contain one `?`. A second one hides the parameters after it.
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
    # `p2p=0` disables WebRTC peer loading. The instance alone serves the video.
    # No peer can fail mid-stream, and no other viewer learns this viewer's IP address.
    assert src
           |> String.replace("&amp;", "&")
           |> URI.parse()
           |> Map.fetch!(:query)
           |> URI.decode_query()
           |> Map.get("p2p") == "0"

    assert html =~ ~s(data-kind="peertube")
    refute html =~ "youtube-nocookie", "nothing of YouTube's is loaded for a PeerTube video"
  end

  # Play on the detail page is the only click needed.
  # `autoplay=1` skips the embed's poster with its second play button.
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

  # YouTube enables captions for some videos by default. The URL sets `cc_load_policy=0`.
  # The JS player also unloads captions, since YouTube sometimes ignores the parameter.
  test "a YouTube embed asks for no captions", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(user, preview)
    entry = Enum.find(Library.entries(user), &(&1.feed.kind == :youtube))

    {:ok, dock, _html} = live_isolated(conn, PlayerDockLive)
    render_hook(dock, "start", %{"id" => entry.id})
    [_, src] = Regex.run(~r|src="([^"]+)"|, dock |> element("iframe") |> render())
    query = src |> String.replace("&amp;", "&") |> URI.parse() |> Map.fetch!(:query)

    assert URI.decode_query(query)["cc_load_policy"] == "0"
  end

  # The feed's embed URL can already carry a query.
  # A second `?` would hide `api=1` from the embed.
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
