# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.FeedsTest do
  @moduledoc false
  use Sikio.DataCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.Events

  # Evaluated once at compile time and unique to this module. Tests here share this feed on
  # purpose. Two async modules writing the same row can deadlock.
  @feed_url feed_url()

  test "a feed is stored once, however often it is imported" do
    {:ok, first} = Feeds.store(preview())
    {:ok, second} = Feeds.store(preview(podcast("Renamed")))

    assert first.id == second.id
    assert second.title == "Renamed"
    assert Repo.aggregate(Feed, :count) == 1
    assert Repo.aggregate(Entry, :count) == 1
  end

  # Items with the same GUID are one entry. The first occurrence wins, so a later duplicate in
  # the document cannot overwrite it.
  test "an episode repeated inside one document is imported once" do
    body = String.replace(podcast(), "</channel>", twin() <> "</channel>")

    assert {:ok, _feed} = Feeds.store(preview(body))
    assert Repo.aggregate(Entry, :count) == 1
    assert Repo.one(from e in Entry, select: e.title) == "One & two"
  end

  test "a source that stopped answering keeps its entries and records why" do
    {:ok, stored} = Feeds.store(preview())
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)

    assert {:error, :unavailable} = Feeds.refresh(stored.id)
    assert Repo.get(Feed, stored.id).last_error == "unavailable"
    assert Repo.aggregate(Entry, :count) == 1
  end

  # The fixture's newest entry is weeks old, so a tenth of its age exceeds the one-day cap.
  # Both a store and a 304 set `next_check_at`.
  test "a stored or unchanged feed is asked next by the age of its newest entry" do
    {:ok, stored} = Feeds.store(preview())
    assert_next_check(stored.id, hours: 24)

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
    assert {:ok, _} = Feeds.refresh(stored.id)
    assert_next_check(stored.id, hours: 24)
  end

  # A failure carries no publication date, so the next check uses the base interval.
  test "a feed that failed is asked again after the base interval" do
    {:ok, stored} = Feeds.store(preview())
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)

    assert {:error, :unavailable} = Feeds.refresh(stored.id)
    assert_next_check(stored.id, hours: 1)
  end

  # A `Retry-After` of 7200 seconds sets the next check two hours ahead.
  test "a server that asks to be left alone is asked again when it said" do
    {:ok, stored} = Feeds.store(preview())

    Req.Test.stub(HTTP, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "7200") |> Plug.Conn.send_resp(503, "")
    end)

    assert {:error, :busy} = Feeds.refresh(stored.id)
    assert Repo.get(Feed, stored.id).last_error == "unavailable"
    assert_next_check(stored.id, hours: 2)
  end

  # 404 and 410 record `gone`, distinct from a temporary `unavailable`, so readers can tell them
  # apart.
  test "a source that is gone records that it is gone" do
    {:ok, stored} = Feeds.store(preview())

    for status <- [404, 410] do
      Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, status, "") end)
      assert {:error, :gone} = Feeds.refresh(stored.id)
      assert Repo.get(Feed, stored.id).last_error == "gone"
    end
  end

  # The sidebar marks failing feeds. The first failure and the recovery broadcast once each.
  # A repeated failure broadcasts nothing, or each poll would reload every open library view.
  test "a source that starts failing or recovers notifies its subscribers once" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)

    {:error, :unavailable} = Feeds.refresh(stored.id)
    assert_received :library_changed
    {:error, :unavailable} = Feeds.refresh(stored.id)
    refute_received :library_changed

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
    {:ok, _} = Feeds.refresh(stored.id)
    assert_received :library_changed
  end

  test "a source that has not changed clears the error it reported before" do
    {:ok, stored} = Feeds.store(preview())
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)
    {:error, :unavailable} = Feeds.refresh(stored.id)

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)

    assert {:ok, refreshed} = Feeds.refresh(stored.id)
    assert refreshed.last_error == nil
    assert refreshed.last_checked_at
  end

  # The feed keeps the subscribed URL. Storing the redirect target would create a second,
  # unsubscribed feed row.
  test "a redirecting endpoint does not move the subscribed address" do
    {:ok, stored} = Feeds.store(preview())

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/rss" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/moved.xml")
          |> Plug.Conn.send_resp(301, "")

        "/moved.xml" ->
          Plug.Conn.send_resp(conn, 200, podcast())
      end
    end)

    assert {:ok, refreshed} = Feeds.refresh(stored.id)
    assert refreshed.url == @feed_url
    assert Repo.aggregate(Feed, :count) == 1
  end

  # `String.slice/3` counts graphemes. 512 graphemes of `e` plus a combining accent are 1024 code
  # points, and the column must hold what the parser produces.
  test "a title of combining characters is stored rather than refused" do
    long = String.duplicate("e\u0301", 600)
    body = String.replace(podcast(), "One &amp; two", long)

    assert {:ok, _feed} = Feeds.store(preview(body))
    assert Repo.one(from e in Entry, select: e.title) == String.slice(long, 0, 512)
  end

  # A 304 broadcasts nothing. Each broadcast reloads every open library view.
  test "an unchanged source notifies nobody" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)

    assert {:ok, _feed} = Feeds.refresh(stored.id)
    refute_receive :library_changed, 100
  end

  # The website is visible in the library, so a change broadcasts like a renamed feed.
  test "a poll that only moves the website notifies the subscribers" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})
    body = String.replace(podcast(), podcast_site(), "https://example.org/moved")
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

    assert {:ok, %{page_url: "https://example.org/moved"}} = Feeds.refresh(stored.id)
    assert_receive :library_changed
  end

  # A poll without a website keeps the stored one. That is no change, so nothing is broadcast.
  test "a poll without the website notifies nobody" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})
    body = String.replace(podcast(), "<link>#{podcast_site()}</link>", "")
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

    assert {:ok, feed} = Feeds.refresh(stored.id)
    assert feed.page_url == podcast_site()
    refute_receive :library_changed, 100
  end

  # Feeds without working cache validators return the full document on every poll.
  # Rewriting an unchanged row costs a row version, WAL and a dead tuple, plus a broadcast.
  # Every write sets `updated_at`, so the test compares it.
  test "importing what is already stored writes no entry" do
    {:ok, stored} = Feeds.store(preview())
    before = versions(stored.id)

    {:ok, _feed} = Feeds.store(preview())

    assert versions(stored.id) == before
  end

  test "a poll that changes nothing notifies nobody, one that changes something does" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    assert {:ok, _feed} = Feeds.refresh(stored.id)
    refute_received :library_changed

    body = podcast() |> String.replace("One &amp; two", "One, two and three")
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
    assert {:ok, _feed} = Feeds.refresh(stored.id)
    assert_received :library_changed
  end

  # A rename without new entries broadcasts, because the sidebar and subscriptions show the title.
  test "a poll that only renames the source notifies its subscribers" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast("Renamed")) end)
    assert {:ok, %{title: "Renamed"}} = Feeds.refresh(stored.id)
    assert_received :library_changed
  end

  # The upsert guard must compare every column the update writes. An omitted column would never
  # update again. Each column is changed separately here.
  for {field, value} <- [
        title: "A new title",
        media_url: "https://audio.example.org/moved.mp3",
        audio_url: "https://video.example.org/static/moved.mp4",
        video_id: "abcdefghijk",
        embed_url: "https://video.example.org/videos/embed/moved",
        page_url: "https://example.org/episodes/moved",
        chapters: [%{"at" => 0, "title" => "Intro"}, %{"at" => 60, "title" => "Mitte"}],
        chapters_url: "https://example.org/chapters.json",
        published_at: ~U[2026-09-19 09:00:00.000000Z],
        image_url: "https://img.example.org/new.jpg",
        duration: 99,
        description: "<p>New notes</p>",
        description_format: :text,
        excerpt: "New notes",
        short: true
      ] do
    test "a changed #{field} is written" do
      {:ok, stored} = Feeds.store(preview())
      before = versions(stored.id)
      [entry] = preview().entries

      Feeds.store(%{
        preview()
        | entries: [Map.put(entry, unquote(field), unquote(Macro.escape(value)))]
      })

      refute versions(stored.id) == before

      assert Repo.one(from e in Entry, select: field(e, unquote(field))) ==
               unquote(Macro.escape(value))
    end
  end

  defp versions(feed_id),
    do:
      Repo.all(
        from e in Entry, where: e.feed_id == ^feed_id, order_by: e.id, select: e.updated_at
      )

  test "refreshing a source that is no longer stored says so" do
    assert {:error, :not_found} = Feeds.refresh(-1)
  end

  # Subscribes a new user to the feed the test already stored. The pin match asserts that
  # exactly one feed exists.
  defp subscriber(feed_id) do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), @feed_url)
    {:ok, _subscription} = Library.subscribe(user, preview)
    ^feed_id = Repo.one(from f in Sikio.Feeds.Feed, select: f.id)
    user.id
  end

  defp preview(body \\ podcast(), url \\ @feed_url) do
    {:ok, preview} = Parser.parse(body, url)
    preview
  end

  defp twin do
    """
    <item><guid>episode-1</guid><title>The same episode, further down</title>
    <enclosure url="https://audio.example.org/1.mp3" type="audio/mpeg" length="12" /></item>
    """
  end

  test "artwork, runtime and notes reach the stored rows" do
    assert {:ok, feed} = Feeds.store(preview())
    assert feed.icon_url == "https://img.example.org/show.jpg"
    assert feed.page_url == podcast_site()

    entry = Repo.one(Entry)
    assert entry.image_url == "https://img.example.org/1.jpg"
    assert entry.duration == 3723
    assert entry.description =~ "<a href=\"https://example.org\">link</a>"
    assert entry.excerpt == "Notes with a link."
  end

  # Rows imported before these columns existed lack their values. The next poll fills them in,
  # so no separate backfill is needed.
  test "a later poll fills in what an earlier import could not store" do
    {:ok, feed} = Feeds.store(preview())
    Repo.update_all(Entry, set: [image_url: nil, duration: nil, description: nil, excerpt: nil])
    Repo.update_all(Feed, set: [icon_url: nil, page_url: nil])

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    assert {:ok, refreshed} = Feeds.refresh(feed.id)

    assert refreshed.icon_url == "https://img.example.org/show.jpg"
    assert refreshed.page_url == podcast_site()
    assert Repo.one(Entry).duration == 3723
  end

  # 300 family emoji are 300 graphemes in Elixir but 2100 code points in Postgres.
  # The column limit used to reject them and fail the whole import.
  test "an excerpt of emoji is stored rather than refused by its column" do
    notes = String.duplicate("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", 300)

    body =
      String.replace(
        podcast(),
        ~r|<content:encoded>.*?</content:encoded>|s,
        "<content:encoded><![CDATA[<p>#{notes}</p>]]></content:encoded>"
      )

    assert {:ok, _feed} = Feeds.store(preview(body))
    assert Repo.one(Entry).excerpt != nil
  end

  # A poll that omits artwork, notes or page URL keeps the stored values, for the feed and its
  # entries.
  test "a poll that omits artwork, notes and the page keeps what was stored" do
    {:ok, _feed} = Feeds.store(preview())

    assert {:ok, feed} = Feeds.store(preview(thin_podcast()))
    assert feed.page_url == podcast_site()

    entry = Repo.one(Entry)
    assert entry.image_url == "https://img.example.org/1.jpg"
    assert entry.duration == 3723
    assert entry.excerpt == "Notes with a link."
    assert entry.page_url == podcast_page()
  end

  # A Short leaves the Shorts playlist feed long before the channel feed.
  # A poll without the Short mark therefore does not clear it.
  test "an entry once known as a Short stays one" do
    [entry] = preview().entries
    {:ok, _feed} = Feeds.store(%{preview() | entries: [Map.put(entry, :short, true)]})

    {:ok, _feed} = Feeds.store(preview())

    assert Repo.one(from e in Entry, select: e.short)
  end

  # Search reads `search_text`. A poll without notes keeps the stored notes, so `search_text`
  # combines the new title with the stored notes.
  test "a poll that renames an entry and omits its notes is found by the new title" do
    {:ok, _feed} = Feeds.store(preview())

    renamed = String.replace(thin_podcast(), "One &amp; two", "One &amp; three")
    assert {:ok, _feed} = Feeds.store(preview(renamed))

    entry = Repo.one(Entry)
    assert entry.search_text =~ "one & three"
    refute entry.search_text =~ "one & two"
    assert entry.search_text =~ "notes with a link"
  end

  # A chapters file is fetched on first access through `Sikio.Feeds.HTTP`. The result is stored.
  # A failed fetch is retried on the next call.
  describe "chapters/1" do
    test "fetches a podcast's chapters file once and keeps what it holds" do
      {:ok, feed} = Feeds.store(preview())
      Repo.update_all(Entry, set: [chapters_url: "https://example.org/c.json"])
      entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)

      Sikio.PictureFixtures.serving(%{
        "/c.json" =>
          {"application/json",
           ~s|{"version":"1.2.0","chapters":[{"startTime":0,"title":"A"},{"startTime":60,"title":"B"}]}|}
      })

      expected = [%{"at" => 0, "title" => "A"}, %{"at" => 60, "title" => "B"}]
      assert Feeds.chapters(entry) == {:ok, expected}
      assert_received {:fetched, "/c.json"}
      assert Repo.get(Entry, entry.id).chapters == expected

      assert Feeds.chapters(Repo.get(Entry, entry.id)) == {:ok, expected}
      refute_received {:fetched, _}
    end

    test "a failing file is tried again, a useless one is not" do
      {:ok, feed} = Feeds.store(preview())
      Repo.update_all(Entry, set: [chapters_url: "https://example.org/c.json"])
      entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)

      Sikio.PictureFixtures.serving(%{})
      assert {:error, _} = Feeds.chapters(entry)
      assert Repo.get(Entry, entry.id).chapters == nil

      Sikio.PictureFixtures.serving(%{"/c.json" => {"application/json", "not json"}})
      assert Feeds.chapters(entry) == {:ok, []}
      assert Repo.get(Entry, entry.id).chapters == []
    end

    # A poll may change `chapters_url` during the download. The old file's chapters are discarded.
    test "chapters of a file the item no longer links are not stored" do
      {:ok, feed} = Feeds.store(preview())
      Repo.update_all(Entry, set: [chapters_url: "https://example.org/c.json"])
      entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)
      Repo.update_all(Entry, set: [chapters_url: "https://example.org/d.json"])

      Sikio.PictureFixtures.serving(%{
        "/c.json" =>
          {"application/json",
           ~s|{"version":"1.2.0","chapters":[{"startTime":0,"title":"A"},{"startTime":60,"title":"B"}]}|}
      })

      assert {:ok, [_, _]} = Feeds.chapters(entry)
      assert Repo.get(Entry, entry.id).chapters == nil
    end

    test "an item without a chapters file has nothing to fetch" do
      {:ok, feed} = Feeds.store(preview())
      entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)
      assert Feeds.chapters(entry) == {:ok, nil}
    end
  end

  describe "media/1" do
    # The instance may move or re-transcode a video. Its API names the current files on each
    # call. A stored URL is never used, and nothing is written.
    test "asks the instance for a PeerTube video's files on every call" do
      {:ok, feed} = Feeds.store(peertube_preview())
      Repo.update_all(Entry, set: [media_url: "https://video.example.org/gone.m3u8"])
      entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)

      Sikio.PictureFixtures.serving(%{
        "/api/v1/videos/mSh0rtUu1d" =>
          {"application/json",
           Jason.encode!(%{
             files: [
               %{resolution: %{id: 0}, fileUrl: "https://video.example.org/static/a-0.mp4"},
               %{resolution: %{id: 720}, fileUrl: "https://video.example.org/static/v-720.mp4"}
             ]
           })}
      })

      for _ <- 1..2 do
        assert {:ok, played} = Feeds.media(entry.embed_url)
        assert played.media_url == "https://video.example.org/static/v-720.mp4"
        assert played.audio_url == "https://video.example.org/static/a-0.mp4"
        assert_received {:fetched, "/api/v1/videos/mSh0rtUu1d"}
      end

      assert Repo.get(Entry, entry.id) == entry
    end

    # A PeerTube feed names no playlist, so a poll clears a stored one. The audio-only file stays
    # when a poll omits it. It tells the detail whether to offer the sound alone.
    test "a poll replaces the media URL and keeps the audio file" do
      {:ok, feed} = Feeds.store(peertube_preview())

      Repo.update_all(Entry,
        set: [
          media_url: "https://video.example.org/master.m3u8",
          audio_url: "https://video.example.org/a.mp4"
        ]
      )

      Feeds.store(%{
        peertube_preview()
        | entries: [%{hd(peertube_preview().entries) | audio_url: nil}]
      })

      assert Repo.one(
               from e in Entry,
                 where: e.feed_id == ^feed.id,
                 select: {e.media_url, e.audio_url}
             ) == {nil, "https://video.example.org/a.mp4"}
    end

    test "a video the instance does not answer for has no files" do
      {:ok, feed} = Feeds.store(peertube_preview())
      entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)

      Sikio.PictureFixtures.serving(%{})
      assert {:error, _} = Feeds.media(entry.embed_url)
    end
  end

  defp peertube_preview do
    {:ok, preview} = Parser.parse(peertube(), "https://video.example.org/feeds/videos.xml")
    preview
  end

  # Fetched chapters belong to their file. When a poll links another file, the stored chapters
  # are cleared so the new file is fetched.
  test "a poll that links another chapters file lets the stored chapters go" do
    {:ok, feed} = Feeds.store(preview())
    stored = [%{"at" => 0, "title" => "Alt"}, %{"at" => 60, "title" => "Auch alt"}]
    Repo.update_all(Entry, set: [chapters: stored, chapters_url: "https://example.org/old.json"])

    link = ~s|<podcast:chapters url="https://example.org/new.json"/>|
    body = String.replace(podcast(), "<itunes:duration>", link <> "<itunes:duration>")
    assert {:ok, _feed} = Feeds.store(preview(body))

    entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)
    assert entry.chapters_url == "https://example.org/new.json"
    assert entry.chapters == nil
  end

  # The feed names only the chapters file, so a poll must not clear fetched chapters.
  test "a poll that names no chapters keeps the ones stored" do
    {:ok, feed} = Feeds.store(preview())
    stored = [%{"at" => 0, "title" => "Intro"}, %{"at" => 60, "title" => "Mitte"}]
    Repo.update_all(Entry, set: [chapters: stored, chapters_url: "https://example.org/c.json"])

    assert {:ok, _feed} = Feeds.store(preview())

    entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)
    assert entry.chapters == stored
    assert entry.chapters_url == "https://example.org/c.json"
  end

  # The same holds when the poll changes another field and writes the row.
  test "a poll that renames an entry and names no chapters keeps the ones stored" do
    {:ok, feed} = Feeds.store(preview())
    stored = [%{"at" => 0, "title" => "Intro"}, %{"at" => 60, "title" => "Mitte"}]
    Repo.update_all(Entry, set: [chapters: stored, chapters_url: "https://example.org/c.json"])

    renamed = String.replace(podcast(), "One &amp; two", "One &amp; three")
    assert {:ok, _feed} = Feeds.store(preview(renamed))

    entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)
    assert entry.title == "One & three"
    assert entry.chapters == stored
    assert entry.chapters_url == "https://example.org/c.json"
  end

  # A YouTube refresh fetches only the Atom feed, which has no channel picture.
  # Overwriting with nil would remove the sidebar picture after the first poll.
  test "a refresh that carries no picture keeps the stored one" do
    {:ok, feed} =
      Feeds.store(%{
        url: youtube_feed_url(),
        title: "Good Channel",
        kind: :youtube,
        icon_url: "https://yt3.googleusercontent.com/picture=s900-c-k-no-rj",
        entries: []
      })

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, youtube()) end)

    assert {:ok, refreshed} = Feeds.refresh(feed.id)
    assert refreshed.icon_url == "https://yt3.googleusercontent.com/picture=s900-c-k-no-rj"
  end

  test "a PeerTube channel is stored with the embed each video is played from" do
    assert {:ok, feed} =
             Feeds.store(preview(peertube(), peertube_feed_url()))

    assert feed.kind == :peertube

    entry = Repo.one(Entry)
    assert entry.embed_url == "https://video.example.org/videos/embed/mSh0rtUu1d"
    assert entry.duration == 3600
  end

  # Spreading adds up to ten minutes. The lower bound allows for elapsed test time.
  defp assert_next_check(feed_id, hours: hours) do
    expected = DateTime.add(DateTime.utc_now(), hours, :hour)
    next = Repo.get!(Feed, feed_id).next_check_at
    assert DateTime.diff(next, expected, :second) in -60..600
  end
end
