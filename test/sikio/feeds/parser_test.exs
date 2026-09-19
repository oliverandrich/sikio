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
end
