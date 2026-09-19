defmodule Sikio.Feeds.Discovery do
  @moduledoc """
  Resolves pasted links into previewable subscription sources.

  What somebody pastes is whatever their browser showed them: a channel page, a video, a podcast
  homepage, an Apple Podcasts link. None of those is a feed, and every path here ends at one, or at
  an error that says why. No personal API key is needed for any of it.
  """
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser

  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be www.youtu.be)
  @channel ~r/\AUC[a-zA-Z0-9_-]{22}\z/
  @video ~r/\A[a-zA-Z0-9_-]{11}\z/

  def discover(url) do
    with {:ok, uri} <- HTTP.normalize(url) do
      cond do
        uri.host in @youtube_hosts -> youtube(uri)
        uri.host in ["podcasts.apple.com", "itunes.apple.com"] -> apple_link(uri)
        true -> webpage(URI.to_string(uri))
      end
    end
  end

  def search(term) when is_binary(term) do
    term = String.trim(term)

    if String.length(term) in 2..120 do
      query =
        URI.encode_query(%{
          term: term,
          media: "podcast",
          entity: "podcast",
          country: "DE",
          limit: 20
        })

      case json("https://itunes.apple.com/search?" <> query) do
        {:ok, %{"results" => results}} when is_list(results) ->
          {:ok,
           results |> Enum.flat_map(&search_result/1) |> Enum.uniq_by(& &1.url) |> Enum.take(20)}

        _ ->
          {:error, :directory_unavailable}
      end
    else
      {:error, :invalid_search}
    end
  end

  @doc "Fetches one known feed URL and parses it, carrying its cache validators along."
  def fetch(url, headers \\ []) do
    with {:ok, %{status: 200} = response} <- HTTP.get(url, headers: headers),
         {:ok, feed} <- Parser.parse(response.body, response.url) do
      {:ok, Map.merge(feed, validators(response))}
    else
      {:ok, %{status: 304}} -> :not_modified
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  def validators(response) do
    %{
      etag: first_header(response, "etag"),
      last_modified: first_header(response, "last-modified")
    }
  end

  defp first_header(response, name), do: response.headers |> Map.get(name, []) |> List.first()

  defp youtube(uri) do
    parts = String.split(uri.path || "", "/", trim: true)

    case parts do
      ["feeds", "videos.xml"] ->
        channel_feed(URI.decode_query(uri.query || "")["channel_id"])

      ["channel", id | _] ->
        channel_feed(id)

      [handle | _] when binary_part(handle, 0, 1) == "@" ->
        channel_page("https://www.youtube.com/" <> handle)

      [prefix, name | _] when prefix in ["c", "user"] ->
        channel_page("https://www.youtube.com/#{prefix}/#{name}")

      _ ->
        video_channel(video_id(uri, parts))
    end
  end

  defp video_id(%URI{host: host}, [id]) when host in ["youtu.be", "www.youtu.be"], do: id
  defp video_id(_uri, [kind, id | _]) when kind in ["shorts", "live", "embed"], do: id
  defp video_id(uri, ["watch"]), do: URI.decode_query(uri.query || "")["v"]
  defp video_id(_, _), do: nil

  # oEmbed answers with the channel that published the video. Scraping the watch page instead would
  # subscribe somebody to whatever YouTube decided to recommend beside it that day.
  defp video_channel(id) when is_binary(id) do
    if Regex.match?(@video, id) do
      query = URI.encode_query(%{url: "https://www.youtube.com/watch?v=" <> id, format: "json"})

      with {:ok, %{"author_url" => author}} <- json("https://www.youtube.com/oembed?" <> query),
           {:ok, uri} <- HTTP.normalize(author),
           true <- uri.host in ["www.youtube.com", "youtube.com"],
           true <- String.starts_with?(uri.path || "", ["/channel/", "/@", "/user/", "/c/"]) do
        youtube(uri)
      else
        _ -> {:error, :youtube_unavailable}
      end
    else
      {:error, :not_found}
    end
  end

  defp video_channel(_), do: {:error, :not_found}

  # An Atom feed from YouTube names no artwork, so the picture comes from the channel's own page.
  # A caller that already read that page passes what it found, including nothing: a page that
  # states no picture is not a reason to load a second copy of the same channel.
  defp channel_feed(id), do: channel_feed(id, :unread)

  defp channel_feed(id, found) when is_binary(id) do
    if Regex.match?(@channel, id) do
      case fetch("https://www.youtube.com/feeds/videos.xml?channel_id=" <> id) do
        {:ok, feed} -> {:ok, [%{feed | icon_url: resolve_picture(id, found)}]}
        other -> other
      end
    else
      {:error, :not_found}
    end
  end

  defp channel_feed(_, _), do: {:error, :not_found}

  defp resolve_picture(id, :unread), do: channel_picture(id)
  defp resolve_picture(_id, found), do: found

  # Decoration, so every failure is the same failure: no picture, and the subscription proceeds.
  defp channel_picture(id) do
    url = "https://www.youtube.com/channel/" <> id

    case page(url) do
      {:ok, doc} -> picture(doc, url)
      _ -> nil
    end
  end

  defp channel_page(url) do
    with {:ok, doc} <- page(url),
         id when is_binary(id) <- channel_id(doc) do
      channel_feed(id, picture(doc, url))
    else
      _ -> {:error, :youtube_unavailable}
    end
  end

  defp page(url) do
    case HTTP.get(url) do
      {:ok, %{status: 200, body: body}} -> Floki.parse_document(body)
      _ -> :error
    end
  end

  # Two places the page states it. The value is an href in a document like any other, so it is
  # resolved against the page rather than read as though somebody had pasted it.
  defp picture(doc, page_url) do
    Floki.attribute(doc, "meta[property='og:image']", "content")
    |> Enum.concat(Floki.attribute(doc, "link[rel=image_src]", "href"))
    |> Enum.find_value(&HTTP.resolve(&1, page_url))
  end

  # Three places the id may be, in the order they are worth trusting: the page's own feed link, the
  # metadata tag, and finally the embedded data blob.
  defp channel_id(doc) do
    alternate = doc |> Floki.find("link[rel=alternate]") |> Floki.attribute("href")

    Enum.find_value(alternate, fn href ->
      uri = URI.parse(href)

      if uri.host in ["www.youtube.com", "youtube.com"] and uri.path == "/feeds/videos.xml",
        do: URI.decode_query(uri.query || "")["channel_id"]
    end) || List.first(Floki.attribute(doc, "meta[itemprop=channelId]", "content")) ||
      metadata_id(doc)
  end

  defp metadata_id(doc) do
    doc
    |> Floki.find("script")
    |> Enum.find_value(fn script ->
      with [_, encoded] <-
             Regex.run(
               ~r/(?:var\s+)?ytInitialData\s*=\s*(\{.*\});?\s*\z/s,
               Floki.text(script, js: true)
             ),
           {:ok, data} <- Jason.decode(encoded) do
        get_in(data, ["metadata", "channelMetadataRenderer", "externalId"])
      else
        _ -> nil
      end
    end)
  end

  defp webpage(url) do
    case HTTP.get(url) do
      {:ok, %{status: 200} = response} -> webpage_response(response)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  defp webpage_response(response) do
    case Parser.parse(response.body, response.url) do
      {:ok, feed} -> {:ok, [Map.merge(feed, validators(response))]}
      _ -> discover_links(response.body, response.url)
    end
  end

  # Five candidates at most, and each one is fetched. A page that advertises a hundred links is not
  # worth a hundred requests to somebody else's server.
  defp discover_links(body, base_url) do
    with {:ok, doc} <- Floki.parse_document(body) do
      urls =
        doc
        |> Floki.find("link[href], a[href]")
        |> Enum.filter(&feed_link?/1)
        |> Floki.attribute("href")
        |> Enum.map(&URI.merge(base_url, &1))
        |> Enum.map(&URI.to_string/1)
        |> Enum.uniq()
        |> Enum.take(5)

      feeds = Enum.flat_map(urls, &candidate/1)

      if feeds == [], do: {:error, :not_found}, else: {:ok, Enum.uniq_by(feeds, & &1.url)}
    end
  rescue
    _ in [ArgumentError, URI.Error] -> {:error, :not_found}
  end

  defp candidate(url) do
    case fetch(url) do
      {:ok, feed} -> [feed]
      _ -> []
    end
  end

  defp feed_link?({"link", attrs, _}) do
    attrs = Map.new(attrs)

    String.downcase(attrs["rel"] || "") == "alternate" and
      String.downcase(attrs["type"] || "") in ["application/rss+xml", "application/atom+xml"]
  end

  defp feed_link?({"a", attrs, _}) do
    path = (attrs |> Map.new() |> Map.get("href", "") |> URI.parse()).path || ""
    Regex.match?(~r/(?:\.(?:rss|xml)|\/(?:feed|rss)\/?)(?:\z)/i, path)
  end

  # Apple's own lookup, rather than the page a browser would show: the show page is a client-side
  # application, and the feed URL is not in its HTML at all.
  defp apple_link(uri) do
    with [_, id] <- Regex.run(~r/\/id(\d+)(?:\/|\z)/, uri.path || ""),
         {:ok, %{"results" => [%{"feedUrl" => url} | _]}} <-
           json("https://itunes.apple.com/lookup?id=" <> id),
         {:ok, feed} <- fetch(url) do
      {:ok, [feed]}
    else
      _ -> {:error, :not_found}
    end
  end

  defp json(url) do
    with {:ok, %{status: 200, body: body}} <- HTTP.get(url, max_bytes: 1_000_000),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp search_result(%{"feedUrl" => url, "collectionName" => title} = hit)
       when is_binary(title) do
    case HTTP.normalize(url) do
      {:ok, uri} ->
        [
          %{
            url: URI.to_string(uri),
            title: String.slice(title, 0, 512),
            author: to_string(hit["artistName"] || "")
          }
        ]

      _ ->
        []
    end
  end

  defp search_result(_), do: []
end
