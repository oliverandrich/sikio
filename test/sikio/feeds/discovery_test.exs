# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.DiscoveryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.HTTP

  # The HTML shell a PeerTube instance serves on every route. It advertises unrelated feeds.
  # It is not a feed, so discovery must query nodeinfo.
  defp instance_page do
    """
    <html><head>
    <link rel="alternate" type="application/rss+xml" title="Comments feed" href="https://video.example.org/feeds/video-comments.xml?videoId=99413b75" />
    <link rel="alternate" type="application/rss+xml" title="Videos feed" href="https://video.example.org/feeds/videos.xml" />
    </head><body></body></html>
    """
  end

  # `poll/2` returns the result and the server's requested wait in seconds, or nil.
  describe "poll/2" do
    defp answer(status, headers, body \\ "") do
      # `prepend_resp_headers/2` keeps duplicate header names.
      Req.Test.stub(HTTP, fn conn ->
        conn |> Plug.Conn.prepend_resp_headers(headers) |> Plug.Conn.send_resp(status, body)
      end)

      Discovery.poll(feed_url(), [])
    end

    test "a feed may be cached for its max-age or its ttl, whichever is longer" do
      ttl = String.replace(podcast(), "</channel>", "<ttl>90</ttl></channel>")

      assert {{:ok, _}, 7200} = answer(200, [{"cache-control", "public, max-age=7200"}], ttl)
      assert {{:ok, _}, 5400} = answer(200, [{"cache-control", "max-age=60"}], ttl)
      assert {{:ok, _}, nil} = answer(200, [], podcast())
    end

    test "an unchanged feed may be cached for its max-age" do
      assert {:not_modified, 600} = answer(304, [{"cache-control", "max-age=600"}])
      assert {:not_modified, nil} = answer(304, [{"cache-control", "no-cache"}])
      # Directive names are not case-sensitive.
      assert {:not_modified, 600} = answer(304, [{"cache-control", "Max-Age=600"}])
    end

    test "a server that is busy or down says when to come back, in seconds or as a date" do
      assert {{:error, :unavailable}, 120} = answer(503, [{"retry-after", "120"}])
      assert {{:error, :unavailable}, 3600} = answer(429, [{"retry-after", "3600"}])

      later =
        DateTime.utc_now()
        |> DateTime.add(1800, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      assert {{:error, :unavailable}, wait} = answer(503, [{"retry-after", later}])
      assert wait in 1790..1800

      assert {{:error, :unavailable}, nil} = answer(503, [{"retry-after", "whenever"}])
      # With a duplicate header, the first value is used.
      assert {{:error, :unavailable}, 120} =
               answer(503, [{"retry-after", "120"}, {"retry-after", "240"}])

      assert {{:error, :unavailable}, nil} = answer(503, [])
    end
  end

  # One input field accepts a URL or a search term. A bare host counts as a URL.
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
          case conn.query_string do
            "channel_id=UCabcdefghijklmnopqrstuv" -> Plug.Conn.send_resp(conn, 200, youtube())
            "playlist_id=UUSHabcdefghijklmnopqrstuv" -> Plug.Conn.send_resp(conn, 404, "")
          end

        "/channel/UCabcdefghijklmnopqrstuv" ->
          Plug.Conn.send_resp(conn, 200, channel_page())
      end
    end)

    assert {:ok, [%{kind: :youtube, title: "Good Channel"}]} =
             Discovery.discover("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv/videos")
  end

  # A channel's Atom feed does not mark Shorts. Entries listed in the channel's Shorts playlist
  # feed are marked as Shorts.
  describe "a YouTube channel's Shorts" do
    @channel_feed "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"

    defp answering_shorts(answer) do
      Req.Test.stub(HTTP, fn conn ->
        case conn.query_string do
          "channel_id=UCabcdefghijklmnopqrstuv" -> Plug.Conn.send_resp(conn, 200, youtube())
          "playlist_id=UUSHabcdefghijklmnopqrstuv" -> answer.(conn)
        end
      end)
    end

    defp shorts(result) do
      assert {{:ok, %{entries: entries}}, _wait} = result
      Enum.map(entries, & &1.short)
    end

    test "are marked as the channel's Shorts feed names them" do
      answering_shorts(&Plug.Conn.send_resp(&1, 200, youtube()))
      assert shorts(Discovery.poll(@channel_feed, [])) == [true]
    end

    test "are none for a channel the Shorts feed knows nothing of" do
      answering_shorts(&Plug.Conn.send_resp(&1, 404, ""))
      assert shorts(Discovery.poll(@channel_feed, [])) == [false]
    end

    # Playlist feeds, including the Shorts playlist, skip the Shorts lookup.
    test "are not looked up for a playlist" do
      Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, youtube()) end)
      playlist = "https://www.youtube.com/feeds/videos.xml?playlist_id=UUSHabcdefghijklmnopqrstuv"
      assert {{:ok, %{entries: [entry]}}, _wait} = Discovery.poll(playlist, [])
      refute entry[:short]
    end

    test "are not marked when the Shorts feed fails, and the poll still succeeds" do
      answering_shorts(&Plug.Conn.send_resp(&1, 500, ""))
      assert shorts(Discovery.poll(@channel_feed, [])) == [false]
    end
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

  describe "item/1 for YouTube" do
    # oEmbed names the channel and the video. The watch page carries the date.
    defp stub_video(watch_page) do
      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/oembed" ->
            Req.Test.json(conn, %{
              title: "An old video",
              author_url: "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv",
              thumbnail_url: "https://i.ytimg.com/vi/zzzzzzzzzzz/hqdefault.jpg"
            })

          "/feeds/videos.xml" ->
            Plug.Conn.send_resp(conn, 200, youtube())

          "/channel/UCabcdefghijklmnopqrstuv" ->
            Plug.Conn.send_resp(conn, 200, channel_page())

          "/watch" ->
            Plug.Conn.send_resp(conn, 200, watch_page)
        end
      end)
    end

    # A video in the channel's feed is taken from the feed, with its notes and date.
    test "a recent video is the feed's own entry" do
      stub_video("")

      assert {:ok, %{preview: preview, external_id: "yt:video:abcdefghijk"}} =
               Discovery.item("https://youtu.be/abcdefghijk")

      assert %{kind: :youtube, entries: [%{title: "A good video"}]} = preview
    end

    # An older video is missing from the feed. oEmbed gives its title and picture, the watch page
    # its date. The entry joins the channel's preview.
    test "an older video is built from oEmbed and dated by its watch page" do
      stub_video(
        ~s(<html><head><meta itemprop="datePublished" content="2023-04-01T08:00:00-07:00"></head></html>)
      )

      assert {:ok, %{preview: preview, external_id: "yt:video:zzzzzzzzzzz"}} =
               Discovery.item("https://www.youtube.com/watch?v=zzzzzzzzzzz")

      entry = Enum.find(preview.entries, &(&1.external_id == "yt:video:zzzzzzzzzzz"))
      assert %{title: "An old video", video_id: "zzzzzzzzzzz"} = entry
      assert entry.image_url == "https://i.ytimg.com/vi/zzzzzzzzzzz/hqdefault.jpg"
      assert entry.page_url == "https://www.youtube.com/watch?v=zzzzzzzzzzz"
      assert entry.published_at == ~U[2023-04-01 15:00:00Z]
    end

    # Without the date on the watch page the entry stays undated rather than invented.
    test "an older video without a date on its watch page stays undated" do
      stub_video("<html><head><title>Before you continue</title></head></html>")
      assert {:ok, %{preview: preview}} = Discovery.item("https://youtu.be/zzzzzzzzzzz")
      assert %{published_at: nil} = Enum.find(preview.entries, &(&1.video_id == "zzzzzzzzzzz"))
    end

    # An instance without HLS serves whole files. The largest at or below 1080p plays. Without
    # one, the smallest larger file plays.
    test "a video without a playlist plays its largest web file at or below 1080p" do
      chosen = fn heights ->
        files =
          for height <- heights,
              do: %{resolution: %{id: height}, fileUrl: "https://video.example.org/#{height}.mp4"}

        Req.Test.stub(HTTP, fn conn -> Req.Test.json(conn, %{files: files}) end)

        case Discovery.peertube_files("https://video.example.org/videos/embed/abc") do
          {:ok, files} -> files.media_url
          error -> error
        end
      end

      assert chosen.([0, 480, 2160, 1080, 720]) == "https://video.example.org/1080.mp4"
      assert chosen.([2160, 1440]) == "https://video.example.org/1440.mp4"
      assert chosen.([0]) == {:error, :unavailable}
    end

    test "a channel link is not a single item" do
      assert {:error, :not_an_item} =
               Discovery.item("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv")
    end
  end

  describe "item/1 for PeerTube" do
    @old %{
      name: "An older talk",
      uuid: "0b1d2c3e-1111-4222-8333-444455556666",
      shortUUID: "oLdV1d30000",
      publishedAt: "2024-05-01T10:00:00.000Z",
      duration: 1800,
      description: "What the talk covers.",
      thumbnailPath: "/lazy-static/thumbnails/old.jpg",
      embedPath: "/videos/embed/0b1d2c3e-1111-4222-8333-444455556666",
      channel: %{id: 7},
      # Web videos and the HLS playlist, as PeerTube lists them. The audio-only one has id 0.
      files: [
        %{resolution: %{id: 0}, fileUrl: "https://video.example.org/static/web-videos/a-0.mp4"}
      ],
      streamingPlaylists: [
        %{
          playlistUrl: "https://video.example.org/static/hls/master.m3u8",
          files: [
            %{resolution: %{id: 1080}, fileUrl: "https://video.example.org/static/hls/v-1080.mp4"}
          ]
        }
      ]
    }

    defp stub_instance do
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

          "/api/v1/videos/mSh0rtUu1d" ->
            Req.Test.json(conn, %{
              name: "A talk worth an hour",
              shortUUID: "mSh0rtUu1d",
              channel: %{id: 7}
            })

          "/api/v1/videos/" <> id
          when id in ["oLdV1d30000", "0b1d2c3e-1111-4222-8333-444455556666"] ->
            Req.Test.json(conn, @old)

          "/feeds/videos.xml" ->
            assert conn.query_string == "videoChannelId=7"
            Plug.Conn.send_resp(conn, 200, peertube())

          # A channel page links no episode, so it names no single item.
          "/c/good/videos" ->
            Plug.Conn.send_resp(conn, 200, "<html></html>")
        end
      end)
    end

    test "a recent video is the feed's own entry" do
      stub_instance()

      assert {:ok,
              %{
                preview: %{kind: :peertube},
                external_id: "https://video.example.org/w/mSh0rtUu1d"
              }} =
               Discovery.item("https://video.example.org/w/mSh0rtUu1d")
    end

    # The id is the watch address the instance's feed uses, so the entry matches the feed later.
    # The playlist is asked for at play time, as for a feed's videos. The audio-only file tells
    # the detail whether to offer the sound alone.
    test "an older video is built from the instance's API" do
      stub_instance()

      for url <- [
            "https://video.example.org/w/oLdV1d30000",
            "https://video.example.org/videos/watch/0b1d2c3e-1111-4222-8333-444455556666"
          ] do
        assert {:ok, %{preview: preview, external_id: id}} = Discovery.item(url)
        assert id == "https://video.example.org/w/oLdV1d30000"
        entry = Enum.find(preview.entries, &(&1.external_id == id))

        assert %{
                 title: "An older talk",
                 duration: 1800,
                 description: "What the talk covers.",
                 embed_url:
                   "https://video.example.org/videos/embed/0b1d2c3e-1111-4222-8333-444455556666",
                 image_url: "https://video.example.org/lazy-static/thumbnails/old.jpg",
                 page_url: "https://video.example.org/w/oLdV1d30000",
                 media_url: nil,
                 audio_url: "https://video.example.org/static/web-videos/a-0.mp4"
               } = entry

        assert entry.published_at == ~U[2024-05-01 10:00:00.000Z]
      end
    end

    # An instance without HLS serves whole files. The largest at or below 1080p plays. Without
    # one, the smallest larger file plays.
    test "a video without a playlist plays its largest web file at or below 1080p" do
      chosen = fn heights ->
        files =
          for height <- heights,
              do: %{resolution: %{id: height}, fileUrl: "https://video.example.org/#{height}.mp4"}

        Req.Test.stub(HTTP, fn conn -> Req.Test.json(conn, %{files: files}) end)

        case Discovery.peertube_files("https://video.example.org/videos/embed/abc") do
          {:ok, files} -> files.media_url
          error -> error
        end
      end

      assert chosen.([0, 480, 2160, 1080, 720]) == "https://video.example.org/1080.mp4"
      assert chosen.([2160, 1440]) == "https://video.example.org/1440.mp4"
      assert chosen.([0]) == {:error, :unavailable}
    end

    test "a channel link is not a single item" do
      stub_instance()
      assert {:error, :not_an_item} = Discovery.item("https://video.example.org/c/good/videos")
    end
  end

  describe "item/1 for podcast episodes" do
    # Apple's lookup lists the show and its episodes. The episode's guid finds it in the feed.
    defp stub_apple(guid) do
      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/lookup" ->
            assert URI.decode_query(conn.query_string)["entity"] == "podcastEpisode"

            Req.Test.json(conn, %{
              results: [
                %{wrapperType: "track", feedUrl: "https://feeds.example.org/small-hours"},
                %{wrapperType: "podcastEpisode", trackId: 1_000_456, episodeGuid: guid},
                %{wrapperType: "podcastEpisode", trackId: 1_000_999, episodeGuid: "other"}
              ]
            })

          "/small-hours" ->
            Plug.Conn.send_resp(conn, 200, podcast())
        end
      end)
    end

    test "an Apple Podcasts episode link finds the episode by its guid" do
      stub_apple("episode-1")

      assert {:ok, %{preview: %{title: "Small Hours"}, external_id: "episode-1"}} =
               Discovery.item("https://podcasts.apple.com/de/podcast/small-hours/id123?i=1000456")
    end

    # An episode the feed no longer lists cannot be saved, since nothing would play it.
    test "an Apple episode missing from the feed is refused" do
      stub_apple("gone")

      assert {:error, :not_found} =
               Discovery.item("https://podcasts.apple.com/de/podcast/small-hours/id123?i=1000456")
    end

    test "an Apple show link is not a single item" do
      assert {:error, :not_an_item} =
               Discovery.item("https://podcasts.apple.com/de/podcast/small-hours/id123")
    end

    # An episode page links its show's feed. The entry whose link is that page is the episode.
    # Only a PeerTube watch path asks the host for NodeInfo.
    test "an episode page finds the episode whose link it is" do
      parent = self()

      Req.Test.stub(HTTP, fn conn ->
        case conn.request_path do
          "/.well-known/nodeinfo" ->
            send(parent, :nodeinfo)
            Plug.Conn.send_resp(conn, 404, "")

          path when path in ["/episodes/1", "/show"] ->
            Plug.Conn.send_resp(
              conn,
              200,
              ~s(<link rel="alternate" type="application/rss+xml" href="/feed.xml">)
            )

          "/feed.xml" ->
            Plug.Conn.send_resp(conn, 200, podcast())
        end
      end)

      assert {:ok, %{external_id: "episode-1"}} = Discovery.item(podcast_page())
      assert {:error, :not_an_item} = Discovery.item(podcast_site())
      refute_received :nodeinfo
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

  # A page may list several candidate feeds. Sequential fetches would add up their latencies.
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
            feedUrl: "https://example.org/rss",
            artworkUrl100: "https://img.example/first-100.jpg"
          },
          %{collectionId: 2, collectionName: "No feed"},
          %{collectionName: "No cover", feedUrl: "https://example.org/bare"},
          %{
            collectionName: "Odd cover",
            feedUrl: "https://example.org/odd",
            artworkUrl100: "file:///etc/passwd"
          },
          %{collectionId: 3, collectionName: "Unsafe", feedUrl: "file:///etc/passwd"}
        ]
      })
    end)

    assert {:ok,
            [
              %{
                title: "First",
                author: "Ada",
                url: "https://example.org/rss",
                icon_url: "https://img.example/first-100.jpg"
              },
              %{title: "No cover", icon_url: nil},
              %{title: "Odd cover", icon_url: nil}
            ]} = Discovery.search("a & b")
  end

  # The directory searches by title. Only the show with the same feed URL lends its artwork, so
  # a namesake's cover never lands on the feed.
  test "Apple's directory lends artwork to the show with the same feed URL" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.request_path == "/search"
      assert URI.decode_query(conn.query_string)["term"] == "Talk ohne Gast"

      Req.Test.json(conn, %{
        results: [
          %{
            feedUrl: "https://other.example/feed.xml",
            artworkUrl600: "https://img.example/other.jpg"
          },
          %{feedUrl: "https://www.fritz.de/tog.xml", artworkUrl600: "https://img.example/tog.jpg"}
        ]
      })
    end)

    assert Discovery.directory_artwork("Talk ohne Gast", "https://www.fritz.de/tog.xml") ==
             {:ok, "https://img.example/tog.jpg"}

    assert Discovery.directory_artwork("Talk ohne Gast", "https://www.fritz.de/other.xml") ==
             {:error, :not_found}
  end

  # An outage is not an answer. The caller asks again later.
  test "an unreachable directory is told apart from a show it does not list" do
    Req.Test.stub(HTTP, &Plug.Conn.send_resp(&1, 503, ""))

    assert Discovery.directory_artwork("Talk ohne Gast", "https://www.fritz.de/tog.xml") ==
             {:error, :unavailable}
  end

  # The directory search refuses such a term too. Nothing is asked.
  test "a title too short to search lends no artwork" do
    Req.Test.stub(HTTP, fn _conn -> flunk("the directory was asked") end)

    assert Discovery.directory_artwork(" X ", "https://www.fritz.de/tog.xml") ==
             {:error, :not_found}
  end

  describe "mediathek_search/2" do
    defp hit(title, extra \\ %{}) do
      Map.merge(
        %{
          id: "id-" <> title,
          channel: "WDR",
          topic: "Tatort",
          title: title,
          description: "Fernsehfilm Deutschland 2025",
          timestamp: 1_791_656_100,
          duration: 5322,
          url_website: "https://www.ardmediathek.de/video/abc",
          url_video: "https://wdr.example/v.mp4",
          url_video_hd: "https://wdr.example/v-hd.mp4"
        },
        extra
      )
    end

    # The newest programmes come first. Variants of one programme are left out: audio
    # description, plain language, sign language and trailers.
    test "returns programmes without their variants, newest first" do
      Req.Test.stub(HTTP, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/query"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        query = Jason.decode!(body)
        assert [%{"fields" => ["title", "topic"], "query" => "tatort"}] = query["queries"]
        assert %{"sortBy" => "timestamp", "sortOrder" => "desc", "future" => false} = query
        assert %{"offset" => 0, "size" => 30} = query, "one modest page, as the maintainer asks"

        Req.Test.json(conn, %{
          result: %{
            results: [
              hit("Die Erfindung des Rades"),
              hit("Die Erfindung des Rades (Audiodeskription)"),
              hit("Die Erfindung des Rades (klare Sprache)"),
              hit("Die Erfindung des Rades (mit Gebärdensprache)"),
              hit("Trailer: Die Erfindung des Rades"),
              hit("Ohne HD", %{
                url_video_hd: "",
                description: 7,
                url_website: "https://www.ardmediathek.de/video/ohne-hd"
              }),
              # Media from plain http breaks the content security policy.
              hit("Nur http", %{url_video_hd: "", url_video: "http://wdr.example/v.mp4"}),
              # A broken timestamp drops its programme, not the search.
              hit("Kaputte Zeit", %{timestamp: 999_999_999_999_999}),
              # A geo-blocked copy of a programme gives way to the open one. ZDF marks it /de/.
              hit("Geo", %{
                url_website: "https://www.ardmediathek.de/video/geo",
                url_video_hd: "https://zdf.example/de/zdf/v.mp4"
              }),
              hit("Geo", %{
                id: "id-Geo-open",
                url_website: "https://www.ardmediathek.de/video/geo",
                url_video_hd: "https://swr.example/v.mp4"
              })
            ]
          }
        })
      end)

      assert {:ok, [rades, without_hd, geo]} =
               Discovery.mediathek_search("tatort", "https://mediathek.example")

      assert %{id: "id-Geo-open", media_url: "https://swr.example/v.mp4"} = geo

      assert rades == %{
               id: "id-Die Erfindung des Rades",
               title: "Die Erfindung des Rades",
               channel: "WDR",
               topic: "Tatort",
               description: "Fernsehfilm Deutschland 2025",
               published_at: ~U[2026-10-10 18:15:00Z],
               duration: 5322,
               media_url: "https://wdr.example/v-hd.mp4",
               page_url: "https://www.ardmediathek.de/video/abc"
             }

      assert without_hd.media_url == "https://wdr.example/v.mp4", "HD first, else the default"
      assert without_hd.description == nil
    end

    # A programme is saved like a single YouTube video. Its source is the search for its topic
    # on its channel, the feed a series subscription would follow.
    test "a programme becomes the preview of its topic on its channel" do
      programme = %{
        id: "abc=",
        title: "Die Erfindung des Rades",
        channel: "WDR",
        topic: "Tatort",
        description: "Fernsehfilm",
        published_at: ~U[2026-10-10 18:15:00Z],
        duration: 5322,
        media_url: "https://wdr.example/v-hd.mp4",
        page_url: "https://www.ardmediathek.de/video/abc"
      }

      # The broadcaster's page names the programme. MediathekViewWeb's id can change.
      assert %{
               preview: preview,
               external_id: "https://www.ardmediathek.de/video/abc Die Erfindung des Rades"
             } = Discovery.mediathek_item(programme)

      assert %{kind: :mediathek, title: "Tatort · WDR", icon_url: nil} = preview

      # One page of 20, as the maintainer asks for sparing use.
      assert URI.decode_query(URI.parse(preview.url).query) == %{
               "query" => "!WDR #Tatort",
               "everywhere" => "false",
               "future" => "false",
               "size" => "20"
             }

      # Commas join a topic's words. With spaces MediathekViewWeb also matches "Die Maus".
      %{preview: maus} =
        Discovery.mediathek_item(%{programme | topic: "Die Sendung mit der Maus"})

      assert URI.decode_query(URI.parse(maus.url).query)["query"] ==
               "!WDR #Die,Sendung,mit,der,Maus"

      # A comma inside a topic would split it into two terms.
      %{preview: sturm} = Discovery.mediathek_item(%{programme | topic: "Sturm, Liebe & Co"})
      assert URI.decode_query(URI.parse(sturm.url).query)["query"] == "!WDR #Sturm,Liebe,&,Co"

      # The public instance names the source, whichever instance `MEDIATHEK_URL` searches.
      assert String.starts_with?(preview.url, "https://mediathekviewweb.de/feed?")

      # A programme without a topic belongs to its channel alone.
      %{preview: bare} = Discovery.mediathek_item(%{programme | topic: ""})
      assert bare.title == "WDR"
      assert URI.decode_query(URI.parse(bare.url).query)["query"] == "!WDR"

      assert [
               %{
                 external_id: "https://www.ardmediathek.de/video/abc Die Erfindung des Rades",
                 title: "Die Erfindung des Rades",
                 media_url: "https://wdr.example/v-hd.mp4",
                 page_url: "https://www.ardmediathek.de/video/abc",
                 published_at: ~U[2026-10-10 18:15:00Z],
                 duration: 5322,
                 description: "Fernsehfilm",
                 description_format: :text
               }
             ] = preview.entries
    end

    # A series is the feed of a topic on a channel. Another instance answers, but the source
    # keeps the public address, so every account shares one source.
    test "a series is fetched from the configured instance under the public address" do
      url = "https://mediathekviewweb.de/feed?query=%21ard+%23Tatort&size=20"

      Req.Test.stub(HTTP, fn conn ->
        assert Plug.Conn.get_req_header(conn, "host") == ["mediathek.example"]
        assert conn.request_path == "/feed"
        assert URI.decode_query(conn.query_string)["query"] == "!ard #Tatort"
        Plug.Conn.send_resp(conn, 200, mediathek_feed())
      end)

      assert {:ok, [%{url: ^url, kind: :mediathek, entries: [_]}]} =
               Discovery.mediathek_series(url, base: "https://mediathek.example")

      # A trailing slash on the instance address does not double the path's slash.
      assert {:ok, [_]} = Discovery.mediathek_series(url, base: "https://mediathek.example/")
    end

    # A subscription that takes every present programme asks once for a larger page. The source
    # keeps its page of 20, which every refresh asks for.
    test "a series is fetched once with a larger page, and keeps its own" do
      url = "https://mediathekviewweb.de/feed?query=%21ard+%23Tatort&size=20"

      Req.Test.stub(HTTP, fn conn ->
        assert %{"query" => "!ard #Tatort", "size" => "100"} = URI.decode_query(conn.query_string)
        Plug.Conn.send_resp(conn, 200, mediathek_feed())
      end)

      for base <- ["https://mediathekviewweb.de", "https://mediathek.example"] do
        assert {:ok, [%{url: ^url}]} = Discovery.mediathek_series(url, base: base, size: 100)
      end

      # An address without a query still gets its size.
      bare = "https://mediathekviewweb.de/feed"

      Req.Test.stub(HTTP, fn conn ->
        assert URI.decode_query(conn.query_string) == %{"size" => "100"}
        Plug.Conn.send_resp(conn, 200, mediathek_feed())
      end)

      assert {:ok, [%{url: ^bare}]} = Discovery.mediathek_series(bare, size: 100)
    end

    test "an unreachable Mediathek says so, and a term too short is not sent" do
      Req.Test.stub(HTTP, &Plug.Conn.send_resp(&1, 503, ""))

      assert Discovery.mediathek_search("tatort", "https://mediathek.example") ==
               {:error, :mediathek_unavailable}

      assert Discovery.mediathek_search(" x ", "https://mediathek.example") ==
               {:error, :invalid_search}
    end
  end

  # A broadcaster's page names its preview picture. KiKA writes `name` where others write
  # `property`. A relative address resolves against the page.
  test "a page's picture comes from its og:image" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/property" ->
          Plug.Conn.send_resp(conn, 200, ~s(<meta property="og:image" content="/img/a.jpg">))

        "/name" ->
          Plug.Conn.send_resp(
            conn,
            200,
            ~s(<meta name="og:image" content="https://img.example/b.jpg">)
          )

        "/bare" ->
          Plug.Conn.send_resp(conn, 200, "<title>No picture</title>")

        "/down" ->
          Plug.Conn.send_resp(conn, 503, "")

        "/busy" ->
          Plug.Conn.send_resp(conn, 429, "")

        "/forbidden" ->
          Plug.Conn.send_resp(conn, 403, "")

        "/moved" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/new/page")
          |> Plug.Conn.send_resp(301, "")

        "/new/page" ->
          Plug.Conn.send_resp(conn, 200, ~s(<meta property="og:image" content="img.jpg">))
      end
    end)

    assert Discovery.page_picture("https://www.ard.example/property") ==
             {:ok, "https://www.ard.example/img/a.jpg"}

    assert Discovery.page_picture("https://www.kika.example/name") ==
             {:ok, "https://img.example/b.jpg"}

    assert Discovery.page_picture("https://www.ard.example/bare") == {:error, :not_found}
    assert Discovery.page_picture("https://www.ard.example/down") == {:error, :unavailable}
    assert Discovery.page_picture("https://www.ard.example/busy") == {:error, :unavailable}

    # A refusal does not change on a retry.
    assert Discovery.page_picture("https://www.ard.example/forbidden") == {:error, :not_found}

    # A relative picture resolves against the page the redirect led to.
    assert Discovery.page_picture("https://www.ard.example/moved") ==
             {:ok, "https://www.ard.example/new/img.jpg"}
  end

  # Apple also finds single episodes. Each names its podcast's feed and its guid there.
  test "Apple's episode search returns episodes with their podcast's feed" do
    Req.Test.stub(HTTP, fn conn ->
      params = URI.decode_query(conn.query_string)
      assert %{"entity" => "podcastEpisode", "term" => "tatort", "limit" => "20"} = params

      Req.Test.json(conn, %{
        results: [
          %{
            trackName: "Einer von uns",
            collectionName: "ARD Radio Tatort",
            feedUrl: "https://feeds.example.org/tatort.xml",
            episodeGuid: "guid-1",
            releaseDate: "2026-09-17T22:01:00Z",
            trackTimeMillis: 3_223_000,
            description: "Ein tödlicher Schusswechsel.",
            artworkUrl160: "https://img.example/160.jpg"
          },
          %{trackName: "Without a feed", episodeGuid: "guid-2"},
          # Apple passes the guid and description as the feed writes them.
          %{
            trackName: "Odd",
            feedUrl: "https://feeds.example.org/odd.xml",
            episodeGuid: " guid-3\n",
            description: 42
          },
          %{
            trackName: "Long",
            feedUrl: "https://feeds.example.org/long.xml",
            episodeGuid: String.duplicate("g", 2001),
            description: String.duplicate("d", 3000)
          }
        ]
      })
    end)

    assert {:ok, [episode, odd, long]} = Discovery.episode_search("tatort")

    assert episode == %{
             id: "guid-1",
             title: "Einer von uns",
             podcast: "ARD Radio Tatort",
             feed_url: "https://feeds.example.org/tatort.xml",
             icon_url: "https://img.example/160.jpg",
             published_at: ~U[2026-09-17 22:01:00Z],
             duration: 3223,
             description: "Ein tödlicher Schusswechsel."
           }

    # The guid matches the feed's entry as the parser stores it.
    assert %{id: "guid-3", description: nil} = odd
    assert "sha256:" <> _ = long.id
    assert String.length(long.description) == 2000
  end

  # Saving an episode reads its podcast's feed, so the entry is the feed's own.
  test "an episode found by the search becomes the preview of its podcast" do
    id = "episode-1"

    Req.Test.stub(HTTP, &Plug.Conn.send_resp(&1, 200, podcast()))

    assert {:ok, %{preview: %{kind: :podcast}, external_id: ^id}} =
             Discovery.episode_item(%{feed_url: "https://feeds.example.org/p.xml", id: id})

    assert {:error, :not_found} =
             Discovery.episode_item(%{feed_url: "https://feeds.example.org/p.xml", id: "gone"})
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

  # The channel picture is optional. A failed channel page fetch must not fail discovery.
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

  # A relative href resolves against the document that contains it, as for feed artwork.
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

  # Any host may run PeerTube, so no hostname list can identify it. Detection uses nodeinfo.
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

  # A host whose nodeinfo names other software, such as Mastodon, is not PeerTube.
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

  # A PeerTube video page advertises its comment feed and the instance feed.
  # Discovery uses the video API to subscribe to the publishing channel instead.
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

  # An instance serves the same HTML shell on every route. A pasted URL may be any of them.
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
