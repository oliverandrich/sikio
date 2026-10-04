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

  # An item goes into the queue first or last, and out of it again. It can be marked heard, put
  # aside, and brought back to the inbox, each from its card.
  test "the card queues, marks and archives its item", c do
    {:ok, view, _} = live(c.conn, item_path(c.entry))

    view |> element("#queue-first") |> render_click()
    assert Playback.queue(c.user) == [c.entry.id]
    assert has_element?(view, "#playback-status", "In the queue")

    view |> element("#dequeue") |> render_click()
    assert Playback.queue(c.user) == []
    assert has_element?(view, "#queue-last")

    view |> element("#queue-last") |> render_click()
    view |> element("#archive") |> render_click()
    assert %{playback: %{status: :archived, queue_rank: nil}} = Library.entry(c.user, c.entry.id)
    assert has_element?(view, "#mark-new")
    refute has_element?(view, "#archive")

    view |> element("#mark-new") |> render_click()
    assert %{playback: %{status: :new}} = Library.entry(c.user, c.entry.id)

    view |> element("#mark-completed") |> render_click()
    assert %{playback: %{status: :heard}} = Library.entry(c.user, c.entry.id)
  end

  # The card's head offers what comes next for its item, and a menu holds the rest. New, it is
  # queued or archived; queued, it is marked heard; heard or archived, it is queued again.
  test "the card's head offers what comes next for its item", c do
    {:ok, view, _} = live(c.conn, item_path(c.entry))

    assert has_element?(view, "#item-actions > #queue-menu #queue-first")
    assert has_element?(view, "#item-actions > #queue-menu #queue-last")
    assert has_element?(view, "#item-actions > #archive")
    assert has_element?(view, "#item-more #mark-completed")
    assert has_element?(view, "#item-more #open-original")

    view |> element("#queue-last") |> render_click()
    assert has_element?(view, "#playback-status", "In the queue")
    assert has_element?(view, "#item-actions > #mark-completed")
    assert has_element?(view, "#item-more #dequeue")
    assert has_element?(view, "#item-more #archive")
    refute has_element?(view, "#queue-menu")

    view |> element("#mark-completed") |> render_click()
    assert has_element?(view, "#item-actions > #queue-menu", "Queue again")
    assert has_element?(view, "#item-more #mark-new")
    refute has_element?(view, "#archive")

    view |> element("#mark-new") |> render_click()
    view |> element("#archive") |> render_click()
    assert has_element?(view, "#item-actions > #queue-menu #queue-first")
    assert has_element?(view, "#item-more #mark-completed")
    assert has_element?(view, "#item-more #mark-new")
  end

  test "library opens a player and shows reversible personal status", c do
    {:ok, view, _} = live(c.conn, ~p"/all")
    assert has_element?(view, "#play-#{c.entry.id}[href='/all/#{c.entry.id}-one-two']")
    view |> element("#play-#{c.entry.id}") |> render_click()
    view |> element("#mark-completed") |> render_click()
    assert has_element?(view, "#entries-#{c.entry.id}", "Listened")
    view |> element("#mark-new") |> render_click()
    assert %{playback: %{status: :new}} = Library.entry(c.user, c.entry.id)
  end

  # Above the title is the player's place. Until play is pressed it shows what plays there and
  # loads nothing from anybody else; marking and the original sit at the card's head.
  test "the detail offers the player above its title and its actions at its head", c do
    {:ok, view, _} = live(c.conn, item_path(c.entry))

    assert has_element?(view, "#item-detail #player-slot #start-playback")
    refute has_element?(view, "#item-detail audio")
    # An episode shows the player itself, which loads nothing until it is used.
    assert has_element?(
             view,
             "#player-slot #audio-cue[data-audio-face] #start-playback[data-audio-play]"
           )

    assert has_element?(view, "#audio-cue input[type=range][data-audio-seek][max='3723']")
    assert has_element?(view, "#audio-cue button[data-audio-speed][disabled]")
    assert has_element?(view, "#item-actions #mark-completed", "Mark as listened")
  end

  # Every item with a page of its own offers it, named for where it leads, and its medium in the
  # meta line leads there too.
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
      {:ok, view, _} = live(c.conn, item_path(entry))

      assert has_element?(
               view,
               ~s|#item-actions #open-original[href="#{href}"][target="_blank"]|,
               label
             )

      assert has_element?(view, ~s|#playback-status a[href="#{href}"][target="_blank"]|)
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

    {:ok, view, _} = live(c.conn, item_path(video))

    assert has_element?(
             view,
             "#open-original[href='https://www.youtube.com/watch?v=abcdefghijk']"
           )

    {:ok, view, _} = live(c.conn, item_path(c.entry))
    refute has_element?(view, "#open-original")
    assert has_element?(view, "#playback-status", "Podcast")
    refute has_element?(view, "#playback-status a")
  end

  # One way at a time: anything not finished can be marked as finished, and only a finished item
  # can be put back. Started counts as not finished.
  test "the card offers the one mark that changes the status", c do
    {:ok, _} = Playback.start(c.user, c.entry.id)
    %{playback: %{session_id: session}} = Library.entry(c.user, c.entry.id)

    {:ok, _} =
      Playback.save(c.user, c.entry.id, session, %{
        "sequence" => 1,
        "position" => 30,
        "duration" => 3723,
        "ended" => false
      })

    {:ok, view, _} = live(c.conn, item_path(c.entry))
    assert has_element?(view, "#playback-status", "min left")
    assert has_element?(view, "#mark-completed")
    refute has_element?(view, "#mark-new")

    view |> element("#mark-completed") |> render_click()
    assert has_element?(view, "#mark-new")
    refute has_element?(view, "#mark-completed")
  end

  # Chapters a publisher listed in the notes stand in a box between the title and the notes,
  # and only there. Each starts the item at its place; the one reached is marked.
  test "the detail lists the chapters the notes name, once", c do
    chapters = "<p>Worum es geht.</p><p>0:00 Intro<br>1:58 Akkus<br>4:51 Solar</p>"

    body =
      String.replace(
        podcast(),
        ~r|<content:encoded>.*?</content:encoded>|s,
        "<content:encoded><![CDATA[#{chapters}]]></content:encoded>"
      )

    {:ok, preview} = Parser.parse(body, feed_url())
    {:ok, _} = Library.subscribe(c.user, preview)
    entry = Enum.find(Library.entries(c.user), &(&1.feed_id != c.entry.feed_id))

    {:ok, view, _} = live(c.conn, item_path(entry))
    assert has_element?(view, "#item-chapters li", "Akkus")
    assert view |> element("#item-chapters") |> render() =~ "1:58"
    refute view |> element("#item-notes") |> render() =~ "Akkus"
    assert has_element?(view, "#item-notes", "Worum es geht.")

    play = view |> element("#item-chapters li:nth-child(2) button") |> render()
    assert play =~ "sikio:play"
    assert play =~ "&quot;position&quot;:118"
    refute has_element?(view, "#item-chapters [aria-current]")

    {:ok, state} = Playback.start(c.user, entry.id)

    Playback.save(c.user, entry.id, state.session_id, %{
      "sequence" => 1,
      "position" => 130,
      "duration" => 3723,
      "ended" => false
    })

    assert has_element?(view, ~s|#item-chapters li:nth-child(2) button[aria-current="true"]|)
  end

  # Chapters the feed names win over chapters read from the notes, from two upward, and the
  # notes are then left as they are. A file of chapters is fetched once the item is opened.
  describe "chapters a podcast's feed names" do
    defp feed_entry(c, extra) do
      body = String.replace(podcast("Podigee"), "<itunes:duration>", extra <> "<itunes:duration>")
      {:ok, preview} = Parser.parse(body, feed_url())
      {:ok, _} = Library.subscribe(c.user, preview)
      Enum.find(Library.entries(c.user), &(&1.feed.title == "Podigee"))
    end

    test "are listed in place of the notes' own, which stay as they are", c do
      entry =
        feed_entry(c, """
        <psc:chapters xmlns:psc="http://podlove.org/simple-chapters">
          <psc:chapter start="00:00:00" title="Begrüßung" />
          <psc:chapter start="00:05:00" title="Thema" />
        </psc:chapters>
        """)

      {:ok, view, _} = live(c.conn, item_path(entry))
      assert has_element?(view, "#item-chapters li", "Begrüßung")
      assert has_element?(view, "#item-chapters li", "Thema")
    end

    test "a single chapter is no list", c do
      entry =
        feed_entry(c, """
        <psc:chapters xmlns:psc="http://podlove.org/simple-chapters">
          <psc:chapter start="00:00:00" title="Pferde" />
        </psc:chapters>
        """)

      {:ok, view, _} = live(c.conn, item_path(entry))
      refute has_element?(view, "#item-chapters")
    end

    test "a linked file is fetched once the item is opened", c do
      entry =
        feed_entry(
          c,
          ~s|<podcast:chapters href="https://example.org/opened/chapters.json" type="application/json+chapters"/>|
        )

      Sikio.PictureFixtures.serving(%{
        "/opened/chapters.json" =>
          {"application/json",
           ~s|{"version":"1.2.0","chapters":[{"startTime":0,"title":"Pferde"},{"startTime":90,"title":"Esel"}]}|}
      })

      {:ok, view, _} = live(c.conn, item_path(entry))
      assert render_async(view) =~ "Esel"
      assert has_element?(view, "#item-chapters li", "Pferde")
    end
  end

  # A player that measures the length, or corrects one the feed got wrong, may make a list
  # possible that the stated length ruled out. The detail reads the chapters again then.
  test "chapters a wrong length hid appear once the length is measured", c do
    chapters = "<p>0:00 Intro<br>1:58 Akkus<br>4:51 Solar</p>"

    body =
      podcast()
      |> String.replace(
        ~r|<content:encoded>.*?</content:encoded>|s,
        "<content:encoded><![CDATA[#{chapters}]]></content:encoded>"
      )
      |> String.replace(
        ~r|<itunes:duration>[^<]*</itunes:duration>|,
        "<itunes:duration>100</itunes:duration>"
      )

    {:ok, preview} = Parser.parse(body, feed_url())
    {:ok, _} = Library.subscribe(c.user, preview)
    entry = Enum.find(Library.entries(c.user), &(&1.feed_id != c.entry.feed_id))

    {:ok, view, _} = live(c.conn, item_path(entry))
    refute has_element?(view, "#item-chapters")

    {:ok, state} = Playback.start(c.user, entry.id)

    Playback.save(c.user, entry.id, state.session_id, %{
      "sequence" => 1,
      "position" => 10,
      "duration" => 1000,
      "ended" => false
    })

    assert has_element?(view, "#item-chapters li", "Solar")
  end

  # A feed may name no length. The bar then has no range of its own, so it keeps the saved place
  # rather than falling back to the start, and cannot be dragged before the audio knows its length.
  test "without a length the card's player keeps the saved place", c do
    {:ok, preview} = Parser.parse(thin_podcast(), feed_url())
    {:ok, _} = Library.subscribe(c.user, preview)
    entry = Enum.find(Library.entries(c.user), &is_nil(&1.duration))
    {:ok, state} = Playback.start(c.user, entry.id)

    Playback.save(c.user, entry.id, state.session_id, %{
      "sequence" => 1,
      "position" => 600,
      "duration" => nil,
      "ended" => false
    })

    {:ok, view, _} = live(c.conn, item_path(entry))

    assert has_element?(
             view,
             "#audio-cue input[data-audio-seek][value='600'][max='600'][disabled]"
           )

    refute has_element?(view, "#audio-cue input[data-audio-seek][data-length]")
  end

  test "audio loads on request, resumes and saves only the active entry", c do
    {:ok, state} = Playback.start(c.user, c.entry.id)
    Playback.save(c.user, c.entry.id, state.session_id, sample(1, 42))
    {:ok, view, _} = live(c.conn, item_path(c.entry))
    refute has_element?(view, "audio")
    assert has_element?(view, "#start-playback[aria-label='Resume']")
    assert has_element?(view, "#audio-cue input[data-audio-seek][value='42']")
    assert has_element?(view, "#audio-cue [data-audio-elapsed]", "0:42")
    assert has_element?(view, "#audio-cue[phx-hook='AudioCue'][data-entry-id='#{c.entry.id}']")
    {:ok, dock, _} = live_isolated(c.conn, SikioWeb.PlayerDockLive)
    render_hook(dock, "start", %{id: c.entry.id})
    # Sikio's own face over an audio element that keeps no controls of its own.
    assert has_element?(
             dock,
             "[phx-hook='MediaPlayer'][data-position='42.0'] audio:not([controls])"
           )

    assert has_element?(dock, "[data-audio-face] button[data-audio-play][aria-label='Play']")

    assert has_element?(
             dock,
             "[data-audio-face] input[type=range][data-audio-seek][aria-label='Position']"
           )

    assert has_element?(
             dock,
             "[data-audio-face] button[data-audio-skip='-15'][aria-label='15 seconds back']"
           )

    assert has_element?(
             dock,
             "[data-audio-face] button[data-audio-skip='30'][aria-label='30 seconds forward']"
           )

    assert has_element?(
             dock,
             "[data-audio-face] button[data-audio-speed][aria-label='Playback speed']",
             "1×"
           )

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
    assert %{playback: %{status: :heard, position: 65.0}} = Library.entry(c.user, c.entry.id)
    view |> element("#mark-new") |> render_click()
    assert has_element?(view, "#playback-status", "New")
  end

  # The detail says what it is, when it appeared, how long it runs and where the reader stands:
  # how much is left once started. Nothing else trails beneath the notes.
  test "the detail's meta line says the status, and the time left once started", c do
    {:ok, %{session_id: session}} = Playback.start(c.user, c.entry.id)
    {:ok, _} = Playback.save(c.user, c.entry.id, session, %{sample(1, 900) | "duration" => 3723})

    {:ok, view, html} = live(c.conn, item_path(c.entry))
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
    {:ok, view, _} = live(c.conn, item_path(entry))
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
    {:ok, view, _} = live(c.conn, item_path(c.entry))
    {:ok, old} = Playback.start(c.user, c.entry.id)
    view |> element("#mark-completed") |> render_click()
    send(view.pid, {:playback_changed, old})
    assert has_element?(view, "#playback-status", "Listened")
  end

  # Only the number in an address is looked up. A title after it that reads otherwise, from a
  # rename or typed by hand, is set right.
  test "an address with another title after the number is corrected", c do
    {:ok, view, _} =
      c.conn
      |> live("/all/#{c.entry.id}-renamed")
      |> follow_redirect(c.conn, "/all/#{c.entry.id}-one-two")

    assert has_element?(view, "#item-detail h2", "One & two")
  end

  test "private entries and malformed IDs cannot be opened", c do
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = build_conn() |> init_test_session(%{}) |> Gate.log_in(other)
    assert {:error, {:live_redirect, %{to: "/all"}}} = live(conn, item_path(c.entry))
    assert {:error, {:live_redirect, %{to: "/all"}}} = live(c.conn, "/all/invalid")
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
      {:ok, view, _} = live(c.conn, ~p"/inbox")

      view |> element("#play-#{c.entry.id}") |> render_click()

      assert_patch(view, "/inbox/#{c.entry.id}-one-two")
      assert has_element?(view, "#entries #entries-#{c.entry.id}")
      assert has_element?(view, "#item-detail h2", "One & two")
      assert has_element?(view, ~s|#play-#{c.entry.id}[aria-current="true"]|)
    end

    # j and k, as readers have moved through lists since Google Reader. The browser half that
    # decides which key presses count is `assets/js/reader_keys.mjs`.
    test "j and k move to the next and the previous item", c do
      {:ok, view, _} = live(c.conn, item_path(c.entry))

      render_hook(view, "move", %{"key" => "j"})
      assert_patch(view, item_path(c.video))

      render_hook(view, "move", %{"key" => "k"})
      assert_patch(view, item_path(c.entry))
    end

    # On a wide screen the browser asks for the first item when none is chosen. The address is
    # replaced, so Back does not land on the empty view again.
    test "the first item is chosen when the browser asks and nothing is", c do
      {:ok, view, _} = live(c.conn, ~p"/inbox")
      render_hook(view, "select_first", %{})
      assert_patch(view, "/inbox/#{c.entry.id}-one-two")

      view |> element("#play-#{c.video.id}") |> render_click()
      render_hook(view, "select_first", %{})
      assert has_element?(view, "#item-detail h2", "A good video")
    end

    # An item the page chose for a wide screen is let go when the screen turns narrow, where it
    # would cover the list. One the reader chose stays.
    test "an item chosen for a wide screen is let go when it narrows", c do
      {:ok, view, _} = live(c.conn, ~p"/inbox")
      render_hook(view, "select_first", %{})
      assert_patch(view, "/inbox/#{c.entry.id}-one-two")
      render_hook(view, "release_first", %{})
      assert_patch(view, "/inbox")

      view |> element("#play-#{c.video.id}") |> render_click()
      render_hook(view, "release_first", %{})
      assert has_element?(view, "#item-detail h2", "A good video")
    end

    # The row carries no buttons, so marking what is selected is a key beside j and k. Pressed
    # again it takes the mark back.
    test "m marks the selected item done, and again marks it new", c do
      {:ok, view, _} = live(c.conn, item_path(c.entry))

      render_hook(view, "toggle_mark", %{})
      assert %{playback: %{status: :heard}} = Library.entry(c.user, c.entry.id)

      render_hook(view, "toggle_mark", %{})
      assert %{playback: %{status: :new}} = Library.entry(c.user, c.entry.id)
    end

    test "m without a selected item does nothing", c do
      {:ok, view, _} = live(c.conn, ~p"/all")
      render_hook(view, "toggle_mark", %{})
      assert Library.entry(c.user, c.entry.id).playback == nil
    end

    # A selected item keeps its place in the list, opened by address or after an update alike.
    # Drawn again out of turn, it would sink to the bottom and j would skip what is on screen.
    test "the selected item keeps its place in the list", c do
      {:ok, view, _} = live(c.conn, item_path(c.entry))
      assert rows(view) == ["entries-#{c.entry.id}", "entries-#{c.video.id}"]

      send(view.pid, :library_changed)
      assert rows(view) == ["entries-#{c.entry.id}", "entries-#{c.video.id}"]
    end

    test "an item whose source goes away leaves the detail", c do
      {:ok, view, _} = live(c.conn, item_path(c.entry))

      subscription = Enum.find(Library.subscriptions(c.user), &(&1.feed_id == c.entry.feed_id))

      {:ok, _} = Library.unsubscribe(c.user, subscription.id)

      assert_patch(view, "/all")
      refute has_element?(view, "#item-detail h2")
    end
  end

  describe "the notes" do
    test "show what the publisher wrote, without what it smuggled in", c do
      {:ok, view, _} = live(c.conn, item_path(c.entry))

      assert has_element?(view, "#item-notes p", "Notes with a")
      assert has_element?(view, ~s|#item-notes a[target="_blank"]|, "link")
      refute render(view) =~ "alert(1)"
    end

    test "an item without notes says so rather than leaving the column empty", c do
      {:ok, preview} = Parser.parse(thin_podcast(), feed_url())
      {:ok, _} = Library.subscribe(c.user, preview)
      thin = Enum.find(Library.entries(c.user), &(&1.description == nil))

      {:ok, view, _} = live(c.conn, item_path(thin))

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
