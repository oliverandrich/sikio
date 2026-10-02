# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryDetailTest do
  @moduledoc """
  The selected item, in the library's third column.

  Selecting patches the address and keeps the list and the sidebar standing. The detail renders
  beside the list from `lg` and alone below it.
  """
  use SikioWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures
  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Repo

  setup :sign_in_with_episode

  test "library opens a player and shows reversible personal status", c do
    {:ok, view, _} = live(c.conn, ~p"/")
    assert has_element?(view, "#play-#{c.entry.id}[href='/library/#{c.entry.id}']")
    view |> element("#play-#{c.entry.id}") |> render_click()
    view |> element("#mark-completed") |> render_click()
    assert has_element?(view, "#entries-#{c.entry.id}", "Listened")
    view |> element("#mark-new") |> render_click()
    assert %{playback: %{status: :new}} = Library.entry(c.user, c.entry.id)
  end

  # Under the title is the player's place. Until play is pressed it shows what plays there and
  # loads nothing from anybody else; marking and the original sit at the card's head.
  test "the detail offers the player under its title and its actions at its head", c do
    {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")

    assert has_element?(view, "#item-detail #player-slot #start-playback")
    refute has_element?(view, "#item-detail audio")
    assert has_element?(view, "#item-actions #mark-completed", "Mark as listened")
  end

  # Every item with a page of its own offers it, named for where it leads.
  test "the detail opens the original page of each kind", c do
    for {body, url} <- [{peertube(), peertube_feed_url()}, {youtube(), youtube_feed_url()}] do
      {:ok, preview} = Parser.parse(body, url)
      {:ok, _} = Library.subscribe(c.user, preview)
    end

    entries = Library.entries(c.user)

    for {kind, href, label} <- [
          {:podcast, podcast_page(), "Open episode page"},
          {:peertube, "https://video.example.org/w/mSh0rtUu1d", "Open on PeerTube"},
          {:youtube, "https://www.youtube.com/watch?v=abcdefghijk", "Open on YouTube"}
        ] do
      entry = Enum.find(entries, &(&1.feed.kind == kind))
      {:ok, view, _} = live(c.conn, ~p"/library/#{entry.id}")

      assert has_element?(
               view,
               ~s|#item-actions #open-original[href="#{href}"][target="_blank"]|,
               label
             )
    end
  end

  # An item imported before pages were kept has none until a poll names it again. A YouTube video
  # is still found by its id; anything else offers nothing rather than a guessed address.
  test "without a stored page only a YouTube video is still opened", c do
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(c.user, preview)
    Repo.update_all(Sikio.Feeds.Entry, set: [page_url: nil])
    entries = Library.entries(c.user)
    video = Enum.find(entries, &(&1.feed.kind == :youtube))

    {:ok, view, _} = live(c.conn, ~p"/library/#{video.id}")

    assert has_element?(
             view,
             "#open-original[href='https://www.youtube.com/watch?v=abcdefghijk']"
           )

    {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")
    refute has_element?(view, "#open-original")
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

  # The detail says what it is, when it appeared, how long it runs and where the reader stands:
  # how much is left once started. Nothing else trails beneath the notes.
  test "the detail's meta line says the status, and the time left once started", c do
    {:ok, %{session_id: session}} = Playback.start(c.user, c.entry.id)
    {:ok, _} = Playback.save(c.user, c.entry.id, session, %{sample(1, 900) | "duration" => 3723})

    {:ok, view, html} = live(c.conn, ~p"/library/#{c.entry.id}")
    assert has_element?(view, "#playback-status", "47 min left")
    refute has_element?(view, "#playback-status", "Saved at")
    refute html =~ "Playback stays with you"
    refute html =~ "Audio streams directly"
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
             "#item-actions #open-original[href='https://www.youtube.com/watch?v=abcdefghijk']",
             "Open on YouTube"
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

  describe "selecting" do
    setup c do
      {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
      {:ok, _} = Library.subscribe(c.user, video)
      [video] = Library.entries(c.user) -- [c.entry]
      %{video: video}
    end

    test "patches the address, keeps the list standing and marks the row", c do
      {:ok, view, _} = live(c.conn, ~p"/?status=new")

      view |> element("#play-#{c.entry.id}") |> render_click()

      assert_patch(view, "/library/#{c.entry.id}?status=new")
      assert has_element?(view, "#entries #entries-#{c.entry.id}")
      assert has_element?(view, "#item-detail h2", "One & two")
      assert has_element?(view, ~s|#play-#{c.entry.id}[aria-current="true"]|)
    end

    # j and k, as readers have moved through lists since Google Reader. The browser half that
    # decides which key presses count is `assets/js/reader_keys.mjs`.
    test "j and k move to the next and the previous item", c do
      {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")

      render_hook(view, "move", %{"key" => "j"})
      assert_patch(view, "/library/#{c.video.id}")

      render_hook(view, "move", %{"key" => "k"})
      assert_patch(view, "/library/#{c.entry.id}")
    end

    # On a wide screen the browser asks for the first item when none is chosen. The address is
    # replaced, so Back does not land on the empty view again.
    test "the first item is chosen when the browser asks and nothing is", c do
      {:ok, view, _} = live(c.conn, ~p"/?status=new")
      render_hook(view, "select_first", %{})
      assert_patch(view, "/library/#{c.entry.id}?status=new")

      view |> element("#play-#{c.video.id}") |> render_click()
      render_hook(view, "select_first", %{})
      assert has_element?(view, "#item-detail h2", "A good video")
    end

    # An item the page chose for a wide screen is let go when the screen turns narrow, where it
    # would cover the list. One the reader chose stays.
    test "an item chosen for a wide screen is let go when it narrows", c do
      {:ok, view, _} = live(c.conn, ~p"/?status=new")
      render_hook(view, "select_first", %{})
      assert_patch(view, "/library/#{c.entry.id}?status=new")
      render_hook(view, "release_first", %{})
      assert_patch(view, "/?status=new")

      view |> element("#play-#{c.video.id}") |> render_click()
      render_hook(view, "release_first", %{})
      assert has_element?(view, "#item-detail h2", "A good video")
    end

    # The row carries no buttons, so marking what is selected is a key beside j and k. Pressed
    # again it takes the mark back.
    test "m marks the selected item done, and again marks it new", c do
      {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")

      render_hook(view, "toggle_mark", %{})
      assert %{playback: %{status: :completed}} = Library.entry(c.user, c.entry.id)

      render_hook(view, "toggle_mark", %{})
      assert %{playback: %{status: :new}} = Library.entry(c.user, c.entry.id)
    end

    test "m without a selected item does nothing", c do
      {:ok, view, _} = live(c.conn, ~p"/")
      render_hook(view, "toggle_mark", %{})
      assert Library.entry(c.user, c.entry.id).playback == nil
    end

    # A selected item keeps its place in the list, opened by address or after an update alike.
    # Drawn again out of turn, it would sink to the bottom and j would skip what is on screen.
    test "the selected item keeps its place in the list", c do
      {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")
      assert rows(view) == ["entries-#{c.entry.id}", "entries-#{c.video.id}"]

      send(view.pid, :library_changed)
      assert rows(view) == ["entries-#{c.entry.id}", "entries-#{c.video.id}"]
    end

    test "an item whose source goes away leaves the detail", c do
      {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")

      subscription = Enum.find(Library.subscriptions(c.user), &(&1.feed_id == c.entry.feed_id))

      {:ok, _} = Library.unsubscribe(c.user, subscription.id)

      assert_patch(view, "/")
      refute has_element?(view, "#item-detail h2")
    end
  end

  describe "the notes" do
    test "show what the publisher wrote, without what it smuggled in", c do
      {:ok, view, _} = live(c.conn, ~p"/library/#{c.entry.id}")

      assert has_element?(view, "#item-notes p", "Notes with a")
      assert has_element?(view, ~s|#item-notes a[target="_blank"]|, "link")
      refute render(view) =~ "alert(1)"
    end

    test "an item without notes says so rather than leaving the column empty", c do
      {:ok, preview} = Parser.parse(thin_podcast(), feed_url())
      {:ok, _} = Library.subscribe(c.user, preview)
      thin = Enum.find(Library.entries(c.user), &(&1.description == nil))

      {:ok, view, _} = live(c.conn, ~p"/library/#{thin.id}")

      refute has_element?(view, "#item-notes")
      assert has_element?(view, "#item-no-notes")
    end
  end

  defp rows(view),
    do:
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("#entries article")
      |> Floki.attribute("id")
end
