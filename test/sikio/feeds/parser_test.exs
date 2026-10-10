# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.ParserTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser

  test "extracts RSS podcast episodes and decodes text entities" do
    assert {:ok, feed} = Parser.parse(podcast(), "https://example.org/rss")
    assert feed.title == "Small Hours"
    assert feed.kind == :podcast

    assert [
             %{
               external_id: "episode-1",
               title: "One & two",
               media_url: "https://audio.example.org/1.mp3"
             }
           ] = feed.entries
  end

  test "extracts YouTube Atom entries" do
    assert {:ok, feed} =
             Parser.parse(
               youtube(),
               "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
             )

    assert feed.kind == :youtube
    assert [%{video_id: "abcdefghijk", external_id: "yt:video:abcdefghijk"}] = feed.entries
  end

  test "accepts YouTube's feed-level channel ID without its UC prefix" do
    body = String.replace(youtube(), ">UCabcdefghijklmnopqrstuv<", ">abcdefghijklmnopqrstuv<")

    assert {:ok, %{kind: :youtube}} =
             Parser.parse(
               body,
               "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
             )
  end

  test "long GUIDs remain distinct rather than being truncated like titles" do
    prefix = String.duplicate("a", 600)
    first = String.replace(podcast(), "episode-1", prefix <> "-first")
    second = String.replace(podcast(), "episode-1", prefix <> "-second")
    {:ok, a} = Parser.parse(first, "https://example.org/rss")
    {:ok, b} = Parser.parse(second, "https://example.org/rss")
    refute hd(a.entries).external_id == hd(b.entries).external_id
  end

  test "malformed text bytes are rejected without crashing the importer" do
    assert {:error, :invalid_feed} = Parser.parse(<<255, 254, 0>>, "https://example.org/rss")
  end

  test "refuses general blogs, malformed XML and document type declarations" do
    for body <- [
          "<html>hello</html>",
          "<rss><channel>",
          "<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss><channel><title>&x;</title></channel></rss>",
          "<rss><channel><title>A blog</title><item><title>Post</title></item></channel></rss>"
        ] do
      assert {:error, :invalid_feed} = Parser.parse(body, "https://example.org/rss")
    end
  end

  test "keeps an empty podcast feed when it declares a podcast namespace" do
    assert {:ok, %{entries: [], kind: :podcast}} =
             Parser.parse(
               ~s(<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>New show</title></channel></rss>),
               "https://example.org/rss"
             )
  end

  # `page_url` is the feed's website. The library links to it.
  test "keeps the website each kind of source names" do
    assert {:ok, %{page_url: site}} = Parser.parse(podcast(), "https://example.org/rss")
    assert site == podcast_site()

    assert {:ok, %{page_url: site}} = Parser.parse(peertube(), peertube_feed_url())
    assert site == "https://video.example.org/c/9f1b2c3d-0000-4444-8888-aaaabbbbcccc/videos"

    # The YouTube URL is built from the validated channel id.
    assert {:ok, %{page_url: site}} = Parser.parse(youtube(), youtube_feed_url())
    assert site == "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv"
  end

  # `<ttl>` is the cache lifetime in minutes. Only a positive integer is accepted.
  test "reads how long a channel says it may be cached" do
    with_ttl = &String.replace(podcast(), "</channel>", "<ttl>#{&1}</ttl></channel>")

    assert {:ok, %{ttl: 90}} = Parser.parse(with_ttl.("90"), "https://example.org/rss")
    assert {:ok, %{ttl: nil}} = Parser.parse(with_ttl.("soon"), "https://example.org/rss")
    assert {:ok, %{ttl: nil}} = Parser.parse(with_ttl.("-5"), "https://example.org/rss")
    assert {:ok, %{ttl: nil}} = Parser.parse(podcast(), "https://example.org/rss")
    assert {:ok, %{ttl: nil}} = Parser.parse(youtube(), youtube_feed_url())
  end

  test "names no website the channel does not give, or gives as something else" do
    without = String.replace(podcast(), "<link>#{podcast_site()}</link>", "")
    assert {:ok, %{page_url: nil}} = Parser.parse(without, "https://example.org/rss")

    script = String.replace(podcast(), podcast_site(), "javascript:alert(1)")
    assert {:ok, %{page_url: nil}} = Parser.parse(script, "https://example.org/rss")
  end

  test "keeps the artwork, runtime and notes a podcast item publishes" do
    assert {:ok, feed} = Parser.parse(podcast(), "https://example.org/rss")
    assert feed.icon_url == "https://img.example.org/show.jpg"

    assert [entry] = feed.entries
    assert entry.image_url == "https://img.example.org/1.jpg"
    assert entry.duration == 3723
    assert entry.description =~ "<a href=\"https://example.org\">link</a>"
    assert entry.excerpt == "Notes with a link."
  end

  test "keeps the thumbnail and description a YouTube entry publishes" do
    assert {:ok, feed} =
             Parser.parse(
               youtube(),
               "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
             )

    assert [entry] = feed.entries
    assert entry.image_url == "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"
    assert entry.description == "What the video is about."
    assert entry.description_format == :text
    assert entry.excerpt == "What the video is about."
    assert entry.duration == nil
  end

  test "a plain seconds runtime is read as well as a stamped one" do
    assert {:ok, %{entries: [entry]}} =
             Parser.parse(podcast_lasting("742"), "https://example.org/rss")

    assert entry.duration == 742
  end

  test "an item without artwork, runtime or notes yields nothing rather than empty strings" do
    assert {:ok, %{entries: [entry]}} =
             Parser.parse(thin_podcast(), "https://example.org/rss")

    assert entry.image_url == nil
    assert entry.duration == nil
    assert entry.description == nil
    assert entry.excerpt == nil
  end

  test "notes fall back to the plain description when no rich content is sent" do
    body = String.replace(podcast(), ~r|<content:encoded>.*?</content:encoded>|s, "")
    assert {:ok, %{entries: [entry]}} = Parser.parse(body, "https://example.org/rss")
    assert entry.description == "Plain summary"
  end

  # The duration is untrusted input stored in a four-byte integer column. An oversized value
  # used to raise in the importer and fail the whole feed.
  test "a runtime the column cannot hold is refused rather than stored" do
    for value <- ["9999999999", "-30", "12:", "one", "1:2:3:4"] do
      assert {:ok, %{entries: [entry]}} =
               Parser.parse(podcast_lasting(value), "https://example.org/rss")

      assert entry.duration == nil, "#{value} was accepted as #{inspect(entry.duration)}"
    end
  end

  test "artwork named relative to the feed resolves against it" do
    for {href, expected} <- [
          {"art/1.jpg", "https://example.org/feeds/art/1.jpg"},
          {"/art/1.jpg", "https://example.org/art/1.jpg"},
          {"//img.example.org/1.jpg", "https://img.example.org/1.jpg"}
        ] do
      body =
        String.replace(podcast(), ~s|href="https://img.example.org/1.jpg"|, ~s|href="#{href}"|)

      assert {:ok, %{entries: [entry]}} =
               Parser.parse(body, "https://example.org/feeds/rss.xml")

      assert entry.image_url == expected, "#{href} became #{inspect(entry.image_url)}"
    end
  end

  # YouTube descriptions are plain text, podcast notes are HTML. The description is stored
  # unchanged, and `description_format` records which format it is.
  test "a plain text description is stored as written and labelled as text" do
    body =
      String.replace(
        youtube(),
        "What the video is about.",
        "Chapters:\n00:00 One &lt;not a tag&gt; and 5 &lt; 6\n01:00 Two"
      )

    assert {:ok, %{entries: [entry]}} =
             Parser.parse(
               body,
               "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
             )

    assert entry.description_format == :text
    assert entry.description =~ "<not a tag>"
    assert entry.description =~ "\n01:00 Two"
    assert entry.excerpt =~ "<not a tag>"
  end

  test "markup a podcast publishes is stored as written and labelled as markup" do
    assert {:ok, %{entries: [entry]}} = Parser.parse(podcast(), "https://example.org/rss")

    assert entry.description_format == :html
    assert entry.description =~ ~s(<a href="https://example.org">link</a>)
  end

  # `itunes:summary` is plain text by specification. A summary containing `5 < 6` must not be
  # parsed as HTML.
  test "a summary is text even though the description beside it is markup" do
    body =
      podcast()
      |> String.replace(~r|<content:encoded>.*?</content:encoded>|s, "")
      |> String.replace(
        "<description>Plain summary</description>",
        "<itunes:summary>5 &lt; 6 and counting</itunes:summary>"
      )

    assert {:ok, %{entries: [entry]}} = Parser.parse(body, "https://example.org/rss")

    assert entry.description_format == :text
    assert entry.description == "5 < 6 and counting"
    assert entry.excerpt == "5 < 6 and counting"
  end

  # PeerTube feeds declare the podcast namespace, which marks an empty podcast feed.
  # Without separate detection, a PeerTube feed would parse as a podcast with no episodes,
  # because video enclosures are rejected.
  test "a PeerTube feed is not mistaken for a podcast that has published nothing" do
    assert {:ok, feed} = Parser.parse(peertube(), "https://video.example.org/feeds/videos.xml")

    assert feed.kind == :peertube
    refute feed.entries == []
  end

  test "reads what a PeerTube item publishes" do
    assert {:ok, feed} = Parser.parse(peertube(), "https://video.example.org/feeds/videos.xml")

    assert feed.title == "Good Instance Videos"
    assert feed.icon_url == "https://video.example.org/lazy-static/avatars/channel.jpg"

    assert [entry] = feed.entries
    assert entry.external_id == "https://video.example.org/w/mSh0rtUu1d"
    assert entry.title == "A talk worth an hour"
    assert entry.embed_url == "https://video.example.org/videos/embed/mSh0rtUu1d"
    assert entry.image_url == "https://video.example.org/lazy-static/thumbnails/8b1f64dd.jpg"
    assert entry.duration == 3600
    assert entry.description_format == :html
    assert entry.description =~ ~s(<a href="https://video.example.org/s">here</a>)
  end

  # The feed's video renditions are HLS fragments, which browsers cannot play as files. The
  # player asks the instance's API for the playlist. The audio-only file plays as it is.
  test "a PeerTube item keeps its audio-only file and leaves the video to the API" do
    {:ok, %{entries: [entry]}} = Parser.parse(peertube(), peertube_feed_url())

    assert entry.media_url == nil
    assert entry.audio_url == "https://video.example.org/static/a.mp4"
  end

  # A file URL is untrusted and becomes a media element's source, so it passes the URL check.
  test "a PeerTube audio file outside the web is ignored" do
    body =
      String.replace(peertube(), "https://video.example.org/static/a.mp4", "javascript:alert(1)")

    {:ok, %{entries: [entry]}} = Parser.parse(body, peertube_feed_url())

    assert entry.audio_url == nil
  end

  # An empty PeerTube feed is detected by its `<generator>` element.
  test "an empty PeerTube feed is recognised by what generated it" do
    body = String.replace(peertube(), ~r|<item>.*</item>|s, "")

    assert {:ok, %{kind: :peertube, entries: []}} =
             Parser.parse(body, "https://video.example.org/feeds/videos.xml")
  end

  # A missing href would resolve to the feed URL, because merging an empty reference returns
  # the base. An item without an embed is not playable and is rejected. Otherwise the player
  # dock would frame the feed XML.
  test "an item without an embed is refused rather than pointed at the feed" do
    body = String.replace(peertube(), ~r|<media:embed[^>]*/>|, "")

    assert {:ok, %{kind: :peertube, entries: []}} =
             Parser.parse(body, "https://video.example.org/feeds/videos.xml")
  end

  # Each feed kind marks an item's page differently. The detail view links to it.
  test "every kind keeps the page its item names" do
    {:ok, %{entries: [podcast]}} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, %{entries: [peertube]}} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, %{entries: [youtube]}} = Parser.parse(youtube(), youtube_feed_url())

    assert podcast.page_url == podcast_page()
    assert peertube.page_url == "https://video.example.org/w/mSh0rtUu1d"
    assert youtube.page_url == "https://www.youtube.com/watch?v=abcdefghijk"
  end

  # The page URL is untrusted and rendered as a link, so it gets the same check as artwork URLs.
  test "a page is resolved against the feed and must be the web's" do
    page = fn link ->
      body = String.replace(podcast(), podcast_page(), link)
      {:ok, %{entries: [entry]}} = Parser.parse(body, "https://example.org/feeds/rss")
      entry.page_url
    end

    assert page.("/episodes/2") == "https://example.org/episodes/2"
    assert page.("javascript:alert(1)") == nil
    assert page.("") == nil
  end

  # An Atom entry may have several links. Only `rel="alternate"` is the video page.
  test "a YouTube entry's page is its alternate link and nothing else" do
    body =
      String.replace(
        youtube(),
        ~s|<link rel="alternate" href="https://www.youtube.com/watch?v=abcdefghijk"/>|,
        ~s|<link rel="self" href="https://www.youtube.com/feeds/x"/>|
      )

    {:ok, %{entries: [entry]}} = Parser.parse(body, youtube_feed_url())
    assert entry.page_url == nil
  end

  # Podlove Simple Chapters are embedded in the item, with a normal play time start and a title.
  test "reads the chapters a podcast lists in its item" do
    chapters = """
    <psc:chapters version="1.2" xmlns:psc="http://podlove.org/simple-chapters">
      <psc:chapter start="00:00:00.000" title="Intro" />
      <psc:chapter start="00:01:58.500" title="Akkus &amp; Laderegler" href="https://example.org/a" />
      <psc:chapter start="4:51" title="Solar" />
    </psc:chapters>
    """

    body = String.replace(podcast(), "<itunes:duration>", chapters <> "<itunes:duration>")
    {:ok, %{entries: [entry]}} = Parser.parse(body, "https://example.org/rss")

    assert entry.chapters == [
             %{"at" => 0, "title" => "Intro"},
             %{"at" => 118, "title" => "Akkus & Laderegler"},
             %{"at" => 291, "title" => "Solar"}
           ]

    assert entry.chapters_url == nil
  end

  # The start is untrusted input. An out-of-range start, such as `1e308:00`, is skipped.
  test "a chapter start no episode could reach is skipped without breaking the feed" do
    chapters = """
    <psc:chapters><psc:chapter start="1e308:00" title="Kaputt" />
    <psc:chapter start="0" title="A" /><psc:chapter start="200:00:00" title="Zu weit" />
    <psc:chapter start="60" title="B" /></psc:chapters>
    """

    body = String.replace(podcast(), "<itunes:duration>", chapters <> "<itunes:duration>")
    assert {:ok, %{entries: [entry]}} = Parser.parse(body, "https://example.org/rss")
    assert Enum.map(entry.chapters, & &1["title"]) == ["A", "B"]
  end

  # Chapters are sorted by start time, regardless of feed order.
  test "listed chapters are put in time order" do
    chapters =
      ~s|<psc:chapters><psc:chapter start="00:10:00" title="Später" /><psc:chapter start="0" title="Anfang" /></psc:chapters>|

    body = String.replace(podcast(), "<itunes:duration>", chapters <> "<itunes:duration>")
    {:ok, %{entries: [entry]}} = Parser.parse(body, "https://example.org/rss")
    assert Enum.map(entry.chapters, & &1["title"]) == ["Anfang", "Später"]
  end

  # Fewer than two valid chapters count as none, so a linked chapters file is used instead.
  test "an unusable chapter list leaves room for a linked file" do
    extra =
      ~s|<psc:chapters><psc:chapter start="0" title="Einzig" /><psc:chapter start="x" title="Kaputt" /></psc:chapters>| <>
        ~s|<podcast:chapters url="/c.json" type="application/json+chapters"/>|

    body = String.replace(podcast(), "<itunes:duration>", extra <> "<itunes:duration>")
    {:ok, %{entries: [entry]}} = Parser.parse(body, "https://example.org/rss")
    assert entry.chapters == nil
    assert entry.chapters_url == "https://example.org/c.json"
  end

  # Podcasting 2.0 links a JSON chapters file, and the parser stores only its URL.
  # Podigee uses `href` instead of `url`.
  test "keeps the address of a podcast's chapters file, spelled url or href" do
    for attribute <- ["url", "href"] do
      link =
        ~s|<podcast:chapters #{attribute}="/43/chapters.json" type="application/json+chapters"/>|

      body = String.replace(podcast(), "<itunes:duration>", link <> "<itunes:duration>")
      {:ok, %{entries: [entry]}} = Parser.parse(body, "https://example.org/rss")
      assert entry.chapters_url == "https://example.org/43/chapters.json"
      assert entry.chapters == nil
    end
  end

  test "an item naming no chapters has none" do
    {:ok, %{entries: [entry]}} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, %{entries: [video]}} = Parser.parse(youtube(), youtube_feed_url())
    assert {entry.chapters, entry.chapters_url} == {nil, nil}
    assert {video.chapters, video.chapters_url} == {nil, nil}
  end

  # One video item does not make a podcast a video feed. Parsing every item as video would drop
  # all audio episodes.
  test "a show that publishes one video is still a podcast" do
    item = """
    <item><guid>bonus</guid><title>A bonus clip</title>
    <media:embed url="https://video.example.org/videos/embed/x" />
    <enclosure url="https://video.example.org/x.mp4" type="video/mp4" /></item>
    """

    body = String.replace(podcast(), "</channel>", item <> "</channel>")

    assert {:ok, feed} = Parser.parse(body, "https://example.org/rss")
    assert feed.kind == :podcast
    assert [%{media_url: "https://audio.example.org/1.mp3"}] = feed.entries
  end
end
