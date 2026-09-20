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
    assert refreshed.url == "https://example.org/rss"
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

  test "refreshing a source that is no longer stored says so" do
    assert {:error, :not_found} = Feeds.refresh(-1)
  end

  # Its own username, because another async test locks the shared feed row and a user row in the
  # opposite order, and two transactions taking the same two locks the other way round deadlock.
  defp subscriber(feed_id) do
    user = Repo.insert!(User.changeset(%User{}, %{username: "feeds_test_reader"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, _subscription} = Library.subscribe(user, preview)
    ^feed_id = Repo.one(from f in Sikio.Feeds.Feed, select: f.id)
    user.id
  end

  defp preview(body \\ podcast(), url \\ "https://example.org/rss") do
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
    Repo.update_all(Feed, set: [icon_url: nil])

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    assert {:ok, refreshed} = Feeds.refresh(feed.id)

    assert refreshed.icon_url == "https://img.example.org/show.jpg"
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
  test "a poll that omits artwork and notes keeps what was stored" do
    {:ok, _feed} = Feeds.store(preview())

    assert {:ok, _feed} = Feeds.store(preview(thin_podcast()))

    entry = Repo.one(Entry)
    assert entry.image_url == "https://img.example.org/1.jpg"
    assert entry.duration == 3723
    assert entry.excerpt == "Notes with a link."
  end

  # A YouTube refresh fetches the Atom feed and nothing else, so it carries no picture. Replacing
  # the stored one with that nothing would empty the sidebar on the first poll after subscribing.
  test "a refresh that carries no picture keeps the stored one" do
    {:ok, feed} =
      Feeds.store(%{
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv",
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
             Feeds.store(preview(peertube(), "https://video.example.org/feeds/videos.xml"))

    assert feed.kind == :peertube

    entry = Repo.one(Entry)
    assert entry.embed_url == "https://video.example.org/videos/embed/mSh0rtUu1d"
    assert entry.duration == 3600
  end
end
