defmodule Sikio.FeedFixtures do
  @moduledoc false

  @doc "The resolver the test environment pins every host to, so no test reaches real DNS."
  def resolve(_host), do: {:ok, [{93, 184, 216, 34}]}

  def podcast(title \\ "Small Hours") do
    """
    <?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
    <channel><title>#{title}</title><description>A thoughtful podcast</description>
    <itunes:image href="https://img.example.org/show.jpg" />
    <item><guid>episode-1</guid><title>One &amp; two</title><pubDate>Fri, 18 Sep 2026 09:00:00 GMT</pubDate>
    <itunes:image href="https://img.example.org/1.jpg" />
    <itunes:duration>01:02:03</itunes:duration>
    <description>Plain summary</description>
    <content:encoded><![CDATA[<p>Notes with a <a href="https://example.org">link</a>.</p><script>alert(1)</script>]]></content:encoded>
    <enclosure url="https://audio.example.org/1.mp3" type="audio/mpeg" length="12" /></item></channel></rss>
    """
  end

  @doc "The same show, published by somebody who names no artwork, runtime or notes."
  def thin_podcast do
    podcast()
    |> String.replace(~r|<itunes:image href="https://img.example.org/1.jpg" />|, "")
    |> String.replace(~r|<itunes:duration>[^<]*</itunes:duration>|, "")
    |> String.replace(~r|<description>Plain summary</description>|, "")
    |> String.replace(~r|<content:encoded>.*?</content:encoded>|s, "")
  end

  @doc "The same show, stating a runtime of the caller's choosing."
  def podcast_lasting(duration) do
    String.replace(
      podcast(),
      "<itunes:duration>01:02:03</itunes:duration>",
      "<itunes:duration>#{duration}</itunes:duration>"
    )
  end

  def youtube do
    """
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/">
      <title>Good Channel</title><yt:channelId>UCabcdefghijklmnopqrstuv</yt:channelId>
      <entry><id>yt:video:abcdefghijk</id><yt:videoId>abcdefghijk</yt:videoId><title>A good video</title>
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
