defmodule Sikio.FeedFixtures do
  @moduledoc false

  @doc "The resolver the test environment pins every host to, so no test reaches real DNS."
  def resolve(_host), do: {:ok, [{93, 184, 216, 34}]}

  def podcast(title \\ "Small Hours") do
    """
    <?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
    <channel><title>#{title}</title><description>A thoughtful podcast</description>
    <item><guid>episode-1</guid><title>One &amp; two</title><pubDate>Fri, 18 Sep 2026 09:00:00 GMT</pubDate>
    <enclosure url="https://audio.example.org/1.mp3" type="audio/mpeg" length="12" /></item></channel></rss>
    """
  end

  def youtube do
    """
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015">
      <title>Good Channel</title><yt:channelId>UCabcdefghijklmnopqrstuv</yt:channelId>
      <entry><id>yt:video:abcdefghijk</id><yt:videoId>abcdefghijk</yt:videoId><title>A good video</title>
      <published>2026-09-17T12:00:00+00:00</published></entry>
    </feed>
    """
  end
end
