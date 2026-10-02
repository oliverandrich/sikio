# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLiveTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Repo
  alias SikioWeb.Pictures

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    podcast_url = feed_url()
    {:ok, podcast} = Parser.parse(podcast(), podcast_url)
    {:ok, sub} = Library.subscribe(user, podcast)

    {:ok, video} =
      Parser.parse(
        youtube(),
        youtube_feed_url()
      )

    {:ok, _} = Library.subscribe(user, video)
    [audio] = Enum.filter(Library.entries(user), &(&1.feed.kind == :podcast))

    %{
      conn: conn |> init_test_session(%{}) |> Gate.log_in(user),
      user: user,
      audio: audio,
      sub: sub,
      podcast_url: podcast_url
    }
  end

  # The chips are what a phone narrows the list with. They build the same addresses the sidebar
  # does, so a narrowed view survives a reload either way.
  test "filters combine, survive reload and reset through the chips", c do
    Playback.mark(c.user, c.audio.id, :completed)
    {:ok, view, _} = live(c.conn, ~p"/")

    view |> element("#chip-kind-audio") |> render_click()
    assert_patch(view, "/?kind=audio")
    view |> element("#chip-view-completed") |> render_click()
    assert_patch(view, "/?kind=audio&status=completed")
    view |> element("#chip-source-#{c.sub.feed_id}") |> render_click()

    path = assert_patch(view)
    assert path =~ "source=#{c.sub.feed_id}"
    assert has_element?(view, "#entries article", "One & two")
    refute has_element?(view, "#entries article", "A good video")
    {:ok, reloaded, _} = live(c.conn, path)
    assert has_element?(reloaded, "#entries article", "One & two")
    refute has_element?(reloaded, "#entries article", "A good video")
    reloaded |> element("#clear-filters") |> render_click()
    assert_patch(reloaded, "/")
    assert has_element?(reloaded, "#entries article", "A good video")
  end

  test "marking and changes from another tab keep filtered membership current", c do
    {:ok, view, _} = live(c.conn, ~p"/?kind=podcast&status=new")
    view |> element("#complete-#{c.audio.id}") |> render_click()
    refute has_element?(view, "#entries-#{c.audio.id}")
    assert has_element?(view, "#library-no-matches")
    Playback.mark(c.user, c.audio.id, :new)
    assert has_element?(view, "#entries-#{c.audio.id}")
    {:ok, old} = Playback.start(c.user, c.audio.id)
    Playback.mark(c.user, c.audio.id, :completed)
    send(view.pid, {:playback_changed, old})
    refute has_element?(view, "#entries-#{c.audio.id}")
  end

  test "feed imports update matching entries without reloading", c do
    {:ok, view, _} = live(c.conn, ~p"/?kind=podcast&status=new")

    Req.Test.stub(HTTP, fn conn ->
      xml =
        podcast("Updated source")
        |> String.replace("episode-1", "episode-2")
        |> String.replace("One &amp; two", "Brand new episode")

      Plug.Conn.send_resp(conn, 200, xml)
    end)

    assert {:ok, _} = Feeds.refresh(c.sub.feed_id)
    assert has_element?(view, "#entries article", "Brand new episode")
    assert has_element?(view, "#chip-source-#{c.sub.feed_id}", "Updated source")
    refute has_element?(view, "#entries article", "A good video")
  end

  test "subscriptions added and removed elsewhere update the library", c do
    {:ok, view, _} = live(c.conn, ~p"/")
    {:ok, _} = Library.unsubscribe(c.user, c.sub.id)
    refute has_element?(view, "#entries-#{c.audio.id}")
    {:ok, preview} = Parser.parse(podcast("Another source"), "https://example.org/another")
    {:ok, _} = Library.subscribe(c.user, preview)
    assert has_element?(view, "#entries article", "Another source")
  end

  test "invalid query parameters are harmless and another account cannot alter our status", c do
    # The same source on purpose: a co-subscriber may write playback, and what this asks is that
    # writing it leaves our own status alone. Give them a feed of their own and the write is
    # refused for want of a subscription, which proves something else entirely.
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), c.podcast_url)
    Library.subscribe(other, preview)
    {:ok, view, _} = live(c.conn, ~p"/?kind=invalid&status=invalid&source=oops")

    # Both halves matter. Their write has to land, or this proves only that a stranger cannot
    # write, which is a different test and one that passes for the wrong reason.
    assert {:ok, %{status: :completed}} = Playback.mark(other, c.audio.id, :completed)
    assert has_element?(view, "#entries-#{c.audio.id}", "New")
    {:ok, reloaded, _} = live(c.conn, ~p"/?status=new")
    assert has_element?(reloaded, "#entries-#{c.audio.id}", "New")
  end

  test "removing the selected source leaves a clear empty view until filters are cleared", c do
    {:ok, view, _} = live(c.conn, ~p"/?source=#{c.sub.feed_id}")
    Library.unsubscribe(c.user, c.sub.id)
    assert has_element?(view, "#library-no-matches")
    assert has_element?(view, "#library-heading", "Unavailable source")
    view |> element("#clear-filters") |> render_click()
    assert has_element?(view, "#entries article", "A good video")
  end

  # A third kind arrived and the interface still asked whether something was YouTube. Everything
  # that is not answered that way fell to the podcast side, so a PeerTube video was drawn with a
  # microphone and described as audio from a publisher.
  test "a PeerTube video is not dressed as a podcast", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, _} = Library.subscribe(user, preview)
    entry = Enum.find(Library.entries(user), &(&1.feed.kind == :peertube))

    {:ok, view, _html} = live(conn, ~p"/")
    row = element(view, "#entries-#{entry.id}") |> render()

    assert row =~ "lucide-circle-play", "it is watched, so it carries the mark of a video"
    refute row =~ "lucide-mic"

    {:ok, _view, page} = live(conn, ~p"/library/#{entry.id}")
    refute page =~ "YouTube receives your connection data"
    refute page =~ "Audio streams directly from the podcast publisher"
    assert page =~ "video.example.org"
  end

  test "a PeerTube source says what it is in the list of sources", %{conn: conn, user: user} do
    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, _} = Library.subscribe(user, preview)

    {:ok, _view, html} = live(conn, ~p"/subscriptions")

    # The account also follows a podcast, so both words have to be there, each on its own source.
    assert html =~ "PeerTube ·"
    assert html =~ "Podcast ·"
  end

  # On a phone the sources fold away. A chosen source keeps them open and names itself, so the
  # filter in force is never hidden; one that left the library is named as unavailable.
  test "a chosen source keeps the phone's source chips open and named", c do
    {:ok, view, _} = live(c.conn, ~p"/?source=#{c.sub.feed_id}")
    assert has_element?(view, "#chip-sources[open] summary", "Small Hours")

    {:ok, _} = Library.unsubscribe(c.user, c.sub.id)
    assert has_element?(view, "#chip-sources[open] summary", "Unavailable source")
  end

  # A playing item saves its place every few seconds. Rereading the library each time would cost
  # every open tab a reload, so a sample that changes no status updates the one row; a status
  # change may move the item between views and reloads. An entry added behind the page's back
  # shows which of the two happened.
  describe "progress from a player" do
    setup c do
      {:ok, %{session_id: session}} = Playback.start(c.user, c.audio.id)
      {:ok, _} = Playback.save(c.user, c.audio.id, session, sample(1, 30))
      %{session: session}
    end

    test "a sample that changes no status updates the row without rereading", c do
      {:ok, view, _} = live(c.conn, ~p"/")
      unseen = sneak_in(c)

      {:ok, _} = Playback.save(c.user, c.audio.id, c.session, sample(2, 60))

      assert has_element?(view, "#entries-#{c.audio.id}", "1:00")
      refute has_element?(view, "#entries article", unseen)
    end

    # Away from the library the sidebar counts for itself, so this is where a reread would show.
    test "a sample that changes no status leaves the sidebar's counts unread", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")
      sneak_in(c)

      {:ok, _} = Playback.save(c.user, c.audio.id, c.session, sample(2, 60))
      refute has_element?(view, "#view-all-count", "3")

      {:ok, _} = Playback.mark(c.user, c.audio.id, :completed)
      assert has_element?(view, "#view-all-count", "3")
    end

    test "a status change rereads the list and the counts", c do
      {:ok, view, _} = live(c.conn, ~p"/")
      unseen = sneak_in(c)

      {:ok, _} = Playback.mark(c.user, c.audio.id, :completed)

      assert has_element?(view, "#entries article", unseen)
      assert has_element?(view, "#view-all-count", "3")
    end
  end

  defp sample(sequence, position),
    do: %{"sequence" => sequence, "position" => position, "duration" => 3723, "ended" => false}

  defp sneak_in(c) do
    title = "Added behind the page's back"
    insert_entries(c, [title])
    title
  end

  # Written straight to the database, so no open view hears of them.
  defp insert_entries(c, titles) do
    now = DateTime.utc_now()

    rows =
      for title <- titles do
        %{
          feed_id: c.sub.feed_id,
          external_id: "direct-#{Sikio.DataCase.unique()}",
          title: title,
          published_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Sikio.Feeds.Entry, rows)
  end

  # An import subscribes to up to fifty sources in a row, and a poll refreshes many feeds at
  # once. Each sends an event, and every open tab would reread the library for each of them.
  # The test closes the window itself rather than waiting the second it lasts.
  test "a burst of new episodes rereads the library at its start and its end", c do
    {:ok, view, _} = live(c.conn, ~p"/")

    single =
      queries_from(view, fn ->
        send(view.pid, :library_changed)
        send(view.pid, :library_window_closed)
      end)

    burst =
      queries_from(view, fn ->
        for _ <- 1..5, do: send(view.pid, :library_changed)
        send(view.pid, :library_window_closed)
      end)

    assert single > 0
    assert burst == 2 * single
  end

  # Counts the database queries the view's own process makes while `fun` runs.
  defp queries_from(view, fun) do
    {_, sql} =
      Sikio.DataCase.queries(view.pid, fn ->
        fun.()
        render(view)
      end)

    length(sql)
  end

  describe "the sidebar" do
    test "narrows the list through the address and marks where the reader is", c do
      {:ok, view, _} = live(c.conn, ~p"/")

      view |> element("#kind-audio") |> render_click()
      assert_patch(view, "/?kind=audio")
      assert has_element?(view, "#entries article", "One & two")
      refute has_element?(view, "#entries article", "A good video")
      assert has_element?(view, "#kind-audio[aria-current=page]")

      view |> element("#view-new") |> render_click()
      assert_patch(view, "/?kind=audio&status=new")

      # Choosing the active kind again lets it go.
      view |> element("#kind-audio") |> render_click()
      assert_patch(view, "/?status=new")
    end

    test "counts new items per source and follows what the reader does", c do
      {:ok, view, _} = live(c.conn, ~p"/")
      assert view |> element("#source-#{c.sub.feed_id}-count") |> render() =~ "1"

      view |> element("#complete-#{c.audio.id}") |> render_click()

      refute has_element?(view, "#source-#{c.sub.feed_id}-count")
      assert view |> element("#view-completed-count") |> render() =~ "1"
    end

    # A page that is not the library still follows what happens elsewhere.
    test "stays current on a page that is not the library", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")
      refute has_element?(view, "#view-completed-count")

      {:ok, _} = Playback.mark(c.user, c.audio.id, :completed)

      assert view |> element("#view-completed-count") |> render() =~ "1"
    end

    test "every member page carries it, and it leads back to the library", c do
      {:ok, view, _} = live(c.conn, ~p"/subscriptions")

      assert has_element?(view, "#sidebar #source-#{c.sub.feed_id}", "Small Hours")
      assert has_element?(view, ~s|#view-new[href="/?status=new"]|)
      refute has_element?(view, "#sidebar [aria-current]")
      assert has_element?(view, ~s|#subscriptions-link[aria-current="page"]|)
      refute has_element?(view, ~s|#library-link[aria-current="page"]|)
    end
  end

  describe "a row in the list" do
    # The picture comes from this host. Its address names the episode's own picture first, then
    # the show's, then the mark for what kind of thing it is.
    test "shows its picture through Sikio's own host, with the fallbacks in order", c do
      {:ok, view, _} = live(c.conn, ~p"/")

      [src] =
        view
        |> element("#entries-#{c.audio.id} img")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.attribute("img", "src")

      assert "/pictures/" <> reference = src

      assert Pictures.verify(reference) ==
               {:ok,
                {["https://img.example.org/1.jpg", "https://img.example.org/show.jpg"],
                 "/images/kind-audio.svg"}}
    end

    test "shows the runtime the publisher stated, and none when there is none", c do
      {:ok, preview} = Parser.parse(thin_podcast(), feed_url())
      {:ok, _} = Library.subscribe(c.user, preview)
      thin = Enum.find(Library.entries(c.user), &(&1.feed_id == preview_feed_id(c.user, preview)))

      {:ok, view, _} = live(c.conn, ~p"/")

      assert view |> element("#runtime-#{c.audio.id}") |> render() =~ "1:02:03"
      refute has_element?(view, "#runtime-#{thin.id}")
    end

    test "says how far somebody got, and dims what was finished", c do
      {:ok, %{session_id: session}} = Playback.start(c.user, c.audio.id)

      {:ok, _} =
        Playback.save(c.user, c.audio.id, session, %{
          "sequence" => 1,
          "position" => 1_862,
          "duration" => 3_723,
          "ended" => false
        })

      {:ok, view, _} = live(c.conn, ~p"/")
      assert has_element?(view, ~s|#entries-#{c.audio.id} [role=progressbar][aria-valuenow="50"]|)

      # A feed may state a shorter runtime than the audio has. The bar stops at the end anyway.
      {:ok, _} =
        Playback.save(c.user, c.audio.id, session, %{
          "sequence" => 2,
          "position" => 4_000,
          "duration" => nil,
          "ended" => false
        })

      assert has_element?(
               view,
               ~s|#entries-#{c.audio.id} [role=progressbar][aria-valuenow="100"]|
             )

      view |> element("#complete-#{c.audio.id}") |> render_click()
      assert has_element?(view, ~s|#entries-#{c.audio.id}[data-status="completed"]|)
    end
  end

  describe "the heading" do
    # The list stops at a hundred. The heading says how many there are, not how many fit.
    test "counts every matching item, and says when the list shows fewer", c do
      insert_entries(c, for(n <- 1..120, do: "Bulk #{n}"))
      {:ok, view, _} = live(c.conn, ~p"/?kind=audio")

      assert view |> element("#library-count") |> render() =~ "100 of 121"
    end
  end

  defp preview_feed_id(user, preview) do
    Enum.find_value(Library.subscriptions(user), &(&1.feed.url == preview.url && &1.feed_id))
  end
end
