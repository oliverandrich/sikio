# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.DiscoveryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.HTTP

  # What an instance answers at any of its pages: an application shell that advertises feeds
  # nobody asked for. Deliberately not a feed, so the discovery has to ask what runs here.
  defp instance_page do
    """
    <html><head>
    <link rel="alternate" type="application/rss+xml" title="Comments feed" href="https://video.example.org/feeds/video-comments.xml?videoId=99413b75" />
    <link rel="alternate" type="application/rss+xml" title="Videos feed" href="https://video.example.org/feeds/videos.xml" />
    </head><body></body></html>
    """
  end

  # One field takes a link or a search. What reads as an address is looked up; everything else is
  # searched for. A bare host counts as an address, since that is how people paste one.
  describe "intent/1" do
    test "an address with a scheme or a bare host is a link" do
      for input <- [
            "https://www.youtube.com/@kurzgesagt",
            "http://example.org/feed.xml",
            "youtube.com/@kurzgesagt",
            "radiolab.org",
            "  feeds.transistor.fm/metacheles  ",
            "podcasts.apple.com/de/podcast/id123"
          ] do
        assert Discovery.intent(input) == {:link, String.trim(input)}, input
      end
    end

    test "words, names and a title with a full stop are a search" do
      for input <- [
            "Logbuch Netzpolitik",
            "Mr. Robot",
            "radiolab",
            "99% Invisible",
            " Lage der Nation "
          ] do
        assert Discovery.intent(input) == {:search, String.trim(input)}, input
      end
    end

    test "nothing is nothing" do
      assert Discovery.intent("") == :empty
      assert Discovery.intent("   ") == :empty
    end
  end

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
        "/.well-known/nodeinfo" ->
          Plug.Conn.send_resp(conn, 404, "")

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

  # A page may advertise five feeds. Asking them one after another makes whoever pasted the page
  # wait for the slowest five times over.
  test "a webpage's candidate feeds are fetched at the same time" do
    test = self()

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/.well-known/nodeinfo" ->
          Plug.Conn.send_resp(conn, 404, "")

        "/shows" ->
          Plug.Conn.send_resp(conn, 200, ~s(<a href="/one.rss">1</a><a href="/two.rss">2</a>))

        "/" <> name ->
          held(test, fn -> Plug.Conn.send_resp(conn, 200, podcast(name)) end)
      end
    end)

    task = Task.async(fn -> Discovery.discover("https://example.org/shows") end)

    assert {:ok, feeds} = release_together(task, 2)
    assert Enum.map(feeds, & &1.title) == ["one.rss", "two.rss"]
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

  # Any host may run PeerTube, so nothing can be recognised from a list of names. The instance
  # says what it runs, and that answer is what decides.
  test "a PeerTube instance is recognised by what it says it runs" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        path when path in [nil, "/", "/c/good/videos", "/w/mSh0rtUu1d"] ->
          Plug.Conn.send_resp(conn, 200, instance_page())

        "/.well-known/nodeinfo" ->
          Req.Test.json(conn, %{
            links: [
              %{
                rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
                href: "https://video.example.org/nodeinfo/2.0.json"
              }
            ]
          })

        "/nodeinfo/2.0.json" ->
          Req.Test.json(conn, %{software: %{name: "peertube", version: "8.3.0"}})

        "/feeds/videos.xml" ->
          Plug.Conn.send_resp(conn, 200, peertube())
      end
    end)

    assert {:ok, [%{kind: :peertube, title: "Good Instance Videos"}]} =
             Discovery.discover("https://video.example.org")
  end

  # A blog that happens to answer nodeinfo is not an instance of anything playable.
  test "a host running something else is not treated as PeerTube" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        path when path in [nil, "/"] ->
          Plug.Conn.send_resp(conn, 200, "<html><body>a blog</body></html>")

        "/.well-known/nodeinfo" ->
          Req.Test.json(conn, %{
            links: [
              %{
                rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
                href: "https://social.example.org/nodeinfo/2.0.json"
              }
            ]
          })

        "/nodeinfo/2.0.json" ->
          Req.Test.json(conn, %{software: %{name: "mastodon", version: "4.3.0"}})
      end
    end)

    assert {:error, :not_found} = Discovery.discover("https://social.example.org")
  end

  test "a PeerTube channel URL resolves to the feed of that channel" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        path when path in [nil, "/", "/c/good/videos", "/w/mSh0rtUu1d"] ->
          Plug.Conn.send_resp(conn, 200, instance_page())

        "/.well-known/nodeinfo" ->
          Req.Test.json(conn, %{
            links: [
              %{
                rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
                href: "https://video.example.org/nodeinfo/2.0.json"
              }
            ]
          })

        "/nodeinfo/2.0.json" ->
          Req.Test.json(conn, %{software: %{name: "peertube"}})

        "/api/v1/video-channels/good" ->
          Req.Test.json(conn, %{id: 7, displayName: "Good Channel"})

        "/feeds/videos.xml" ->
          assert conn.query_string == "videoChannelId=7"
          Plug.Conn.send_resp(conn, 200, peertube())
      end
    end)

    assert {:ok, [%{kind: :peertube}]} =
             Discovery.discover("https://video.example.org/c/good/videos")
  end

  # A PeerTube video page advertises its own comment feed and the feed of the whole instance.
  # Searching the page for links would take one of those. The channel that published the video
  # is what somebody pasting a video means.
  test "a pasted PeerTube video subscribes to its channel, not to its comments" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        path when path in [nil, "/", "/c/good/videos", "/w/mSh0rtUu1d"] ->
          Plug.Conn.send_resp(conn, 200, instance_page())

        "/.well-known/nodeinfo" ->
          Req.Test.json(conn, %{
            links: [
              %{
                rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
                href: "https://video.example.org/nodeinfo/2.0.json"
              }
            ]
          })

        "/nodeinfo/2.0.json" ->
          Req.Test.json(conn, %{software: %{name: "peertube"}})

        "/api/v1/videos/mSh0rtUu1d" ->
          Req.Test.json(conn, %{channel: %{id: 7, displayName: "Good Channel"}})

        "/feeds/videos.xml" ->
          assert conn.query_string == "videoChannelId=7"
          Plug.Conn.send_resp(conn, 200, peertube())

        "/feeds/video-comments.xml" ->
          flunk("subscribed to the comments of a video")
      end
    end)

    assert {:ok, [%{kind: :peertube, title: "Good Instance Videos"}]} =
             Discovery.discover("https://video.example.org/w/mSh0rtUu1d")
  end

  # An instance serves every one of its routes as the same application shell, so the address
  # somebody copied out of their browser may be any of them.
  test "the other addresses an instance answers under also reach their feed" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/.well-known/nodeinfo" ->
          Req.Test.json(conn, %{
            links: [
              %{
                rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
                href: "https://video.example.org/nodeinfo/2.0.json"
              }
            ]
          })

        "/nodeinfo/2.0.json" ->
          Req.Test.json(conn, %{software: %{name: "peertube"}})

        "/api/v1/video-channels/good" ->
          Req.Test.json(conn, %{id: 7})

        "/api/v1/accounts/somebody" ->
          Req.Test.json(conn, %{id: 3})

        "/feeds/videos.xml" ->
          assert conn.query_string in ["videoChannelId=7", "accountId=3"]
          Plug.Conn.send_resp(conn, 200, peertube())

        _ ->
          Plug.Conn.send_resp(conn, 200, instance_page())
      end
    end)

    for url <- [
          "https://video.example.org/video-channels/good",
          "https://video.example.org/video-channels/good/videos",
          "https://video.example.org/a/somebody",
          "https://video.example.org/accounts/somebody/videos"
        ] do
      assert {:ok, [%{kind: :peertube}]} = Discovery.discover(url), "#{url} found no feed"
    end
  end
end
