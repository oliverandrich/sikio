defmodule Sikio.Feeds.DiscoveryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.HTTP

  test "a direct channel URL resolves straight to its Atom feed" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/feeds/videos.xml" ->
          assert conn.query_string == "channel_id=UCabcdefghijklmnopqrstuv"
          Plug.Conn.send_resp(conn, 200, youtube())

        "/channel/UCabcdefghijklmnopqrstuv" ->
          Plug.Conn.send_resp(conn, 200, channel_page())
      end
    end)

    assert {:ok, [%{kind: :youtube, title: "Good Channel"}]} =
             Discovery.discover("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv/videos")
  end

  test "YouTube feed URLs themselves can be pasted" do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, youtube()) end)

    assert {:ok, [%{kind: :youtube}]} =
             Discovery.discover(
               "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
             )

    assert {:error, :not_found} = Discovery.discover("https://www.youtube.com/feeds/videos.xml")
  end

  test "handles resolve through channel-owned RSS metadata" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/@good" ->
          Plug.Conn.send_resp(
            conn,
            200,
            ~s(<html><head><link rel="alternate" type="application/rss+xml" href="https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"></head></html>)
          )

        "/feeds/videos.xml" ->
          Plug.Conn.send_resp(conn, 200, youtube())
      end
    end)

    assert {:ok, [%{kind: :youtube}]} = Discovery.discover("youtube.com/@good/videos")
  end

  test "watch, short and shortened video URLs use the author's channel, never a related video" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/oembed" ->
          Req.Test.json(conn, %{
            author_url: "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv"
          })

        "/feeds/videos.xml" ->
          Plug.Conn.send_resp(conn, 200, youtube())

        "/channel/UCabcdefghijklmnopqrstuv" ->
          Plug.Conn.send_resp(conn, 200, channel_page())
      end
    end)

    for url <- [
          "https://youtu.be/abcdefghijk?t=30",
          "https://m.youtube.com/watch?v=abcdefghijk",
          "https://www.youtube.com/shorts/abcdefghijk",
          "https://www.youtube.com/live/abcdefghijk"
        ] do
      assert {:ok, [%{kind: :youtube}]} = Discovery.discover(url)
    end
  end

  test "a webpage discovers multiple podcast feeds and resolves relative links" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/shows" ->
          conn |> Plug.Conn.put_resp_header("location", "/shows/") |> Plug.Conn.send_resp(301, "")

        "/shows/" ->
          Plug.Conn.send_resp(
            conn,
            200,
            ~s(<link rel="alternate" type="application/rss+xml" href="one.xml"><a href="/two.rss">RSS</a>)
          )

        "/shows/one.xml" ->
          Plug.Conn.send_resp(conn, 200, podcast("First"))

        "/two.rss" ->
          Plug.Conn.send_resp(conn, 200, podcast("Second"))
      end
    end)

    assert {:ok, feeds} = Discovery.discover("https://example.org/shows")
    assert Enum.map(feeds, & &1.title) == ["First", "Second"]
  end

  test "direct podcast RSS is accepted and bogus pages yield a useful failure" do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    assert {:ok, [%{kind: :podcast}]} = Discovery.discover("https://example.org/rss")

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>Nothing here</html>") end)

    assert {:error, :not_found} = Discovery.discover("https://example.org/")
  end

  test "Apple search returns podcast sources only and safely encodes the query" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.request_path == "/search"
      params = URI.decode_query(conn.query_string)
      assert params["term"] == "a & b"
      assert params["media"] == "podcast"

      Req.Test.json(conn, %{
        results: [
          %{
            collectionId: 1,
            collectionName: "First",
            artistName: "Ada",
            feedUrl: "https://example.org/rss"
          },
          %{collectionId: 2, collectionName: "No feed"},
          %{collectionId: 3, collectionName: "Unsafe", feedUrl: "file:///etc/passwd"}
        ]
      })
    end)

    assert {:ok, [%{title: "First", author: "Ada", url: "https://example.org/rss"}]} =
             Discovery.search("a & b")
  end

  test "Apple show links resolve through lookup, not HTML scraping" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/lookup" ->
          assert URI.decode_query(conn.query_string)["id"] == "12345"
          Req.Test.json(conn, %{results: [%{feedUrl: "https://example.org/rss"}]})

        "/rss" ->
          Plug.Conn.send_resp(conn, 200, podcast())
      end
    end)

    assert {:ok, [%{kind: :podcast}]} =
             Discovery.discover("https://podcasts.apple.com/de/podcast/small-hours/id12345")
  end

  test "a channel's own page supplies the picture its feed does not carry" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/channel/UCabcdefghijklmnopqrstuv" ->
          Plug.Conn.send_resp(conn, 200, channel_page())

        "/feeds/videos.xml" ->
          Plug.Conn.send_resp(conn, 200, youtube())
      end
    end)

    assert {:ok, [feed]} =
             Discovery.discover("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv/videos")

    assert feed.icon_url == "https://yt3.googleusercontent.com/picture=s900-c-k-no-rj"
  end

  test "a pasted feed URL reaches the channel page for its picture too" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/channel/UCabcdefghijklmnopqrstuv" -> Plug.Conn.send_resp(conn, 200, channel_page())
        "/feeds/videos.xml" -> Plug.Conn.send_resp(conn, 200, youtube())
      end
    end)

    assert {:ok, [feed]} =
             Discovery.discover(
               "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
             )

    assert feed.icon_url == "https://yt3.googleusercontent.com/picture=s900-c-k-no-rj"
  end

  # The picture is decoration. A channel page that is slow, blocked or shaped differently must not
  # cost somebody the subscription they asked for.
  test "a channel without a reachable picture still subscribes" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/channel/UCabcdefghijklmnopqrstuv" -> Plug.Conn.send_resp(conn, 500, "nope")
        "/feeds/videos.xml" -> Plug.Conn.send_resp(conn, 200, youtube())
      end
    end)

    assert {:ok, [%{kind: :youtube, icon_url: nil}]} =
             Discovery.discover("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv")
  end

  # The same rule the feed's own artwork follows: an href in a document belongs to that document.
  test "a picture named relative to the channel page resolves against it" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/channel/UCabcdefghijklmnopqrstuv" ->
          Plug.Conn.send_resp(
            conn,
            200,
            String.replace(
              channel_page(),
              "https://yt3.googleusercontent.com/picture=s900-c-k-no-rj",
              "/img/avatar.jpg"
            )
          )

        "/feeds/videos.xml" ->
          Plug.Conn.send_resp(conn, 200, youtube())
      end
    end)

    assert {:ok, [feed]} =
             Discovery.discover("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv")

    assert feed.icon_url == "https://www.youtube.com/img/avatar.jpg"
  end
end
