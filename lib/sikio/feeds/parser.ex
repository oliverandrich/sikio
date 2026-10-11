# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Parser do
  @moduledoc """
  Parses podcast RSS, PeerTube RSS and YouTube Atom without external entity expansion.

  Feed documents are untrusted, so any DTD or entity declaration is rejected, not resolved.
  YouTube Atom must come from a YouTube host.
  Generic blog feeds are rejected, because the player cannot play them.
  """
  alias Sikio.Feeds.HTTP

  @doc """
  Returns whether a document has no DTD or entity declaration.

  The feed parser and the OPML reader both call it before parsing untrusted XML.
  A single check keeps the rule identical in both places.
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

  # PeerTube RSS also declares the podcast namespace, so the namespace cannot tell them apart.
  # The item enclosures can. An instance without items still identifies itself in `<generator>`.
  defp feed({"rss", attrs, _} = root, url) do
    channel = child(root, "channel")
    items = children(channel, "item")

    if mediathek_feed?(url),
      do: {:ok, mediathek_feed(channel, items, url)},
      else: rss_feed_of_kind(channel, items, attrs, url)
  end

  # The channel id must come from a YouTube host. The application polls that id later, and any
  # other server could name any channel.
  defp feed({"feed", _, _} = root, url) do
    channel_id = channel_id(value(root, "yt:channelId"))

    if Regex.match?(~r/\AUC[\w-]{22}\z/, channel_id) and
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
         # Built from the validated id, not from a link in the document.
         page_url: "https://www.youtube.com/channel/" <> channel_id,
         entries: Enum.take(entries, 500)
       }}
    else
      {:error, :invalid_feed}
    end
  end

  defp feed(_root, _url), do: {:error, :invalid_feed}

  defp rss_feed_of_kind(channel, items, attrs, url) do
    case rss_kind(channel, items, attrs) do
      nil -> {:error, :invalid_feed}
      kind -> {:ok, rss_feed(kind, channel, items, url)}
    end
  end

  @doc """
  Returns whether a title names a variant of a programme rather than the programme: audio
  description, plain language, sign language or a trailer.
  """
  def mediathek_variant?(title),
    do:
      Regex.match?(
        ~r/Audiodeskription|Hörfassung|klare Sprache|Gebärdensprache|\bTrailer\b/i,
        title
      )

  @doc """
  Returns whether a URL is a search feed of the public MediathekViewWeb instance.

  Its items look like neither podcast nor PeerTube items, so the address marks it. Another
  instance's feed is parsed under the public address; see `Sikio.Feeds.Discovery.poll/3`.
  """
  def mediathek_feed?(url) do
    match?(%URI{scheme: "https", host: "mediathekviewweb.de", path: "/feed"}, URI.parse(url))
  end

  # The title names the topic and channel as the items carry them, not the search's syntax.
  defp mediathek_feed(channel, items, url) do
    first = List.first(items)

    title =
      case {value(first, "category"), value(first, "dc:creator")} do
        {"", _} -> searched(url)
        {topic, ""} -> topic
        {topic, broadcaster} -> "#{topic} · #{broadcaster}"
      end

    %{
      url: url,
      title: String.slice(title, 0, 512),
      kind: :mediathek,
      icon_url: nil,
      page_url: nil,
      ttl: ttl(channel),
      entries: items |> Enum.map(&mediathek_entry/1) |> Enum.reject(&is_nil/1) |> one_per_page()
    }
  end

  @doc """
  Returns the channels and topics a MediathekViewWeb feed address searches, as written.

  The search reads `!channel #topic,words`, so a channel comes back as `"!WDR"`.
  """
  def mediathek_selector(url) when is_binary(url) do
    query = URI.decode_query(URI.parse(url).query || "")["query"] || ""
    query |> String.split(" ", trim: true) |> Enum.split_with(&String.starts_with?(&1, "!"))
  end

  # A series without programmes right now is named after its search.
  defp searched(url) do
    {channels, topics} = mediathek_selector(url)

    topic = topics |> Enum.map_join(" ", &String.replace(String.trim_leading(&1, "#"), ",", " "))
    channel = channels |> Enum.map_join(" ", &String.trim_leading(&1, "!"))

    [topic, channel] |> Enum.reject(&(&1 == "")) |> Enum.join(" · ")
  end

  @doc """
  Returns the id a Mediathek programme is stored under: its broadcaster's page and its title.

  MediathekViewWeb's own id can change between fetches. It serves only without a page.
  A page can hold several programmes, so the title tells them apart.
  """
  def mediathek_id(page_url, title, _id) when is_binary(page_url), do: page_url <> " " <> title
  def mediathek_id(nil, _title, id), do: id

  @doc """
  Keeps one copy of each programme, in the given order. A copy is the same title on one page.

  MediathekViewWeb lists a copy blocked outside Germany, Austria or Switzerland beside the open
  one. The open copy takes the first copy's place.
  """
  def one_per_page(programmes) do
    keyed = Enum.with_index(programmes, &{mediathek_id(&1.page_url, &1.title, &2), &1})

    open =
      keyed
      |> Enum.reverse()
      |> Enum.reject(fn {_key, programme} -> geo_blocked?(programme.media_url) end)
      |> Map.new()

    keyed
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {key, first} -> Map.get(open, key, first) end)
  end

  # The ARD marks blocked files with /geo/, ZDF and 3sat with /de/, ORF with cms-austria.
  defp geo_blocked?(url) when is_binary(url), do: Regex.match?(~r{/geo/|/de/|cms-austria}, url)
  defp geo_blocked?(_url), do: false

  # The content security policy admits media from HTTPS only.
  defp mediathek_entry(item) do
    with title when title != "" <- value(item, "title"),
         false <- mediathek_variant?(title),
         {:ok, %URI{scheme: "https"} = uri} <-
           HTTP.normalize(attr(child(item, "enclosure"), "url")),
         id when id != "" <- value(item, "guid") do
      page = HTTP.resolve(value(item, "websiteUrl"), "https://mediathekviewweb.de")

      %{
        external_id: mediathek_id(page, title, id),
        title: title,
        media_url: URI.to_string(uri),
        audio_url: nil,
        video_id: nil,
        embed_url: nil,
        page_url: page,
        chapters: nil,
        chapters_url: nil,
        published_at: date(value(item, "pubDate")),
        image_url: nil,
        duration: duration(value(item, "duration")),
        description: blank_to_nil(value(item, "description")),
        description_format: :text,
        excerpt: nil
      }
    else
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  # The feed's `yt:channelId` may omit the `UC` prefix that entries and channel URLs carry.
  defp channel_id(id) when byte_size(id) == 22, do: "UC" <> id
  defp channel_id(id), do: id

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

  # The channel's `<ttl>` in minutes. Anything but a positive integer is ignored.
  defp ttl(channel) do
    case Integer.parse(value(channel, "ttl")) do
      {minutes, ""} when minutes > 0 -> minutes
      _ -> nil
    end
  end

  # `<generator>` decides first, because it describes the whole document. Otherwise the item
  # enclosures decide, and audio wins. A podcast with one video episode stays a podcast. Parsed
  # as PeerTube, its audio episodes would be dropped.
  #
  # A podcast without items is valid, for a show that has not published yet. A blog feed whose
  # items were all rejected looks the same, so only the iTunes or podcast namespace accepts it.
  defp rss_kind(channel, items, attrs) do
    cond do
      String.starts_with?(value(channel, "generator"), "PeerTube") -> :peertube
      Enum.any?(items, &podcast_item?/1) -> :podcast
      Enum.any?(items, &peertube_item?/1) -> :peertube
      Enum.any?(attrs, fn {name, _} -> name in ["xmlns:itunes", "xmlns:podcast"] end) -> :podcast
      true -> nil
    end
  end

  # A PeerTube item has a `media:embed` and a video enclosure. A podcast item has neither.
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
        audio_url: nil,
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

  # The feed's video renditions are HLS fragments, which browsers cannot play as files. The
  # instance's API names the playlist each time the entry plays; see `Sikio.Feeds.media/1`.
  # The audio-only file plays as it is. The embed URL names the video for the API. It comes from
  # the feed, because a PeerTube release may change the URL format.
  defp peertube_entry(item, feed_url) do
    embed = HTTP.resolve(attr(child(item, "media:embed"), "url"), feed_url)
    group = child(item, "media:group")
    {notes, format} = notes(item, "content:encoded": :html, description: :html)
    audio = group |> children("media:content") |> Enum.find(&(attr(&1, "height") == "0"))

    with true <- embed != nil,
         title when title != "" <- value(item, "title") do
      %{
        external_id: identifier(item, embed),
        title: title,
        media_url: nil,
        audio_url: HTTP.resolve(attr(audio, "url"), feed_url),
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

  # All renditions carry the same duration, so the first non-empty one is used.
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
        audio_url: nil,
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

  # The item's or channel's page from `<link>`. It is not truncated like a title, because a
  # truncated URL points elsewhere. It is untrusted, so it passes the same check as artwork.
  defp rss_page(item, feed_url),
    do: item |> child("link") |> text() |> String.trim() |> HTTP.resolve(feed_url)

  # Atom lists several links. The `alternate` link is the video page.
  defp youtube_page(item, feed_url) do
    item
    |> children("link")
    |> Enum.find_value(fn link -> attr(link, "rel") == "alternate" && attr(link, "href") end)
    |> HTTP.resolve(feed_url)
  end

  # Upper bound for runtimes and chapter starts: one week. See duration/1.
  @longest_runtime 7 * 24 * 60 * 60

  # Podlove Simple Chapters: a start in Normal Play Time and a title, inside the item. They use
  # string keys, as the database returns them, so stored and fresh chapters have one shape.
  # Fewer than two valid chapters return nil, so a linked chapters file can be used instead.
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

  # Normal Play Time: SS, MM:SS or HH:MM:SS, with an optional fraction. Each untrusted part is
  # bounded before multiplication. A start beyond one week returns nil, as a runtime does.
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

  # Podcasting 2.0 links a JSON chapters file, fetched on demand by `Sikio.Feeds.chapters/1`.
  # The specification uses `url`. Podigee writes `href`.
  defp chapters_url(item, feed_url) do
    link = child(item, "podcast:chapters")
    HTTP.resolve(nonempty(attr(link, "url"), attr(link, "href")), feed_url)
  end

  # Publishers put artwork in one of three elements. The URL is untrusted, so it passes the same
  # check as a media URL.
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

  # `itunes:duration` is SS, MM:SS or HH:MM:SS. The value is untrusted and the column is a
  # 4-byte integer. Values outside one second to one week return nil instead of raising.

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

  # The first non-empty element wins, so HTML notes take precedence over plain text.
  # Each element name carries the format its specification defines. The format is never guessed.
  # Notes are not truncated like a title, but capped at 20,000 characters as untrusted input.
  defp notes(node, names) do
    Enum.find_value(names, {nil, nil}, fn {name, format} ->
      case node |> child(to_string(name)) |> text() |> String.trim() do
        "" -> nil
        value -> {String.slice(value, 0, 20_000), format}
      end
    end)
  end

  # The excerpt shown under a title in lists. Tags are stripped, so the excerpt is plain text.
  # Text nodes are joined with a space, so adjacent paragraphs do not merge into one word.
  # That separator also lands before punctuation after a link, so such spaces are removed.
  # Plain text skips the HTML parser.
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

  defp identifier(item, fallback),
    do: item |> child("guid") |> text() |> String.trim() |> nonempty(fallback) |> external_id()

  @doc """
  Returns the external id an entry with this guid is stored under.

  The id matches an episode across polls, so it is not truncated like a title. A guid over
  2,000 bytes is hashed with SHA-256, since long identifiers often differ at the end.
  """
  def external_id(guid) do
    guid = String.trim(guid)

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
