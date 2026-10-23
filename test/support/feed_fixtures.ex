# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.FeedFixtures do
  @moduledoc false

  @doc """
  Returns a feed URL that no other test uses.

  Same reason as `Sikio.DataCase.unique_username/1`: about every second test writes a feed row.
  Any host works. `config/test.exs` pins the resolver, so no DNS lookup happens.
  """
  def feed_url(path \\ "rss"), do: "https://feed#{Sikio.DataCase.unique()}.example.org/#{path}"

  @doc """
  Returns a YouTube channel feed URL that no other test uses.

  The parser requires YouTube's host and a channel id in YouTube's format, so only the id varies.
  The fixture document keeps its own channel id. Nothing compares the two.
  """
  def youtube_feed_url do
    id = String.pad_leading(Sikio.DataCase.unique(), 22, "a")
    "https://www.youtube.com/feeds/videos.xml?channel_id=UC#{id}"
  end

  @doc "Returns a PeerTube instance feed URL that no other test uses."
  def peertube_feed_url, do: feed_url("feeds/videos.xml")

  @doc "A MediathekViewWeb search feed: one programme, its sign-language variant and a plain http file."
  def mediathek_feed do
    """
    <?xml version="1.0" encoding="UTF-8"?><rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
      <channel>
        <title><![CDATA[MVW - !ard #Die,Sendung,mit,der,Maus | Überall]]></title>
        <generator>RSS for Node</generator>
        <ttl>75</ttl>
        <item>
          <title><![CDATA[Sachgeschichte: Immer geradeaus]]></title>
          <description><![CDATA[Wie fährt ein Zug geradeaus?]]></description>
          <link>https://ard.example.org/maus/1.mp4</link>
          <guid isPermaLink="false">maus-1=</guid>
          <category><![CDATA[Die Sendung mit der Maus]]></category>
          <dc:creator><![CDATA[ARD]]></dc:creator>
          <pubDate>Sun, 04 Oct 2026 07:30:00 GMT</pubDate>
          <enclosure url="https://ard.example.org/maus/1.mp4" length="1000" type="video/mp4"/>
          <duration>1800</duration>
          <websiteUrl>https://www.ardmediathek.de/video/maus-1</websiteUrl>
        </item>
        <item>
          <title><![CDATA[Sachgeschichte: Immer geradeaus (Gebärdensprache)]]></title>
          <link>https://ard.example.org/maus/1-dgs.mp4</link>
          <guid isPermaLink="false">maus-1-dgs=</guid>
          <category><![CDATA[Die Sendung mit der Maus]]></category>
          <dc:creator><![CDATA[ARD]]></dc:creator>
          <pubDate>Sun, 04 Oct 2026 07:30:00 GMT</pubDate>
          <enclosure url="https://ard.example.org/maus/1-dgs.mp4" length="1000" type="video/mp4"/>
        </item>
        <item>
          <title><![CDATA[Nur über http]]></title>
          <guid isPermaLink="false">maus-2=</guid>
          <pubDate>Sun, 27 Sep 2026 07:30:00 GMT</pubDate>
          <enclosure url="http://ard.example.org/maus/2.mp4" length="1000" type="video/mp4"/>
        </item>
      </channel>
    </rss>
    """
  end

  @doc """
  Returns a programme as `Sikio.Feeds.Discovery.mediathek_search/2` returns it.

  Its id, topic and addresses are unique, so no other test writes the same rows.
  """
  def mediathek_programme do
    n = Sikio.DataCase.unique()

    %{
      id: "programme-#{n}=",
      title: "Die Erfindung des Rades",
      channel: "WDR",
      topic: "Tatort #{n}",
      description: "Fernsehfilm",
      published_at: ~U[2026-10-10 18:15:00Z],
      duration: 5322,
      media_url: "https://wdr#{n}.example.org/v-hd.mp4",
      page_url: "https://mediathek#{n}.example.org/video/abc"
    }
  end

  @doc """
  Blocks a stubbed request until it receives `:release`, then returns `respond.()`.

  Each held request sends `{:held, pid}` to `test`.
  Two messages before any release show two concurrent requests.
  With sequential requests, the second starts only after the first is released.
  """
  def held(test, respond) do
    send(test, {:held, self()})

    receive do
      :release -> respond.()
    end
  end

  @doc "Waits until `count` requests are held at once, then releases them and any later ones."
  def release_together(%Task{} = task, count) do
    import ExUnit.Assertions
    held = for _ <- 1..count, do: assert_receive({:held, _pid}, 1_000) |> elem(1)
    Enum.each(held, &send(&1, :release))
    released(task)
  end

  defp released(%Task{ref: ref} = task) do
    receive do
      {:held, pid} ->
        send(pid, :release)
        released(task)

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result
    after
      1_000 -> ExUnit.Assertions.flunk("the task neither finished nor sent another request")
    end
  end

  @doc """
  Test resolver. Maps every host to one address, so no test reaches DNS.
  `two-addresses.example.org` has a second address, which comes first.
  """
  def resolve("two-addresses.example.org"), do: {:ok, [{93, 184, 216, 35}, {93, 184, 216, 34}]}
  def resolve(_host), do: {:ok, [{93, 184, 216, 34}]}

  @doc "The episode page URL in the podcast fixture."
  def podcast_page, do: "https://example.org/episodes/1"

  @doc "The podcast fixture with a second episode, titled Later, published one day later."
  def podcast_later do
    String.replace(
      podcast(),
      "</channel>",
      "<item><guid>episode-2</guid><title>Later</title><pubDate>Sat, 19 Sep 2026 09:00:00 GMT</pubDate>" <>
        ~s(<enclosure url="https://example.org/2.mp3" type="audio/mpeg" length="1"/></item></channel>)
    )
  end

  @doc "The website URL in the podcast fixture's channel."
  def podcast_site, do: "https://example.org/show"

  def podcast(title \\ "Small Hours") do
    """
    <?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel><title>#{title}</title><link>#{podcast_site()}</link><description>A thoughtful podcast</description>
    <itunes:image href="https://img.example.org/show.jpg" />
    <item><guid>episode-1</guid><title>One &amp; two</title><link>#{podcast_page()}</link><pubDate>Fri, 18 Sep 2026 09:00:00 GMT</pubDate>
    <itunes:image href="https://img.example.org/1.jpg" />
    <itunes:duration>01:02:03</itunes:duration>
    <description>Plain summary</description>
    <content:encoded><![CDATA[<p>Notes with a <a href="https://example.org">link</a>.</p><script>alert(1)</script>]]></content:encoded>
    <enclosure url="https://audio.example.org/1.mp3" type="audio/mpeg" length="12" /></item></channel></rss>
    """
  end

  @doc "The podcast fixture without links, episode image, duration, description or show notes."
  def thin_podcast do
    podcast()
    |> String.replace("<link>#{podcast_site()}</link>", "")
    |> String.replace("<link>#{podcast_page()}</link>", "")
    |> String.replace(~r|<itunes:image href="https://img.example.org/1.jpg" />|, "")
    |> String.replace(~r|<itunes:duration>[^<]*</itunes:duration>|, "")
    |> String.replace(~r|<description>Plain summary</description>|, "")
    |> String.replace(~r|<content:encoded>.*?</content:encoded>|s, "")
  end

  @doc "The podcast fixture, or `feed`, with `href` in `atom:link rel=\"self\"`."
  def podcast_naming(href, feed \\ podcast()) do
    feed
    |> String.replace(
      ~s|<rss version="2.0"|,
      ~s|<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"|
    )
    |> String.replace("<channel>", ~s|<channel><atom:link rel="self" href="#{href}" />|)
  end

  @doc "The podcast fixture with `duration` as the episode's `itunes:duration`."
  def podcast_lasting(duration) do
    String.replace(
      podcast(),
      "<itunes:duration>01:02:03</itunes:duration>",
      "<itunes:duration>#{duration}</itunes:duration>"
    )
  end

  @doc "A PeerTube channel feed with the elements a real instance publishes."
  def peertube do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:media="http://search.yahoo.com/mrss/" xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel>
    <title>Good Instance Videos</title>
    <link>https://video.example.org/c/9f1b2c3d-0000-4444-8888-aaaabbbbcccc/videos</link>
    <generator>PeerTube - https://video.example.org</generator>
    <image><url>https://video.example.org/lazy-static/avatars/channel.jpg</url></image>
    <item>
    <title>A talk worth an hour</title>
    <link>https://video.example.org/w/mSh0rtUu1d</link>
    <guid>https://video.example.org/w/mSh0rtUu1d</guid>
    <pubDate>Thu, 18 Jun 2026 15:43:13 GMT</pubDate>
    <content:encoded><![CDATA[<p>Slides are <a href="https://video.example.org/s">here</a>.</p>]]></content:encoded>
    <dc:creator>Good Channel</dc:creator>
    <enclosure length="1004043852" type="video/mp4" url="https://video.example.org/download/videos/generate/99413b75?videoFileIds=1" />
    <media:thumbnail url="https://video.example.org/lazy-static/thumbnails/8b1f64dd.jpg" height="1400" width="1400" />
    <media:embed url="https://video.example.org/videos/embed/mSh0rtUu1d" />
    <media:player url="https://video.example.org/w/mSh0rtUu1d" />
    <media:group>
    <media:content type="audio/mp4" medium="video" height="0" url="https://video.example.org/static/a.mp4" duration="3600" isDefault="true" />
    <media:content type="video/mp4" medium="video" height="360" url="https://video.example.org/static/v.mp4" duration="3600" isDefault="false" />
    </media:group>
    </item>
    </channel></rss>
    """
  end

  @doc "A YouTube channel page with only the two elements that discovery reads."
  def channel_page do
    """
    <html><head>
    <meta property="og:image" content="https://yt3.googleusercontent.com/picture=s900-c-k-no-rj">
    <link rel="alternate" type="application/rss+xml" href="https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv">
    </head></html>
    """
  end

  # YouTube's format: `yt:channelId` omits the `UC` prefix that the entries' ids carry.
  def youtube do
    """
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/">
      <title>Good Channel</title><yt:channelId>abcdefghijklmnopqrstuv</yt:channelId>
      <entry><id>yt:video:abcdefghijk</id><yt:videoId>abcdefghijk</yt:videoId><title>A good video</title>
      <link rel="alternate" href="https://www.youtube.com/watch?v=abcdefghijk"/>
      <published>2026-09-17T12:00:00+00:00</published>
      <media:group>
        <media:thumbnail url="https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg" width="480" height="360" />
        <media:description>What the video is about.</media:description>
      </media:group>
      </entry>
    </feed>
    """
  end

  @doc """
  YouTube's results page with `hits` in `ytInitialData`, nested as the page nests them.

  Each hit is a map such as `youtube_channel_hit/2` or `youtube_video_hit/2` returns.
  """
  def youtube_results(hits) do
    data = %{
      contents: %{
        twoColumnSearchResultsRenderer: %{
          primaryContents: %{
            sectionListRenderer: %{contents: [%{itemSectionRenderer: %{contents: hits}}]}
          }
        }
      }
    }

    """
    <html><head><title>YouTube</title></head><body>
    <script>var ytInitialData = #{Jason.encode!(data)};</script>
    </body></html>
    """
  end

  # The page writes avatar addresses without a scheme and puts the subscriber count in
  # `videoCountText`.
  def youtube_channel_hit(name, attrs \\ %{}) do
    %{
      channelRenderer:
        Map.merge(
          %{
            channelId: "UC" <> String.pad_trailing(name, 22, "x"),
            title: %{simpleText: "Channel " <> name},
            thumbnail: %{
              thumbnails: [
                %{url: "//yt3.ggpht.com/#{name}=s88", width: 88, height: 88},
                %{url: "//yt3.ggpht.com/#{name}=s176", width: 176, height: 176}
              ]
            },
            videoCountText: %{simpleText: "2.3M subscribers"},
            subscriberCountText: %{simpleText: "@" <> name}
          },
          attrs
        )
    }
  end

  # A live or upcoming video has no `lengthText`.
  def youtube_video_hit(name, attrs \\ %{}) do
    %{
      videoRenderer:
        Map.merge(
          %{
            videoId: String.pad_trailing(name, 11, "x"),
            title: %{runs: [%{text: "Video " <> name}]},
            lengthText: %{simpleText: "15:37"},
            publishedTimeText: %{simpleText: "17 hours ago"},
            ownerText: %{
              runs: [
                %{
                  text: "Good Channel",
                  navigationEndpoint: %{
                    browseEndpoint: %{
                      browseId: "UCabcdefghijklmnopqrstuv",
                      canonicalBaseUrl: "/@good"
                    }
                  }
                }
              ]
            },
            thumbnail: %{
              thumbnails: [
                %{url: "https://i.ytimg.com/vi/#{name}/hq720.jpg?a=1", width: 360, height: 202},
                %{url: "https://i.ytimg.com/vi/#{name}/hq720.jpg?a=2", width: 720, height: 404}
              ]
            }
          },
          attrs
        )
    }
  end
end
