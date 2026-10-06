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

  # One address for this module and a different one for every other, evaluated once when this
  # is compiled. Several tests here mean the same feed on purpose, which is what half of them
  # are about; two modules meaning the same row is what the suite deadlocks on.
  @feed_url feed_url()

  test "a feed is stored once, however often it is imported" do
    {:ok, first} = Feeds.store(preview())
    {:ok, second} = Feeds.store(preview(podcast("Renamed")))

    assert first.id == second.id
    assert second.title == "Renamed"
    assert Repo.aggregate(Feed, :count) == 1
    assert Repo.aggregate(Entry, :count) == 1
  end

  # Two items sharing a GUID are one episode. The first one in the document is the one kept, so a
  # feed that repeats an entry lower down cannot rewrite what is already in the library.
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

  # The fixture's newest episode is weeks old, so a tenth of its age is more than the day the
  # wait is capped at. Each kind of answer sets the next request.
  test "a stored or unchanged feed is asked next by the age of its newest entry" do
    {:ok, stored} = Feeds.store(preview())
    assert_next_check(stored.id, hours: 24)

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
    assert {:ok, _} = Feeds.refresh(stored.id)
    assert_next_check(stored.id, hours: 24)
  end

  # A failure says nothing about the feed's pace, so it is tried again at the base interval.
  test "a feed that failed is asked again after the base interval" do
    {:ok, stored} = Feeds.store(preview())
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)

    assert {:error, :unavailable} = Feeds.refresh(stored.id)
    assert_next_check(stored.id, hours: 1)
  end

  # A busy server says when to come back, and that is when it is asked next.
  test "a server that asks to be left alone is asked again when it said" do
    {:ok, stored} = Feeds.store(preview())

    Req.Test.stub(HTTP, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "7200") |> Plug.Conn.send_resp(503, "")
    end)

    assert {:error, :busy} = Feeds.refresh(stored.id)
    assert Repo.get(Feed, stored.id).last_error == "unavailable"
    assert_next_check(stored.id, hours: 2)
  end

  # A gone feed is not one that is down for a while. The reader is told which it is.
  test "a source that is gone records that it is gone" do
    {:ok, stored} = Feeds.store(preview())

    for status <- [404, 410] do
      Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, status, "") end)
      assert {:error, :gone} = Feeds.refresh(stored.id)
      assert Repo.get(Feed, stored.id).last_error == "gone"
    end
  end

  # The sidebar marks a failing source. Starting to fail and recovering are news, once each;
  # failing again is not, or every poll of a broken feed would reload every open library.
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

  # The subscription points at the address somebody pasted. A feed that answers a redirect today
  # would otherwise arrive under its new address as a second, unsubscribed source.
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

  # `String.slice/3` counts graphemes, so a title of 512 accented characters is 1024 code points.
  # The column has to hold what the parser is willing to produce.
  test "a title of combining characters is stored rather than refused" do
    long = String.duplicate("e\u0301", 600)
    body = String.replace(podcast(), "One &amp; two", long)

    assert {:ok, _feed} = Feeds.store(preview(body))
    assert Repo.one(from e in Entry, select: e.title) == String.slice(long, 0, 512)
  end

  # A source that answers 304 has nothing new to tell anybody, and every notification costs each
  # open library a full reload.
  test "an unchanged source notifies nobody" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)

    assert {:ok, _feed} = Feeds.refresh(stored.id)
    refute_receive :library_changed, 100
  end

  # A new website is what a reader sees of the source, so it counts like a new name.
  test "a poll that only moves the website notifies the subscribers" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})
    body = String.replace(podcast(), podcast_site(), "https://example.org/moved")
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

    assert {:ok, %{page_url: "https://example.org/moved"}} = Feeds.refresh(stored.id)
    assert_receive :library_changed
  end

  # A poll that names no website keeps the stored one, and keeping it is no change to announce.
  test "a poll without the website notifies nobody" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})
    body = String.replace(podcast(), "<link>#{podcast_site()}</link>", "")
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

    assert {:ok, feed} = Feeds.refresh(stored.id)
    assert feed.page_url == podcast_site()
    refute_receive :library_changed, 100
  end

  # A source without working cache validators answers in full on every poll. Rewriting rows it
  # did not change costs a new row version, write ahead log and a dead tuple per entry, and a
  # notification that makes every open library reload. Every write sets `updated_at`.
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

  # A renamed show with no new episode is still news: the sidebar and the subscriptions show its
  # name.
  test "a poll that only renames the source notifies its subscribers" do
    {:ok, stored} = Feeds.store(preview())
    Events.subscribe_updates(%User{id: subscriber(stored.id)})

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast("Renamed")) end)
    assert {:ok, %{title: "Renamed"}} = Feeds.refresh(stored.id)
    assert_received :library_changed
  end

  # The guard compares every column the update writes. One left out of it would never be updated
  # again, and nothing else would notice, so each one is changed on its own here.
  for {field, value} <- [
        title: "A new title",
        media_url: "https://audio.example.org/moved.mp3",
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
        excerpt: "New notes"
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

  # The feed this test already stored, not another one: the assertion below is that there is
  # exactly one.
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

  # A library imported before these columns existed has rows without them. The next poll carries
  # what the publisher sends, so the backfill costs nothing beyond waiting for it.
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

  # Graphemes are not codepoints. Three hundred family emoji are three hundred characters to
  # Elixir and two thousand one hundred to Postgres, which refused them and took the import down.
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

  # The feed keeps its picture when a poll carries none. The entries did the opposite and wiped
  # artwork and notes off every episode of a show that left them out once.
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

  # The search reads one stored text. A poll without notes keeps the notes, so the text has to
  # take the new title from the poll and the notes from the row.
  test "a poll that renames an entry and omits its notes is found by the new title" do
    {:ok, _feed} = Feeds.store(preview())

    renamed = String.replace(thin_podcast(), "One &amp; two", "One &amp; three")
    assert {:ok, _feed} = Feeds.store(preview(renamed))

    entry = Repo.one(Entry)
    assert entry.search_text =~ "one & three"
    refute entry.search_text =~ "one & two"
    assert entry.search_text =~ "notes with a link"
  end

  # A podcast's chapters file is fetched once, the first time somebody opens the item, through
  # the same guarded client as feeds. What it holds is stored; a failure is tried again later.
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

    test "an item without a chapters file has nothing to fetch" do
      {:ok, feed} = Feeds.store(preview())
      entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)
      assert Feeds.chapters(entry) == {:ok, nil}
    end
  end

  # Chapters fetched from a podcast's JSON file are stored on the entry. The feed itself names
  # only the file, so its next poll must not wipe what was fetched.
  # Chapters fetched from a file belong to that file. A feed that links another one has them
  # fetched again rather than keeping the old file's.
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

  test "a poll that names no chapters keeps the ones stored" do
    {:ok, feed} = Feeds.store(preview())
    stored = [%{"at" => 0, "title" => "Intro"}, %{"at" => 60, "title" => "Mitte"}]
    Repo.update_all(Entry, set: [chapters: stored, chapters_url: "https://example.org/c.json"])

    assert {:ok, _feed} = Feeds.store(preview())

    entry = Repo.one(from e in Entry, where: e.feed_id == ^feed.id)
    assert entry.chapters == stored
    assert entry.chapters_url == "https://example.org/c.json"
  end

  # The same, when the poll changes something else and so writes the row: an omitted file is no
  # new file.
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

  # A YouTube refresh fetches the Atom feed and nothing else, so it carries no picture. Replacing
  # the stored one with that nothing would empty the sidebar on the first poll after subscribing.
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

  defp assert_next_check(feed_id, hours: hours) do
    expected = DateTime.add(DateTime.utc_now(), hours, :hour)
    next = Repo.get!(Feed, feed_id).next_check_at
    assert abs(DateTime.diff(next, expected, :second)) < 60
  end
end
