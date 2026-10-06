# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Parser do
  @moduledoc """
  Reads podcast RSS and YouTube Atom without external entity expansion.

  The document arrives from a stranger, so a declared entity is refused outright rather than
  resolved. Only two shapes are accepted: a podcast feed with audio enclosures, and a YouTube
  channel feed served by YouTube. A general blog feed is not something this application can play.
  """
  alias Sikio.Feeds.HTTP

  @doc """
  Whether a document declares no DTD or entity.

  Asked before any XML from a stranger is parsed, here and by the OPML reader, so that tightening
  the rule tightens it everywhere.
  """
  def entity_free?(body) when is_binary(body),
    do: not Regex.match?(~r/<!\s*(DOCTYPE|ENTITY)/i, body)

  def parse(body, url) when is_binary(body) do
    with true <- entity_free?(body),
         {:ok, root} <- Saxy.SimpleForm.parse_string(body),
         {:ok, feed} <- feed(root, url),
         true <- feed.title != "" do
      {:ok, feed}
    else
      _ -> {:error, :invalid_feed}
    end
  end

  # Two different things arrive as RSS. PeerTube declares the podcast namespace as well, so the
  # namespace cannot tell them apart; what an item offers to play can, and an instance that has
  # published nothing still says what generated its feed.
  defp feed({"rss", attrs, _} = root, url) do
    channel = child(root, "channel")
    items = children(channel, "item")

    case rss_kind(channel, items, attrs) do
      nil -> {:error, :invalid_feed}
      kind -> {:ok, rss_feed(kind, channel, items, url)}
    end
  end

  # The channel id has to come with a YouTube host, because the id is what the application will
  # poll later and an arbitrary server may name any channel it likes.
  defp feed({"feed", _, _} = root, url) do
    channel_id = value(root, "yt:channelId")

    if Regex.match?(~r/\A(?:UC)?[\w-]{22}\z/, channel_id) and
         URI.parse(url).host in ["www.youtube.com", "youtube.com"] do
      entries =
        root
        |> children("entry")
        |> Enum.map(&youtube_entry(&1, url))
        |> Enum.reject(&is_nil/1)

      {:ok,
       %{
         url: url,
         title: value(root, "title"),
         kind: :youtube,
         icon_url: nil,
         ttl: nil,
         # Built from the id checked above rather than read from a stranger's link.
         page_url: "https://www.youtube.com/channel/" <> channel_id,
         entries: Enum.take(entries, 500)
       }}
    else
      {:error, :invalid_feed}
    end
  end

  defp feed(_root, _url), do: {:error, :invalid_feed}

  defp rss_feed(kind, channel, items, url) do
    reader = if kind == :peertube, do: &peertube_entry/2, else: &podcast_entry/2
    entries = items |> Enum.map(&reader.(&1, url)) |> Enum.reject(&is_nil/1)

    %{
      url: url,
      title: value(channel, "title"),
      kind: kind,
      icon_url: image_url(channel, url),
      page_url: rss_page(channel, url),
      ttl: ttl(channel),
      entries: Enum.take(entries, 500)
    }
  end

  # How many minutes the channel says it may be cached. Anything but a whole number says nothing.
  defp ttl(channel) do
    case Integer.parse(value(channel, "ttl")) do
      {minutes, ""} when minutes > 0 -> minutes
      _ -> nil
    end
  end

  # What generated the document decides, because it is the one statement about the whole of it.
  # Only when it says nothing does the shape of the items answer, and audio wins there: a show
  # that publishes one video is still a show, and reading its episodes as videos drops them all.
  #
  # An empty podcast is a real thing, a show that has not published yet, but an empty document
  # with a channel element is also what a blog feed looks like after its entries are rejected.
  defp rss_kind(channel, items, attrs) do
    cond do
      String.starts_with?(value(channel, "generator"), "PeerTube") -> :peertube
      Enum.any?(items, &podcast_item?/1) -> :podcast
      Enum.any?(items, &peertube_item?/1) -> :peertube
      Enum.any?(attrs, fn {name, _} -> name in ["xmlns:itunes", "xmlns:podcast"] end) -> :podcast
      true -> nil
    end
  end

  # An embed to play and a video to download. A podcast has neither.
  defp peertube_item?(item) do
    attr(child(item, "media:embed"), "url") != "" and
      String.starts_with?(enclosure_type(item), "video/")
  end

  defp podcast_item?(item) do
    type = enclosure_type(item)
    String.starts_with?(type, "audio/") or type == "application/ogg"
  end

  defp enclosure_type(item), do: item |> child("enclosure") |> attr("type")

  defp podcast_entry(item, feed_url) do
    url = item |> child("enclosure") |> attr("url")

    with true <- podcast_item?(item),
         {:ok, uri} <- HTTP.normalize(url),
         title when title != "" <- value(item, "title") do
      {notes, format} =
        notes(item, "content:encoded": :html, description: :html, "itunes:summary": :text)

      %{
        external_id: identifier(item, URI.to_string(uri)),
        title: title,
        media_url: URI.to_string(uri),
        video_id: nil,
        embed_url: nil,
        page_url: rss_page(item, feed_url),
        chapters: listed_chapters(item),
        chapters_url: chapters_url(item, feed_url),
        published_at: date(value(item, "pubDate")),
        image_url: image_url(item, feed_url),
        duration: duration(value(item, "itunes:duration")),
        description: notes,
        description_format: format,
        excerpt: excerpt(notes, format)
      }
    else
      _ -> nil
    end
  end

  # The instance holds the video and its own player shows it, so nothing here names a file. The
  # embed is what the page will load, and the feed states it rather than it being built from
  # parts that a future release may spell differently.
  defp peertube_entry(item, feed_url) do
    embed = HTTP.resolve(attr(child(item, "media:embed"), "url"), feed_url)
    group = child(item, "media:group")
    {notes, format} = notes(item, "content:encoded": :html, description: :html)

    with true <- embed != nil,
         title when title != "" <- value(item, "title") do
      %{
        external_id: identifier(item, embed),
        title: title,
        media_url: nil,
        video_id: nil,
        embed_url: embed,
        page_url: rss_page(item, feed_url),
        chapters: nil,
        chapters_url: chapters_url(item, feed_url),
        published_at: date(value(item, "pubDate")),
        image_url: image_url(item, feed_url),
        duration: duration(playable_duration(group)),
        description: notes,
        description_format: format,
        excerpt: excerpt(notes, format)
      }
    else
      _ -> nil
    end
  end

  # Every rendition states the same runtime, so the first one that states anything answers.
  defp playable_duration(group) do
    group
    |> children("media:content")
    |> Enum.find_value("", fn node -> nonempty(attr(node, "duration"), nil) end)
  end

  defp youtube_entry(item, feed_url) do
    id = value(item, "yt:videoId")

    if Regex.match?(~r/\A[\w-]{11}\z/, id) do
      group = child(item, "media:group")
      {notes, format} = notes(group, "media:description": :text)

      %{
        external_id: "yt:video:" <> id,
        title: value(item, "title"),
        media_url: nil,
        video_id: id,
        embed_url: nil,
        page_url: youtube_page(item, feed_url),
        chapters: nil,
        chapters_url: nil,
        published_at: date(value(item, "published")),
        image_url: image_url(group, feed_url),
        duration: nil,
        description: notes,
        description_format: format,
        excerpt: excerpt(notes, format)
      }
    end
  end

  # An item's own page, or a channel's, where the publisher shows it. RSS names it as text, and it
  # is not cut the way a title is: a shortened address leads somewhere else. It is a stranger's
  # address bound for a link, so it passes the check artwork passes.
  defp rss_page(item, feed_url),
    do: item |> child("link") |> text() |> String.trim() |> HTTP.resolve(feed_url)

  # Atom names several links. The alternate one is the video's page.
  defp youtube_page(item, feed_url) do
    item
    |> children("link")
    |> Enum.find_value(fn link -> attr(link, "rel") == "alternate" && attr(link, "href") end)
    |> HTTP.resolve(feed_url)
  end

  # Neither a runtime nor a chapter's start reaches beyond a week; see duration/1.
  @longest_runtime 7 * 24 * 60 * 60

  # Podlove Simple Chapters: a start in normal play time and a title, in the item itself. Kept as
  # the database keeps them, string keys, so a chapter reads the same before storing and after.
  # Fewer than two usable chapters are no list, and leave room for a linked file instead.
  defp listed_chapters(item) do
    chapters =
      item
      |> child("psc:chapters")
      |> children("psc:chapter")
      |> Enum.map(fn chapter ->
        %{
          "at" => play_time(attr(chapter, "start")),
          "title" => String.trim(attr(chapter, "title"))
        }
      end)
      |> Enum.reject(&(is_nil(&1["at"]) or &1["title"] == ""))
      |> Enum.sort_by(& &1["at"])
      |> Enum.take(500)

    if length(chapters) >= 2, do: chapters
  end

  # Normal play time: seconds, or minutes and seconds, or hours too, perhaps with a fraction. The
  # number is a stranger's, so each part is bounded before it is multiplied, and a start beyond
  # a week is none, as a runtime is.
  defp play_time(value) do
    parts = String.split(value, ":")

    seconds =
      Enum.reduce_while(parts, 0, fn part, total ->
        case Float.parse(part) do
          {number, ""} when number >= 0 and number < 1_000_000 -> {:cont, total * 60 + number}
          _ -> {:halt, nil}
        end
      end)

    cond do
      length(parts) > 3 or is_nil(seconds) -> nil
      seconds > @longest_runtime -> nil
      true -> trunc(seconds)
    end
  end

  # Podcasting 2.0 links a JSON file of chapters, fetched once somebody opens the item. The
  # namespace says `url`; Podigee writes `href`.
  defp chapters_url(item, feed_url) do
    link = child(item, "podcast:chapters")
    HTTP.resolve(nonempty(attr(link, "url"), attr(link, "href")), feed_url)
  end

  # Artwork is named three different ways depending on who is publishing. The URL still comes from
  # a stranger, so it goes through the same check as a media URL rather than straight into a page.
  defp image_url(node, feed_url) do
    [
      attr(child(node, "itunes:image"), "href"),
      attr(child(node, "media:thumbnail"), "url"),
      node |> child("image") |> value("url")
    ]
    |> Enum.find("", &(&1 != ""))
    |> case do
      "" -> nil
      href -> HTTP.resolve(href, feed_url)
    end
  end

  # `itunes:duration` is seconds, or minutes and seconds, or hours and minutes and seconds.
  # The number is a stranger's and the column holds four bytes, so anything outside a week is
  # treated as the nonsense it is rather than raised out of the importer.

  defp duration(value) do
    parts = String.split(value, ":")

    with true <- length(parts) in 1..3 and Enum.all?(parts, &(&1 =~ ~r/\A\d+\z/)),
         seconds when seconds in 1..@longest_runtime <-
           Enum.reduce(parts, 0, &(&2 * 60 + String.to_integer(&1))) do
      seconds
    else
      _ -> nil
    end
  end

  # The first element that carries anything wins, so a show that sends both rich and plain notes
  # keeps the rich one. Each name comes with the shape that element holds by specification, and
  # the answer carries it: nothing here guesses whether a blob is markup by looking at it.
  # Not truncated the way a title is, but still bounded: this is a stranger's document and the
  # column it lands in is not a bucket.
  defp notes(node, names) do
    Enum.find_value(names, {nil, nil}, fn {name, format} ->
      case node |> child(to_string(name)) |> text() |> String.trim() do
        "" -> nil
        value -> {String.slice(value, 0, 20_000), format}
      end
    end)
  end

  # What the list under a title shows. Tags come out, so the excerpt is text and nothing else.
  # Separating the text nodes keeps two paragraphs from running into one word. Punctuation that
  # followed a link would inherit that separator, so it is pulled back against the word. Plain
  # text is already the answer and needs no parser.
  defp excerpt(nil, _format), do: nil
  defp excerpt(notes, :text), do: notes |> collapse() |> String.slice(0, 300) |> presence()

  defp excerpt(notes, _html) do
    notes
    |> Floki.parse_fragment!()
    |> Floki.text(sep: " ")
    |> collapse()
    |> String.slice(0, 300)
    |> presence()
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp collapse(text) do
    text
    |> String.slice(0, 400)
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(~r/ ([.,;:!?)\]])/u, "\\1")
    |> String.trim()
  end

  defp children({_, _, content}, name), do: Enum.filter(content, &match?({^name, _, _}, &1))
  defp children(nil, _name), do: []
  defp child(node, name), do: node |> children(name) |> List.first()

  defp value(node, name),
    do: node |> child(name) |> text() |> String.trim() |> String.slice(0, 512)

  defp text({_, _, content}), do: Enum.map_join(content, &text/1)
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
  defp attr({_, attrs, _}, name), do: attrs |> List.keyfind(name, 0, {name, ""}) |> elem(1)
  defp attr(_, _), do: ""

  # The identifier is what makes an episode the same episode on the next poll, so it is not
  # truncated the way a title is. A GUID too long for the index is hashed rather than cut, because
  # two long identifiers usually differ at the end.
  defp identifier(item, fallback) do
    guid = item |> child("guid") |> text() |> String.trim() |> nonempty(fallback)

    if byte_size(guid) > 2_000,
      do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, guid)),
      else: guid
  end

  defp nonempty("", fallback), do: fallback
  defp nonempty(value, _), do: value

  defp date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> date
      _ -> rfc_date(value)
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  defp rfc_date(value) do
    with [_, day, month, year, hour, minute, second, zone] <-
           Regex.run(
             ~r/(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) (GMT|UT|[+-]\d{4})\z/,
             value
           ),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(year),
             index + 1,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             String.to_integer(second)
           ) do
      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-zone_offset(zone), :second)
    else
      _ -> nil
    end
  end

  defp zone_offset(<<sign, hours::binary-size(2), minutes::binary-size(2)>>) do
    seconds = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
    if sign == ?-, do: -seconds, else: seconds
  end

  defp zone_offset(_), do: 0
end
