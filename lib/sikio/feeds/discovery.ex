# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Discovery do
  @moduledoc """
  Resolves pasted links into previewable subscription sources.

  Input is a URL copied from a browser: a channel page, a video, a podcast homepage or an Apple
  Podcasts link. Each path resolves to a feed or to an error with a reason. No personal API key
  is required.
  """
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser

  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be www.youtu.be)
  @channel ~r/\AUC[a-zA-Z0-9_-]{22}\z/
  @video ~r/\A[a-zA-Z0-9_-]{11}\z/

  @doc """
  Classifies one input line as `{:link, address}`, `{:search, term}` or `:empty`.

  A link contains `://`, or is one word with a dot followed by two or more letters, like a host.
  Anything else is a search term.
  """
  def intent(input) when is_binary(input) do
    input = String.trim(input)

    cond do
      input == "" -> :empty
      String.contains?(input, "://") -> {:link, input}
      Regex.match?(~r/\A[^\s\/]+\.[a-z]{2,}(?:[\/?#:]\S*)?\z/i, input) -> {:link, input}
      true -> {:search, input}
    end
  end

  def discover(url) do
    with {:ok, uri} <- HTTP.normalize(url) do
      cond do
        uri.host in @youtube_hosts -> youtube(uri)
        uri.host in ["podcasts.apple.com", "itunes.apple.com"] -> apple_link(uri)
        true -> webpage(uri)
      end
    end
  end

  @doc """
  Resolves a link to one video or episode into `%{preview: feed, external_id: id}`.

  The preview is the item's feed, and it holds the item. An item missing from its feed is built
  from what its source states. `Sikio.Library.save/4` saves only an entry such a preview holds.
  Returns `{:error, :not_an_item}` for a link to a channel, a show or another page.
  """
  def item(url) do
    with {:ok, uri} <- HTTP.normalize(url) do
      cond do
        uri.host in @youtube_hosts -> youtube_item(uri)
        uri.host in ["podcasts.apple.com", "itunes.apple.com"] -> apple_item(uri)
        peertube?(uri) -> peertube_item(uri)
        true -> page_item(uri)
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

  @doc "Fetches and parses a known feed URL. The result includes ETag and Last-Modified."
  def fetch(url, headers \\ []) do
    case poll(url, headers) do
      {:not_modified, _wait} -> :not_modified
      {result, _wait} -> result
    end
  end

  @doc """
  Fetches a feed as `fetch/2` does and also returns the server's requested wait.

  The wait is in seconds, or nil when absent. A 200 uses the longer of `max-age` and `<ttl>`.
  A 304 uses `Cache-Control: max-age`. A 429 or 503 uses `Retry-After`.
  """
  def poll(url, headers), do: url |> HTTP.get(headers: headers) |> answered()

  defp answered({:ok, %{status: 200} = response}) do
    case Parser.parse(response.body, response.url) do
      {:ok, feed} ->
        ttl = feed.ttl && feed.ttl * 60
        feed = feed |> with_shorts() |> Map.merge(validators(response))
        {{:ok, feed}, longest(max_age(response), ttl)}

      error ->
        {error, nil}
    end
  end

  defp answered({:ok, %{status: 304} = response}), do: {:not_modified, max_age(response)}

  # 404 and 410 count as permanent, not as a temporary outage.
  defp answered({:ok, %{status: status}}) when status in [404, 410], do: {{:error, :gone}, nil}

  defp answered({:ok, %{status: status} = response}) when status in [429, 503],
    do: {{:error, :unavailable}, retry_after(response)}

  defp answered({:error, reason}), do: {{:error, reason}, nil}
  defp answered(_other), do: {{:error, :unavailable}, nil}

  # A YouTube channel feed does not mark Shorts. The channel's `UUSH` Shorts playlist has its own
  # feed. A channel without Shorts has no such feed. A failed Shorts fetch marks nothing and does
  # not fail the channel poll.
  defp with_shorts(feed) do
    case Feed.channel_id(feed) do
      "UC" <> id ->
        shorts = shorts("https://www.youtube.com/feeds/videos.xml?playlist_id=UUSH" <> id)
        %{feed | entries: Enum.map(feed.entries, &Map.put(&1, :short, &1.video_id in shorts))}

      _ ->
        feed
    end
  end

  defp shorts(url) do
    case fetch(url) do
      {:ok, %{entries: entries}} -> MapSet.new(entries, & &1.video_id)
      _ -> MapSet.new()
    end
  end

  defp longest(nil, other), do: other
  defp longest(one, nil), do: one
  defp longest(one, other), do: max(one, other)

  defp max_age(response) do
    case Regex.run(~r/(?:^|[,\s])max-age=(\d+)/i, joined_header(response, "cache-control")) do
      [_, seconds] -> positive(String.to_integer(seconds))
      nil -> nil
    end
  end

  # `max-age=0` disables caching and adds no wait.
  defp positive(0), do: nil
  defp positive(seconds), do: seconds

  # Delay in seconds or an HTTP date. With repeated headers, the first value counts.
  defp retry_after(response) do
    value = response.headers |> Map.get("retry-after", [""]) |> hd() |> String.trim()

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> seconds_until(value)
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp seconds_until(date) do
    with [_, day, month, year, hour, minute, second] <-
           Regex.run(~r/\A\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/, date),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         [day, year, hour, minute, second] =
           Enum.map([day, year, hour, minute, second], &String.to_integer/1),
         {:ok, at} <- NaiveDateTime.new(year, index + 1, day, hour, minute, second) do
      at |> DateTime.from_naive!("Etc/UTC") |> DateTime.diff(DateTime.utc_now()) |> max(0)
    else
      _ -> nil
    end
  end

  defp joined_header(response, name), do: response.headers |> Map.get(name, []) |> Enum.join(",")

  def validators(response) do
    %{
      etag: first_header(response, "etag"),
      last_modified: first_header(response, "last-modified")
    }
  end

  defp first_header(response, name), do: response.headers |> Map.get(name, []) |> List.first()

  # Any host may run PeerTube, so there is no host list. NodeInfo reports the software, and only
  # that decides. Other software falls through to feed link discovery.
  #
  # This runs before link discovery for correctness. A PeerTube video page links its comment feed
  # and the instance feed. A channel page links only its Podcasting 2.0 feed. Link discovery on a
  # video page would subscribe to a comment feed.
  #
  # It runs after the URL itself was parsed as a feed. A URL that is already a feed skips the
  # NodeInfo requests.
  defp peertube(url) when is_binary(url) do
    case HTTP.normalize(url) do
      {:ok, uri} -> peertube(uri)
      _ -> nil
    end
  end

  defp peertube(%URI{} = uri) do
    if peertube?(uri) do
      case peertube_feed(uri) do
        {:ok, url} -> feed_only(url)
        _ -> {:error, :not_found}
      end
    end
  end

  defp peertube?(uri) do
    with {:ok, %{"links" => links}} <- json(origin(uri) <> "/.well-known/nodeinfo"),
         href when is_binary(href) <- nodeinfo_href(links),
         {:ok, %{host: host}} <- HTTP.normalize(href),
         true <- host == uri.host,
         {:ok, %{"software" => %{"name" => name}}} <- json(href) do
      String.downcase(name) == "peertube"
    else
      _ -> false
    end
  end

  # NodeInfo lists several schema versions. Only the 2.0 link is followed, and only on the same
  # host. A link in a third-party document may point to any host.
  defp nodeinfo_href(links) when is_list(links) do
    Enum.find_value(links, fn link ->
      with %{"rel" => rel, "href" => href} <- link,
           true <- String.ends_with?(rel, "/schema/2.0") do
        href
      else
        _ -> nil
      end
    end)
  end

  defp nodeinfo_href(_links), do: nil

  # The feed URL needs a numeric id, but a channel URL carries a name. The instance API maps the
  # name to the id.
  defp peertube_feed(uri) do
    origin = origin(uri)

    route(origin, String.split(uri.path || "", "/", trim: true))
  end

  # The URL forms a PeerTube instance serves, in short (`/w`, `/c`, `/a`) and long spelling.
  defp route(origin, path) when path in [[], ["videos"]],
    do: {:ok, origin <> "/feeds/videos.xml"}

  defp route(origin, ["videos", "watch", id | _]), do: video_channel_feed(origin, id)
  defp route(origin, ["w", id | _]), do: video_channel_feed(origin, id)

  defp route(origin, [word, name | _]) when word in ["c", "video-channels"],
    do: owner_feed(origin, "video-channels", "videoChannelId", name)

  defp route(origin, [word, name | _]) when word in ["a", "accounts"],
    do: owner_feed(origin, "accounts", "accountId", name)

  defp route(_origin, _path), do: :error

  # Channels and accounts share one API shape under different paths.
  defp owner_feed(origin, resource, param, name) do
    case json("#{origin}/api/v1/#{resource}/#{URI.encode(name)}") do
      {:ok, %{"id" => id}} when is_integer(id) ->
        {:ok, "#{origin}/feeds/videos.xml?#{param}=#{id}"}

      _ ->
        :error
    end
  end

  # A pasted video resolves to its channel's feed, as on YouTube.
  defp video_channel_feed(origin, id) do
    case json(origin <> "/api/v1/videos/" <> URI.encode(id)) do
      {:ok, %{"channel" => %{"id" => channel_id}}} when is_integer(channel_id) ->
        {:ok, origin <> "/feeds/videos.xml?videoChannelId=" <> Integer.to_string(channel_id)}

      _ ->
        :error
    end
  end

  # A watch page in short or long spelling names one video by its short or long id.
  defp peertube_item(uri) do
    case String.split(uri.path || "", "/", trim: true) do
      ["w", id | _] -> instance_video(origin(uri), id)
      ["videos", "watch", id | _] -> instance_video(origin(uri), id)
      _ -> {:error, :not_an_item}
    end
  end

  # The instance's feed names a video by its short watch address, so a video built from the API
  # gets the same id and matches the feed later.
  defp instance_video(origin, id) do
    with {:ok, %{"channel" => %{"id" => channel}, "shortUUID" => short} = video}
         when is_integer(channel) and is_binary(short) <-
           json(origin <> "/api/v1/videos/" <> URI.encode(id)),
         {:ok, feed} <- fetch("#{origin}/feeds/videos.xml?videoChannelId=#{channel}") do
      watch = origin <> "/w/" <> short

      entries =
        if Enum.any?(feed.entries, &(&1.external_id == watch)),
          do: feed.entries,
          else: [api_entry(origin, watch, video) | feed.entries]

      {:ok, %{preview: %{feed | entries: entries}, external_id: watch}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp api_entry(origin, watch, video) do
    %{
      external_id: watch,
      title: String.slice(to_string(video["name"] || watch), 0, 512),
      media_url: nil,
      video_id: nil,
      embed_url: HTTP.resolve(to_string(video["embedPath"] || ""), origin),
      page_url: watch,
      chapters: nil,
      chapters_url: nil,
      published_at: iso_date(video["publishedAt"]),
      image_url: HTTP.resolve(to_string(video["thumbnailPath"] || ""), origin),
      duration: if(is_integer(video["duration"]), do: video["duration"]),
      description: video["description"],
      description_format: :text,
      excerpt: nil,
      short: false
    }
  end

  defp iso_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> DateTime.shift_zone!(date, "Etc/UTC")
      _ -> nil
    end
  end

  defp iso_date(_value), do: nil

  defp origin(%URI{scheme: scheme, host: host}), do: "#{scheme}://#{host}"

  defp feed_only(url) do
    case fetch(url) do
      {:ok, feed} -> {:ok, [feed]}
      other -> other
    end
  end

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

  # oEmbed returns the channel that published the video. The watch page also links recommended
  # channels, so scraping it could pick the wrong one.
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

  defp youtube_item(uri) do
    parts = String.split(uri.path || "", "/", trim: true)
    id = video_id(uri, parts)

    if is_binary(id) and Regex.match?(@video, id),
      do: video_item(id, parts),
      else: {:error, :not_an_item}
  end

  # The channel comes from oEmbed, as for a subscription. A video missing from the channel's feed,
  # which lists only the newest, is built from oEmbed and dated by its watch page.
  defp video_item(id, parts) do
    page = "https://www.youtube.com/watch?v=" <> id
    query = URI.encode_query(%{url: page, format: "json"})
    external_id = "yt:video:" <> id

    with {:ok, %{"author_url" => author} = oembed} <-
           json("https://www.youtube.com/oembed?" <> query),
         {:ok, uri} <- HTTP.normalize(author),
         {:ok, [feed | _]} <- youtube(uri) do
      entries =
        if Enum.any?(feed.entries, &(&1.external_id == external_id)),
          do: feed.entries,
          else: [
            oembed_entry(%{id: id, external_id: external_id, page: page}, oembed, parts)
            | feed.entries
          ]

      {:ok, %{preview: %{feed | entries: entries}, external_id: external_id}}
    else
      _ -> {:error, :youtube_unavailable}
    end
  end

  defp oembed_entry(%{id: id, external_id: external_id, page: page}, oembed, parts) do
    %{
      external_id: external_id,
      title: String.slice(to_string(oembed["title"] || id), 0, 512),
      media_url: nil,
      video_id: id,
      embed_url: nil,
      page_url: page,
      chapters: nil,
      chapters_url: nil,
      published_at: published(page),
      image_url: HTTP.resolve(to_string(oembed["thumbnail_url"] || ""), page),
      duration: nil,
      description: nil,
      description_format: :text,
      excerpt: nil,
      short: List.first(parts) == "shorts"
    }
  end

  # Best effort: the watch page's `datePublished`. A consent page or changed markup leaves the
  # entry undated, which is better than an invented date on a shared entry.
  defp published(page_url) do
    with {:ok, doc} <- page(page_url),
         [value | _] <- Floki.attribute(doc, "meta[itemprop=datePublished]", "content") do
      iso_date(value)
    else
      _ -> nil
    end
  end

  # YouTube's Atom feed has no artwork, so the picture comes from the channel page. A caller that
  # already parsed that page passes its result, including nil. A missing picture does not cause a
  # second page fetch.
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

  # The picture is optional. Every failure returns nil and the subscription proceeds.
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

  # The page states the picture in two places. The value is an href, resolved against the page.
  defp picture(doc, page_url) do
    Floki.attribute(doc, "meta[property='og:image']", "content")
    |> Enum.concat(Floki.attribute(doc, "link[rel=image_src]", "href"))
    |> Enum.find_value(&HTTP.resolve(&1, page_url))
  end

  # Three id sources, most reliable first: feed link, metadata tag, `ytInitialData` blob.
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

  defp webpage(uri) do
    case HTTP.get(URI.to_string(uri)) do
      {:ok, %{status: 200} = response} -> webpage_response(response)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  # Three checks, cheapest first. A response that parses as a feed is used directly.
  # Otherwise NodeInfo is checked, because PeerTube names the correct feed.
  # Link discovery runs last, because it is the least reliable.
  defp webpage_response(response) do
    case Parser.parse(response.body, response.url) do
      {:ok, feed} ->
        {:ok, [feed |> with_shorts() |> Map.merge(validators(response))]}

      _ ->
        # A PeerTube instance without a feed for this URL returns its error. Link discovery on its
        # pages would find comment feeds.
        case peertube(response.url) do
          nil -> discover_links(response.body, response.url)
          answer -> answer
        end
    end
  end

  # At most five candidates are fetched, to bound requests to a third-party server. They are
  # fetched concurrently, so the latency is that of the slowest.
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

      feeds =
        urls
        |> Task.async_stream(&candidate/1, max_concurrency: 5, timeout: :infinity)
        |> Enum.flat_map(fn {:ok, found} -> found end)

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

  # An Apple episode link names its show in the path and the episode in `i`. The lookup lists the
  # show's feed and its episodes. The episode's guid is the feed entry's id.
  defp apple_item(uri) do
    with [_, show] <- Regex.run(~r/\/id(\d+)(?:\/|\z)/, uri.path || ""),
         episode when is_binary(episode) <- URI.decode_query(uri.query || "")["i"] do
      apple_episode(show, episode)
    else
      _ -> {:error, :not_an_item}
    end
  end

  defp apple_episode(show, episode) do
    query = URI.encode_query(%{id: show, entity: "podcastEpisode", limit: 200})

    with {:ok, %{"results" => results}} when is_list(results) <-
           json("https://itunes.apple.com/lookup?" <> query),
         url when is_binary(url) <- Enum.find_value(results, & &1["feedUrl"]),
         guid when is_binary(guid) <-
           Enum.find_value(results, &(to_string(&1["trackId"]) == episode && &1["episodeGuid"])),
         {:ok, feed} <- fetch(url) do
      held(feed, guid)
    else
      _ -> {:error, :not_found}
    end
  end

  # An episode page links its show's feed. The entry whose link is the page is the episode.
  # A page that is a feed, or whose feeds hold no entry for it, is not a single item.
  defp page_item(uri) do
    with {:ok, %{status: 200} = response} <- HTTP.get(URI.to_string(uri)),
         {:error, _not_a_feed} <- Parser.parse(response.body, response.url),
         {:ok, feeds} <- discover_links(response.body, response.url),
         {feed, entry} <- linked_entry(feeds, [URI.to_string(uri), response.url]) do
      {:ok, %{preview: feed, external_id: entry.external_id}}
    else
      _ -> {:error, :not_an_item}
    end
  end

  defp linked_entry(feeds, pages) do
    pages = Enum.map(pages, &same_page/1)

    Enum.find_value(feeds, fn feed ->
      entry = Enum.find(feed.entries, &(same_page(&1.page_url) in pages))
      entry && {feed, entry}
    end)
  end

  # Two addresses of one page differ at most in a fragment or a trailing slash.
  defp same_page(nil), do: nil

  defp same_page(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | fragment: nil, path: String.trim_trailing(uri.path || "", "/")})
  end

  defp held(feed, external_id) do
    if Enum.any?(feed.entries, &(&1.external_id == external_id)),
      do: {:ok, %{preview: feed, external_id: external_id}},
      else: {:error, :not_found}
  end

  # Uses Apple's lookup API. The show page renders client-side, and its HTML has no feed URL.
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
