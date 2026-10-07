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

  @doc "Test resolver. Maps every host to one address, so no test reaches DNS."
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
end
