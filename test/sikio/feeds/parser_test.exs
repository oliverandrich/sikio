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

  # The runtime comes from a stranger's document and lands in a four byte column. A number too
  # large for it raised out of the importer and took the whole feed with it.
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

  # YouTube writes plain text where a podcast writes markup. The column carries the publisher's
  # own bytes and says which of the two it holds, so neither is read as the other.
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

  # `itunes:summary` is plain text by specification, so a summary saying `5 < 6` must not be
  # read as a document whose first tag never closes.
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

  # PeerTube declares the podcast namespace, which is what tells a show that has published
  # nothing yet from a blog. Without a mark of its own, an instance would be subscribed to as a
  # podcast with no episodes, because every video enclosure is refused as not being audio.
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

  # An instance that has published nothing still declares who generated the feed.
  test "an empty PeerTube feed is recognised by what generated it" do
    body = String.replace(peertube(), ~r|<item>.*</item>|s, "")

    assert {:ok, %{kind: :peertube, entries: []}} =
             Parser.parse(body, "https://video.example.org/feeds/videos.xml")
  end

  # An href that is not there resolves to the document that does not carry it, because merging
  # nothing against an address answers that address. An item with no embed is not playable, and
  # an entry pointing at the feed it came from would have the dock frame the XML.
  test "an item without an embed is refused rather than pointed at the feed" do
    body = String.replace(peertube(), ~r|<media:embed[^>]*/>|, "")

    assert {:ok, %{kind: :peertube, entries: []}} =
             Parser.parse(body, "https://video.example.org/feeds/videos.xml")
  end

  # One video among audio does not make a show a video channel, and reading every episode with
  # the wrong reader drops all of them.
  # Each kind names an item's own page in its own way. The page is what the detail opens.
  test "every kind keeps the page its item names" do
    {:ok, %{entries: [podcast]}} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, %{entries: [peertube]}} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, %{entries: [youtube]}} = Parser.parse(youtube(), youtube_feed_url())

    assert podcast.page_url == podcast_page()
    assert peertube.page_url == "https://video.example.org/w/mSh0rtUu1d"
    assert youtube.page_url == "https://www.youtube.com/watch?v=abcdefghijk"
  end

  # The page comes from a stranger and ends up in a link, so it passes the check artwork passes.
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

  # Atom names several links. Only the alternate one is the video's page.
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
