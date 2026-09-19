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

  # An empty podcast is a real thing, a show that has not published yet, but an empty document with
  # a channel element is also what a blog feed looks like after its entries are rejected. The
  # namespace declaration is what tells them apart.
  defp feed({"rss", attrs, _} = root, url) do
    channel = child(root, "channel")
    entries = channel |> children("item") |> Enum.map(&podcast_entry/1) |> Enum.reject(&is_nil/1)

    if entries != [] or
         Enum.any?(attrs, fn {name, _} -> name in ["xmlns:itunes", "xmlns:podcast"] end) do
      {:ok,
       %{
         url: url,
         title: value(channel, "title"),
         kind: :podcast,
         entries: Enum.take(entries, 500)
       }}
    else
      {:error, :invalid_feed}
    end
  end

  # The channel id has to come with a YouTube host, because the id is what the application will
  # poll later and an arbitrary server may name any channel it likes.
  defp feed({"feed", _, _} = root, url) do
    channel_id = value(root, "yt:channelId")

    if Regex.match?(~r/\A(?:UC)?[\w-]{22}\z/, channel_id) and
         URI.parse(url).host in ["www.youtube.com", "youtube.com"] do
      entries = root |> children("entry") |> Enum.map(&youtube_entry/1) |> Enum.reject(&is_nil/1)

      {:ok,
       %{url: url, title: value(root, "title"), kind: :youtube, entries: Enum.take(entries, 500)}}
    else
      {:error, :invalid_feed}
    end
  end

  defp feed(_root, _url), do: {:error, :invalid_feed}

  defp podcast_entry(item) do
    enclosure = child(item, "enclosure")
    url = attr(enclosure, "url")
    type = attr(enclosure, "type")

    with true <- String.starts_with?(type, "audio/") or type == "application/ogg",
         {:ok, uri} <- HTTP.normalize(url),
         title when title != "" <- value(item, "title") do
      %{
        external_id: identifier(item, URI.to_string(uri)),
        title: title,
        media_url: URI.to_string(uri),
        video_id: nil,
        published_at: date(value(item, "pubDate"))
      }
    else
      _ -> nil
    end
  end

  defp youtube_entry(item) do
    id = value(item, "yt:videoId")

    if Regex.match?(~r/\A[\w-]{11}\z/, id) do
      %{
        external_id: "yt:video:" <> id,
        title: value(item, "title"),
        media_url: nil,
        video_id: id,
        published_at: date(value(item, "published"))
      }
    end
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
