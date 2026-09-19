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
end
