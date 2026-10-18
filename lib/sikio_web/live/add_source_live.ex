# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddSourceLive do
  @moduledoc """
  Adds a source from a pasted link or a search in Apple Podcasts, the Mediathek, PeerTube and
  YouTube.

  A pasted link shows a preview with its title and item count first.
  Subscribing asks which present items to take and where later ones go. A search result's feed
  is fetched after the answer.
  A search also asks MediathekViewWeb. A programme from it is saved on its own, as an item.
  A search also asks a PeerTube index for channels and videos. A video is saved as its link is.
  A search also reads YouTube's results page for channels and videos, saved the same way.
  A search lists the hits of every index in one list, ordered by `Sikio.Feeds.SearchRank`. The list
  renders once every index answered, or after a deadline. A pill per kind filters it.
  Discovery runs in `start_async/3`. Candidates stay in assigns under generated ids.
  A forged id therefore selects nothing.

  A link to one video or episode also offers that item alone, saved without a subscription.
  `/add?url=…` fills in the link and starts the lookup, for bookmarklets and share sheets.

  After subscribing, the view navigates to the source's page.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents,
    only: [artwork: 1, date: 1, page_picture: 1, runtime: 1, source_name: 1, source_picture: 1]

  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.SearchRank
  alias Sikio.Library
  alias Sikio.Platforms
  alias SikioWeb.LibraryPaths
  alias SikioWeb.SubscriptionSettings

  # Each kind of hit with the assign that holds its results, in the order of the pills.
  @results [
    podcasts: :candidates,
    episodes: :episodes,
    series: :series,
    programmes: :programmes,
    channels: :channels,
    videos: :videos,
    youtube_channels: :youtube_channels,
    youtube_videos: :youtube_videos
  ]

  @kinds Enum.map(@results, fn {kind, _results} -> to_string(kind) end)

  # Each kind's row id prefix. Rows of all kinds share one list, so their ids must differ.
  @prefixes %{
    podcasts: "found-",
    episodes: "episode-",
    series: "series-",
    programmes: "programme-",
    channels: "channel-",
    videos: "video-",
    youtube_channels: "youtube-channel-",
    youtube_videos: "youtube-video-"
  }

  # The list renders once every search answered, or after this many milliseconds.
  @deadline 5_000

  # Without a filter, the list shows this many of the best hits.
  @shown 20

  # Each search besides Apple's podcast search with the assign that holds its state.
  @states %{
    episodes: :episodes_state,
    programmes: :programmes_state,
    channels: :channels_state,
    videos: :videos_state,
    youtube_channels: :youtube_channels_state,
    youtube_videos: :youtube_videos_state
  }

  # The rows that fetch their item before saving it, by the event that saves one.
  @fetched %{
    "save_episode" => :episodes,
    "save_video" => :videos,
    "save_youtube_video" => :youtube_videos
  }

  # Each list's rows subscribe to a source: the fields with its address and name, and the
  # `Discovery` function that fetches it. A capture here would be a compile-time dependency.
  @subscribable %{
    "episodes" => {:episodes, :feed_url, :podcast, :discover},
    "series" => {:series, :series_url, :title, :mediathek_series},
    "programmes" => {:programmes, :series_url, :series_title, :mediathek_series},
    "channels" => {:channels, :url, :title, :discover},
    "videos" => {:videos, :channel_url, :channel, :discover},
    "youtube_channels" => {:youtube_channels, :url, :title, :discover},
    "youtube_videos" => {:youtube_videos, :channel_url, :channel, :discover}
  }

  # Each search with the platform it asks.
  @searches [
    sources: :podcast,
    episodes: :podcast,
    programmes: :mediathek,
    channels: :peertube,
    videos: :peertube,
    youtube_channels: :youtube,
    youtube_videos: :youtube
  ]

  @existing ~w(newest all none)

  # A series taken whole is fetched once with this many programmes. Its refreshes ask for 20.
  @whole_series 100

  @lookups [
    :subscribe,
    :item,
    :programmes,
    :episodes,
    :fetched_item,
    :channels,
    :videos,
    :youtube_channels,
    :youtube_videos
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Add a source"),
       form: to_form(%{"q" => ""}),
       mode: nil,
       busy: false,
       platforms: Platforms.enabled()
     )
     |> stream_configure(:sources, dom_id: &(@prefixes.podcasts <> &1.id))
     |> stream_configure(:results, dom_id: & &1.id)
     |> without_results()}
  end

  @impl true
  # The link leaves the address once the lookup starts, so a reconnect does not repeat it.
  def handle_params(%{"url" => url}, _uri, socket) when is_binary(url) and url != "" do
    if connected?(socket),
      do: {:noreply, socket |> lookup(url) |> push_patch(to: ~p"/add", replace: true)},
      else: {:noreply, assign(socket, form: to_form(%{"q" => url}))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, _params, %{assigns: %{busy: true}} = socket)
      when event in ["add", "search_instead", "select"],
      do: {:noreply, socket}

  # Keeps the `form` assign current, so the input survives a LiveView reconnect.
  def handle_event("validate", %{"q" => q}, socket),
    do: {:noreply, assign(socket, form: to_form(%{"q" => q}))}

  # One input: a URL is discovered, any other text is searched.
  def handle_event("add", %{"q" => q}, socket), do: {:noreply, lookup(socket, q)}

  # A pill filters the list to its kind. Pressed again, it shows every kind.
  def handle_event("filter", %{"kind" => kind}, socket) when kind in @kinds do
    kind = String.to_existing_atom(kind)
    filter = if socket.assigns.filter == kind, do: nil, else: kind
    {:noreply, socket |> assign(filter: filter) |> show_rows()}
  end

  # One description shows in full at a time.
  def handle_event("more", %{"row" => row}, socket) do
    more = if socket.assigns.more == row, do: nil, else: row
    {:noreply, socket |> assign(more: more) |> show_rows()}
  end

  def handle_event("save_programme", %{"key" => key, "at" => at}, socket)
      when at in ["queue", "inbox"] do
    case socket.assigns.programmes[key] do
      nil -> {:noreply, socket}
      programme -> save_item(socket, Discovery.mediathek_item(programme), at)
    end
  end

  # An episode is saved from its podcast's feed, a video from its instance. Each is fetched first.
  def handle_event(event, %{"key" => key, "at" => at}, %{assigns: %{saving: nil}} = socket)
      when is_map_key(@fetched, event) and at in ["queue", "inbox"] do
    list = @fetched[event]

    case socket.assigns[list][key] do
      nil -> {:noreply, socket}
      found -> {:noreply, fetch_item(socket, list, key, at, found)}
    end
  end

  def handle_event(event, _params, socket) when is_map_key(@fetched, event),
    do: {:noreply, socket}

  # A pasted link's item subscribes to its source's feed, fetched afresh. The item's preview can
  # hold an older video added for the link, which the feed itself does not list.
  def handle_event("subscribe", %{"list" => "item"}, %{assigns: %{item: %{} = item}} = socket),
    do: {:noreply, ask(socket, "single-item", item.preview.title, {:discover, item.preview.url})}

  # A click from a row the page already cleared.
  def handle_event("subscribe", %{"list" => "item"}, socket), do: {:noreply, socket}

  def handle_event("subscribe", %{"list" => list, "key" => key}, socket)
      when is_map_key(@subscribable, list) do
    {name, url, title, fetch} = @subscribable[list]

    case socket.assigns[name][key] do
      %{^url => address} = row when is_binary(address) ->
        {:noreply, ask(socket, @prefixes[name] <> key, row[title], {fetch, address})}

      _forged ->
        {:noreply, socket}
    end
  end

  # The dialog's choices stay in `asking` as they change.
  def handle_event("subscribe_options", params, %{assigns: %{asking: %{} = asking}} = socket) do
    existing = if params["existing"] in @existing, do: params["existing"], else: asking.existing
    deliveries = Enum.map(SubscriptionSettings.deliveries(), &elem(&1, 0))
    delivery = if params["delivery"] in deliveries, do: params["delivery"], else: asking.delivery
    {:noreply, assign(socket, asking: %{asking | existing: existing, delivery: delivery})}
  end

  def handle_event("cancel_subscribe", _params, socket),
    do: {:noreply, assign(socket, asking: nil)}

  def handle_event("confirm_subscribe", _params, %{assigns: %{asking: %{} = asking}} = socket) do
    # The archive takes every present entry, whatever the hidden question says.
    existing =
      if asking.delivery == "skip", do: :none, else: String.to_existing_atom(asking.existing)

    opts = [existing: existing, delivery: String.to_existing_atom(asking.delivery)]
    socket = assign(socket, asking: nil)

    case asking.source do
      {:preview, preview} ->
        subscribe(socket, preview, opts)

      # The source is fetched first, so subscribing imports its current entries.
      {fetch, url} ->
        args =
          if fetch == :mediathek_series and existing == :all,
            do: [url, [size: @whole_series]],
            else: [url]

        {:noreply,
         socket
         |> assign(
           subscribing: asking.row,
           row_errors: Map.delete(socket.assigns.row_errors, asking.row)
         )
         |> show_rows()
         |> start_async(:subscribe, fn -> {opts, apply(Discovery, fetch, args)} end)}
    end
  end

  def handle_event(event, _params, socket)
      when event in ["subscribe_options", "confirm_subscribe"],
      do: {:noreply, socket}

  def handle_event("save_item", %{"at" => at}, %{assigns: %{item: %{} = item}} = socket)
      when at in ["queue", "inbox"],
      do: save_item(socket, item, at)

  def handle_event("save_item", _params, socket), do: {:noreply, socket}

  # Clears the input, the results and any pending subscribe task.
  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> cancel_lookups()
     |> assign(form: to_form(%{"q" => ""}), busy: false, mode: nil)
     |> without_results()
     |> push_event("focus", %{id: "add-q"})}
  end

  # Input such as `name.tld` failed as a URL. This searches the same text.
  def handle_event("search_instead", _params, %{assigns: %{fallback: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("search_instead", _params, socket),
    do: {:noreply, search(socket, socket.assigns.fallback)}

  def handle_event("select", %{"id" => id}, socket) do
    case socket.assigns.candidates[id] do
      nil ->
        {:noreply, socket}

      %{entries: _} = preview ->
        {:noreply, ask(socket, id, preview.title, {:preview, preview})}

      # A search result is fetched after the dialog. The list stays visible meanwhile.
      %{url: url} = result ->
        {:noreply, ask(socket, id, result.title, {:discover, url})}
    end
  end

  # Opens the subscribe dialog for one row. A running subscribe takes no second one.
  defp ask(%{assigns: %{subscribing: nil}} = socket, row, title, source),
    do:
      assign(socket,
        asking: %{row: row, title: title, source: source, existing: "newest", delivery: "inbox"}
      )

  defp ask(socket, _row, _title, _source), do: socket

  # An item whose feed is fetched before it is saved. The row shows the wait and any failure.
  # The message for a missing item is translated here, in the view's process and locale.
  defp fetch_item(socket, list, key, at, found) do
    {row, gone, fetch} = fetching(list, key, found)

    socket
    |> assign(saving: row, row_errors: Map.delete(socket.assigns.row_errors, row))
    |> show_rows()
    |> start_async(:fetched_item, fn -> {at, gone, fetch.()} end)
  end

  # A feed without the episode is final. A video's instance may only be down at the moment.
  defp fetching(:episodes, key, episode),
    do:
      {@prefixes.episodes <> key, gettext("This episode is no longer in its podcast's feed."),
       fn -> Discovery.episode_item(episode) end}

  defp fetching(:videos, key, video),
    do:
      {@prefixes.videos <> key,
       gettext("This video could not be read from its PeerTube instance. Try again later."),
       fn -> Discovery.peertube_video_item(video.url) end}

  # The video is read as its pasted link would be.
  defp fetching(:youtube_videos, key, video),
    do:
      {@prefixes.youtube_videos <> key,
       gettext("This video could not be read from YouTube. Try again later."),
       fn -> Discovery.item(video.url) end}

  defp lookup(socket, q) do
    socket = assign(socket, form: to_form(%{"q" => q}))

    case Discovery.intent(q) do
      :empty ->
        socket

      # Input without a scheme only resembles a URL. It is kept as `fallback` for a search.
      {:link, url} ->
        fallback = if String.contains?(url, "://"), do: nil, else: url
        socket |> discover(url) |> assign(fallback: fallback)

      # The searches each check the term. Without the podcast search, one would say nothing.
      {:search, term} ->
        if Discovery.search_term?(term),
          do: search(socket, term),
          else:
            socket |> searching(:search) |> assign(busy: false, error: message(:invalid_search))
    end
  end

  @impl true
  # A pasted link whose every source belongs to a platform that is off finds nothing.
  def handle_async(:sources, {:ok, {:ok, sources}}, socket) do
    case {socket.assigns.mode, Enum.filter(sources, &on?(socket, &1[:kind]))} do
      {:link, []} when sources != [] -> failed(socket, :platform_off)
      {_mode, allowed} -> found_sources(socket, allowed)
    end
  end

  def handle_async(:programmes, {:ok, {:ok, found}}, socket) do
    term = socket.assigns.term
    found = found |> Enum.map(&with_series/1) |> keyed(:key)
    series = found |> grouped() |> keyed(:key) |> scored(:series, term)

    {:noreply,
     socket
     |> assign(
       programmes: found |> scored(:programmes, term) |> by_key(),
       series: by_key(series),
       programmes_state: :done
     )
     |> answered()}
  end

  def handle_async(source, {:ok, {:ok, found}}, socket)
      when is_map_key(@states, source) do
    found = found |> keyed(:key) |> scored(source, socket.assigns.term)

    {:noreply,
     socket
     |> assign([{source, by_key(found)}, {@states[source], :done}])
     |> answered()}
  end

  # The podcast search reports an invalid term. The other searches stay silent about it.
  def handle_async(source, {:ok, {:error, :invalid_search}}, socket)
      when is_map_key(@states, source),
      do: {:noreply, socket |> assign(@states[source], nil) |> answered()}

  def handle_async(source, _failed, socket) when is_map_key(@states, source),
    do: {:noreply, socket |> assign(@states[source], :failed) |> answered()}

  def handle_async(:fetched_item, {:ok, {at, _gone, {:ok, item}}}, socket),
    do: socket |> assign(saving: nil) |> save_item(item, at)

  # A cleared page has no row left to report on.
  def handle_async(:fetched_item, _failed, %{assigns: %{saving: nil}} = socket),
    do: {:noreply, socket}

  def handle_async(:fetched_item, {:ok, {_at, gone, {:error, :not_found}}}, socket),
    do: fetch_failed(socket, gone)

  def handle_async(:fetched_item, _failed, socket),
    do: fetch_failed(socket, message(:unavailable))

  # Only a link to one video or episode yields an item. Its preview holds the entry.
  def handle_async(:item, {:ok, {:ok, %{preview: preview, external_id: _} = item}}, socket) do
    if on?(socket, preview.kind),
      do: {:noreply, show_item(socket, item)},
      else: {:noreply, assign(socket, error: message(:platform_off))}
  end

  def handle_async(:item, _result, socket), do: {:noreply, socket}

  def handle_async(:subscribe, {:ok, {opts, {:ok, [preview | _]}}}, socket),
    do: socket |> assign(subscribing: nil) |> subscribe(preview, opts)

  def handle_async(:subscribe, {:ok, {_opts, {:error, reason}}}, socket),
    do: row_failed(socket, reason)

  def handle_async(:subscribe, _result, socket), do: row_failed(socket, :unavailable)

  def handle_async(:sources, {:ok, {:error, reason}}, socket), do: failed(socket, reason)
  def handle_async(:sources, {:exit, _reason}, socket), do: failed(socket, :unavailable)

  defp found_sources(socket, sources) do
    sources = keyed(sources, :id)

    search? = socket.assigns.mode == :search
    sources = if search?, do: scored(sources, :podcasts, socket.assigns.term), else: sources
    socket = assign(socket, busy: false, candidates: by_id(sources))

    if search?,
      do: {:noreply, answered(socket)},
      else: {:noreply, show_sources(socket, sources)}
  end

  defp failed(socket, reason),
    do: {:noreply, socket |> assign(busy: false, error: message(reason)) |> answered()}

  @impl true
  # A search's deadline. A new lookup cancels the timer; one that fired already names its term.
  def handle_info({:settle, term}, %{assigns: %{mode: :search, term: term}} = socket),
    do: {:noreply, socket |> assign(settled: true) |> show_rows()}

  def handle_info(_stale, socket), do: {:noreply, socket}

  defp fetch_failed(socket, error) do
    errors = Map.put(socket.assigns.row_errors, socket.assigns.saving, error)
    {:noreply, socket |> assign(saving: nil, row_errors: errors) |> show_rows()}
  end

  defp row_failed(socket, reason) do
    errors = Map.put(socket.assigns.row_errors, socket.assigns.subscribing, message(reason))

    {:noreply,
     socket
     |> assign(subscribing: nil, row_errors: errors)
     |> show_rows()}
  end

  # A programme names the source its series is subscribed as.
  defp with_series(programme) do
    %{preview: source} = Discovery.mediathek_item(programme)
    Map.merge(programme, %{series_url: source.url, series_title: source.title})
  end

  # The Mediathek's programmes grouped by topic and channel, in the order they first appear.
  # A programme without a topic forms no series.
  defp grouped(programmes) do
    programmes
    |> Enum.reject(&(&1.topic == ""))
    |> Enum.group_by(&{&1.channel, &1.topic})
    |> Enum.map(fn {_, [first | _] = members} ->
      %{
        title: first.series_title,
        # The search sees one page, so the row names the hit, not the series' size or newest.
        found: first.title,
        found_at: first.published_at,
        series_url: first.series_url,
        # A series tries the pages of its first programmes.
        pages: members |> Enum.map(& &1.page_url) |> Enum.reject(&is_nil/1) |> Enum.take(3),
        first: String.to_integer(first.key)
      }
    end)
    |> Enum.sort_by(& &1.first)
  end

  # A search's answer. The list renders once no search is left, or once its deadline passed.
  defp answered(%{assigns: %{mode: :search} = assigns} = socket) do
    waiting =
      assigns.busy or Enum.any?(@states, fn {_kind, state} -> assigns[state] == :searching end)

    socket |> assign(waiting: waiting, settled: assigns.settled or not waiting) |> show_rows()
  end

  defp answered(socket), do: show_rows(socket)

  # A stream re-renders a row only when it is inserted again.
  # Re-inserting all rows in order updates each row's state.
  defp show_rows(%{assigns: %{mode: :search} = assigns} = socket) do
    rows = ranked(assigns)
    counts = Map.new(@results, fn {kind, results} -> {kind, map_size(assigns[results])} end)

    socket
    |> assign(counts: counts)
    |> stream(:results, shown(assigns, rows), reset: true)
  end

  defp show_rows(socket) do
    rows = socket.assigns.candidates |> Map.values() |> Enum.sort_by(&String.to_integer(&1.id))
    stream(socket, :sources, rows, reset: true)
  end

  defp shown(%{settled: false}, _rows), do: []
  defp shown(%{filter: nil}, rows), do: Enum.take(rows, @shown)
  defp shown(%{filter: kind}, rows), do: Enum.filter(rows, &(&1.kind == kind))

  # Every hit with its kind and row id, best match first. A tie keeps each index's order.
  defp ranked(assigns) do
    for {{kind, results}, order} <- Enum.with_index(@results),
        hit <- Map.values(assigns[results]) do
      key = hit[:key] || hit.id

      %{
        id: @prefixes[kind] <> key,
        kind: kind,
        hit: hit,
        rank: {-hit.score, String.to_integer(key), order}
      }
    end
    |> Enum.sort_by(& &1.rank)
  end

  # Each hit's score is computed once, when its index answers. Rows re-render on every event.
  defp scored(hits, kind, term) do
    Enum.map(hits, fn hit ->
      {title, origin} = named(kind, hit)
      Map.put(hit, :score, SearchRank.score(term, title, origin))
    end)
  end

  defp by_id(hits), do: Map.new(hits, &{&1.id, &1})
  defp by_key(hits), do: Map.new(hits, &{&1.key, &1})

  # The title a hit is ranked by, and the name of the show or channel it comes from.
  defp named(:podcasts, hit), do: {hit.title, hit[:author]}
  defp named(:episodes, hit), do: {hit.title, hit.podcast}
  defp named(:programmes, hit), do: {hit.title, hit.topic}
  defp named(kind, hit) when kind in [:videos, :youtube_videos], do: {hit.title, hit.channel}
  defp named(_kind, hit), do: {hit.title, nil}

  defp discover(socket, url),
    do:
      socket
      |> searching(:link)
      |> start_async(:sources, fn -> Discovery.discover(url) end)
      |> start_async(:item, fn -> Discovery.item(url) end)

  # A platform that is off is not asked. Its searches have no state, so the list does not wait.
  defp search(socket, term) do
    searches = Enum.filter(@searches, fn {_search, kind} -> on?(socket, kind) end)

    socket =
      socket
      |> searching(:search)
      |> assign(
        term: term,
        waiting: true,
        busy: Enum.any?(searches, &match?({:sources, _kind}, &1)),
        deadline: Process.send_after(self(), {:settle, term}, @deadline)
      )

    searching =
      for {search, _kind} <- searches, @states[search], do: {@states[search], :searching}

    searches
    |> Enum.reduce(assign(socket, searching), fn {search, _kind}, socket ->
      start_async(socket, search, fn -> searched(search, term) end)
    end)
    |> answered()
  end

  defp searched(:sources, term), do: Discovery.search(term)
  defp searched(:episodes, term), do: Discovery.episode_search(term)
  defp searched(:programmes, term), do: Discovery.mediathek_search(term)
  defp searched(:channels, term), do: Discovery.peertube_channel_search(term)
  defp searched(:videos, term), do: Discovery.peertube_video_search(term)
  defp searched(:youtube_channels, term), do: Discovery.youtube_channel_search(term)
  defp searched(:youtube_videos, term), do: Discovery.youtube_video_search(term)

  defp on?(socket, kind), do: Map.get(socket.assigns.platforms, kind) != false

  # A new lookup cancels a pending subscribe task.
  defp searching(socket, mode) do
    socket
    |> cancel_lookups()
    |> assign(busy: true, mode: mode)
    |> without_results()
  end

  defp cancel_lookups(socket) do
    if timer = socket.assigns[:deadline], do: Process.cancel_timer(timer)
    Enum.reduce(@lookups, assign(socket, deadline: nil), &cancel_async(&2, &1))
  end

  # The state of a page that has looked nothing up yet.
  defp without_results(socket) do
    socket
    |> assign(
      error: nil,
      candidates: %{},
      fallback: nil,
      subscribing: nil,
      asking: nil,
      row_errors: %{},
      item: nil,
      programmes: %{},
      programmes_state: nil,
      episodes: %{},
      episodes_state: nil,
      series: %{},
      channels: %{},
      channels_state: nil,
      videos: %{},
      videos_state: nil,
      youtube_channels: %{},
      youtube_channels_state: nil,
      youtube_videos: %{},
      youtube_videos_state: nil,
      saving: nil,
      more: nil,
      term: nil,
      waiting: false,
      settled: false,
      counts: %{},
      filter: nil
    )
    |> stream(:sources, [], reset: true)
    |> stream(:results, [], reset: true)
  end

  # Gives each result a key in list order. A row's button names the key, not the result.
  defp keyed(results, field) do
    results
    |> Enum.with_index()
    |> Enum.map(fn {result, index} -> Map.put(result, field, to_string(index)) end)
  end

  # The single item card for one video, episode or programme in `preview`.
  defp show_item(socket, %{preview: preview, external_id: id}) do
    entry = Enum.find(preview.entries, &(&1.external_id == id))

    socket
    |> assign(item: %{preview: preview, external_id: id, entry: entry})
    |> without_item_source()
  end

  # A link's item takes its source's row away. A search streams its sources as they are.
  defp show_sources(%{assigns: %{item: nil}} = socket, sources),
    do: stream(socket, :sources, sources, reset: true)

  defp show_sources(socket, _sources), do: without_item_source(socket)

  # The item's row subscribes to its source, so the source needs no row of its own. The sources
  # stream once from what remains: a reset after an insert in one render keeps the insert.
  defp without_item_source(socket) do
    url = get_in(socket.assigns, [:item, :preview, :url])

    candidates =
      Map.reject(socket.assigns.candidates, fn {_id, source} -> url && source[:url] == url end)

    socket |> assign(candidates: candidates) |> show_rows()
  end

  # A search row shows plain text. The parser gives HTML notes a plain excerpt.
  defp item_description(%{excerpt: excerpt}) when is_binary(excerpt) and excerpt != "",
    do: excerpt

  defp item_description(%{description: notes, description_format: :text}) when is_binary(notes),
    do: notes

  defp item_description(_entry), do: nil

  # Saving into the inbox keeps an earlier playback state, and an enqueue can fail. The page
  # opens the list that holds the entry afterwards.
  defp save_item(socket, %{preview: preview, external_id: id}, at) do
    account = socket.assigns.current_account
    at = String.to_existing_atom(at)

    with {:ok, %{id: entry_id}} <- Library.save(account, preview, id, at),
         %{} = entry <- Library.entry(account, entry_id) do
      place = place(entry.playback)

      message =
        case place do
          "queue" -> gettext("Added %{title} to the queue.", title: entry.title)
          "inbox" -> gettext("Added %{title} to the inbox.", title: entry.title)
          _ -> gettext("Saved %{title}.", title: entry.title)
        end

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> push_navigate(to: LibraryPaths.library_path(%{"status" => place}, entry))}
    else
      {:error, :platform_off} ->
        {:noreply, socket |> put_flash(:error, message(:platform_off)) |> show_rows()}

      # An episode's row was disabled while its feed was fetched.
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save this item. Please try again."))
         |> show_rows()}
    end
  end

  # The list that shows an entry with this playback state, as `Library` filters them.
  defp place(%{queue_rank: rank}) when not is_nil(rank), do: "queue"
  defp place(%{status: :heard}), do: "heard"
  defp place(%{status: status}) when status not in [nil, :new], do: "all"
  defp place(_new), do: "inbox"

  defp subscribe(socket, preview, opts) do
    account = socket.assigns.current_account

    case Library.subscribe(account, preview, opts) do
      {:ok, subscription} ->
        # An existing subscription keeps its custom name.
        name = source_name(subscription)
        to = LibraryPaths.source_path(subscription)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Subscribed to %{title}.", title: name))
         |> push_navigate(to: to)}

      {:error, :platform_off} ->
        {:noreply, socket |> put_flash(:error, message(:platform_off)) |> show_rows()}

      # Re-inserts the rows, so no row keeps its pending state after a failure.
      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save this subscription. Please try again."))
         |> show_rows()}
    end
  end

  # With every platform on, the hint names them all. Otherwise it names those that are on.
  defp hint(platforms) do
    kinds = Platforms.kinds()

    case Enum.filter(kinds, &platforms[&1]) do
      ^kinds ->
        gettext(
          "Paste a link to a podcast, a YouTube or PeerTube channel or video, or search Apple Podcasts, the Mediathek, PeerTube and YouTube."
        )

      [] ->
        gettext("Every platform is switched off on this instance.")

      on ->
        gettext("Paste a link, or search by name. On this instance: %{platforms}.",
          platforms: Enum.map_join(on, ", ", &platform_name/1)
        )
    end
  end

  defp platform_name(:podcast), do: "Apple Podcasts"
  defp platform_name(:mediathek), do: gettext("the Mediathek")
  defp platform_name(:peertube), do: "PeerTube"
  defp platform_name(:youtube), do: "YouTube"

  # Messages name a next step where one exists.
  # A generic error does not tell whether to retry, fix the link or give up.
  defp message(:unsafe_url),
    do:
      gettext(
        "Please use a public http or https URL. Local and private addresses cannot be imported."
      )

  defp message(:not_found),
    do:
      gettext(
        "No podcast, YouTube or PeerTube feed found. Try the show's RSS URL or the channel's URL."
      )

  defp message(:youtube_unavailable),
    do:
      gettext(
        "YouTube did not reveal this channel. Try its channel URL; private or unavailable videos cannot be resolved."
      )

  defp message(:platform_off),
    do: gettext("This platform is switched off on this instance. Ask an administrator.")

  defp message(:invalid_search),
    do: gettext("Enter between 2 and 120 characters to search.")

  defp message(:directory_unavailable),
    do:
      gettext(
        "Apple Podcasts search is unavailable right now. You can still paste a feed or webpage URL."
      )

  defp message(:invalid_feed),
    do: gettext("This source is not a supported podcast, YouTube or PeerTube feed.")

  defp message(:too_large),
    do: gettext("This page or feed is too large to import. Try a direct feed URL.")

  defp message(_),
    do: gettext("Could not read this source. Please check the link or try again later.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:add}
      title={gettext("Add a source")}
      back={%{to: ~p"/library", label: gettext("Library")}}
    >
      <%!-- Centered like a search page; the results below use the full width. --%>
      <header class="mx-auto max-w-2xl pt-4 pb-4 text-center sm:pt-10">
        <h1 data-large-title class="text-title font-semibold">{gettext("Add a source")}</h1>
        <p id="add-subtitle" class="mt-2 text-muted">
          {gettext("Paste a link, or search for a show by its name.")}
        </p>
      </header>
      <div>
        <.form
          for={@form}
          id="add-form"
          phx-change="validate"
          phx-submit="add"
          class="mx-auto mt-8 max-w-2xl"
        >
          <label for="add-q" class="text-label font-semibold text-ink">
            {gettext("Link or search")}
          </label>
          <fieldset disabled={@busy} class="mt-1.5 flex flex-col gap-2 sm:flex-row">
            <div class="relative flex-1">
              <input
                id="add-q"
                type="text"
                name="q"
                value={@form[:q].value}
                required
                maxlength="2048"
                autocomplete="off"
                aria-describedby="add-hint"
                placeholder={gettext("A link or a show's name")}
                class={[field_class(), "min-h-11 min-w-0 py-0 pr-11 sm:min-h-9 sm:pr-9"]}
              />
              <button
                :if={@form[:q].value not in [nil, ""]}
                id="clear-search"
                type="button"
                phx-click="clear"
                aria-label={gettext("Clear search")}
                title={gettext("Clear search")}
                class="absolute inset-y-0 right-0 flex w-11 items-center justify-center text-muted hover:text-ink sm:w-9"
              >
                <Lucideicons.x aria-hidden="true" class="size-4" />
              </button>
            </div>
            <.button variant="primary">
              {gettext("Find")}
              <Lucideicons.arrow_right aria-hidden="true" class="size-4" />
            </.button>
          </fieldset>
          <p id="add-hint" class="mt-2 text-center text-meta leading-relaxed text-muted">
            {hint(@platforms)}
          </p>
        </.form>
        <div
          :if={@mode != :search}
          aria-live="polite"
          class="mx-auto mt-6 flex max-w-2xl flex-col gap-3 text-center empty:hidden"
        >
          <p :if={@busy} id="discovery-loading" class="text-label text-muted">
            {gettext("Looking for your next good listen or watch…")}
          </p>
        </div>
        <%!-- `role="alert"` outside the `aria-live` region, so it is announced once. A search
        reports its errors below its pills. --%>
        <div
          :if={@error && @mode != :search}
          id="discovery-error"
          role="alert"
          class="mx-auto mt-6 flex max-w-2xl flex-col gap-2 rounded-control bg-danger-surface p-4 text-label text-danger sm:flex-row sm:items-center sm:justify-between"
        >
          <span>{@error}</span>
          <button
            :if={@fallback}
            id="search-instead"
            type="button"
            phx-click="search_instead"
            class="text-link font-semibold"
          >
            {gettext("Search for it instead")}
          </button>
        </div>
        <%!-- A link to one video or episode shows it as a search shows a hit. --%>
        <div :if={@item} class={list_class()}>
          <.item_row
            id="single-item"
            list="item"
            key="item"
            title={@item.entry.title}
            origin={[@item.preview.title]}
            published_at={@item.entry.published_at}
            duration={@item.entry.duration}
            description={item_description(@item.entry)}
            picture={artwork(Map.put(@item.entry, :feed, @item.preview))}
            more={@more == "single-item"}
            save="save_item"
            subscribe_label={gettext("Subscribe to %{title}", title: @item.preview.title)}
            subscribing={@subscribing}
          />
        </div>
        <%!-- A pasted link's sources. --%>
        <div id="sources" phx-update="stream" class={list_class()}>
          <.source_row
            :for={{dom_id, source} <- @streams.sources}
            id={dom_id}
            picture={source_picture(source)}
            title={source.title}
            action={%{"phx-click" => "select", "phx-value-id" => source.id}}
            disabled={@busy or @subscribing != nil}
            subscribing={@subscribing == source.id}
            error={@row_errors[source.id]}
          >
            <span :if={source[:author]}>{source.author}</span>
            <span :if={source[:entries]}>
              {gettext("%{count} recent items available", count: length(source.entries))}
            </span>
            <span class="min-w-0 truncate font-mono" title={source.url}>
              {String.replace_prefix(source.url, "https://", "")}
            </span>
          </.source_row>
        </div>
        <%!-- A search lists the hits of every index in one list. A pill per kind shows its count
        and filters the list. --%>
        <div :if={@mode == :search} class="mt-8">
          <div
            id="search-filters"
            role="group"
            aria-label={gettext("Filter results")}
            class="flex flex-wrap justify-center gap-2"
          >
            <.filter_pill
              :for={{kind, label} <- pills()}
              kind={to_string(kind)}
              label={label}
              count={Map.get(@counts, kind, 0)}
              filter={@filter}
            />
          </div>
          <p :if={@waiting} id="search-loading" class="mt-3 text-label text-muted">
            {gettext("Searching Apple Podcasts, the Mediathek, PeerTube and YouTube…")}
          </p>
          <%!-- Searches of one index fail together, so each index reports once. --%>
          <div class="mt-3 flex flex-col gap-1 text-label text-danger empty:hidden">
            <p :if={@error} id="search-error" role="alert">{@error}</p>
            <p :if={@episodes_state == :failed and is_nil(@error)} id="episodes-error" role="alert">
              {gettext("Apple Podcasts search is unavailable right now. Try again later.")}
            </p>
            <p :if={@programmes_state == :failed} id="programmes-error" role="alert">
              {gettext("The Mediathek search is unavailable right now. Try again later.")}
            </p>
            <p
              :if={@channels_state == :failed or @videos_state == :failed}
              id="channels-error"
              role="alert"
            >
              {gettext("The PeerTube search is unavailable right now. Try again later.")}
            </p>
            <p :if={@youtube_channels_state == :failed} id="youtube-channels-error" role="alert">
              {gettext(
                "YouTube's results could not be read right now. Try again later, or paste the channel's link."
              )}
            </p>
            <p :if={@youtube_videos_state == :failed} id="youtube-videos-error" role="alert">
              {gettext(
                "YouTube's results could not be read right now. Try again later, or paste the video's link."
              )}
            </p>
          </div>
          <p
            :if={@settled and not @waiting and Enum.all?(@counts, fn {_kind, n} -> n == 0 end)}
            id="no-results"
            class="mt-3 text-muted"
          >
            {gettext("Nothing found. Try another name or paste the show's website.")}
          </p>
        </div>
        <div id="results" phx-update="stream" class={list_class()}>
          <.result
            :for={{dom_id, row} <- @streams.results}
            id={dom_id}
            row={row}
            busy={@busy}
            subscribing={@subscribing}
            saving={@saving}
            errors={@row_errors}
            more={@more}
          />
        </div>
        <.confirm_dialog
          :if={@asking}
          name="subscribe"
          title={gettext("Subscribe to %{title}", title: @asking.title)}
          confirm_label={gettext("Subscribe")}
          wide
        >
          <form
            id="subscribe-form"
            phx-change="subscribe_options"
            class="flex flex-col gap-5"
          >
            <%!-- The archive takes every present item, so the question goes away. --%>
            <.radio_group
              :if={@asking.delivery != "skip"}
              name="existing"
              legend={gettext("Episodes so far")}
              options={[
                {"newest", gettext("Only the newest")},
                {"all", gettext("All, oldest first")},
                {"none", gettext("None")}
              ]}
              value={@asking.existing}
            />
            <.radio_group
              name="delivery"
              legend={gettext("New episodes go to")}
              options={SubscriptionSettings.deliveries()}
              value={@asking.delivery}
            />
          </form>
        </.confirm_dialog>
        <p class="mt-10 text-center text-label text-muted">
          {gettext("Coming from another app?")}
          <.link id="add-opml" navigate={~p"/subscriptions/import"} class="font-semibold text-link">
            {gettext("Import OPML")}
          </.link>
        </p>
      </div>
    </Layouts.member>
    """
  end

  attr :kind, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :filter, :atom, required: true

  # A kind's count and its filter. A kind without hits shows no pill.
  defp filter_pill(assigns) do
    assigns = assign(assigns, pressed: to_string(assigns.filter) == assigns.kind)

    ~H"""
    <button
      :if={@count > 0}
      id={"filter-" <> @kind}
      type="button"
      phx-click="filter"
      phx-value-kind={@kind}
      aria-pressed={to_string(@pressed)}
      class="inline-flex min-h-8 items-center gap-2 rounded-full border border-line bg-surface px-3 text-label text-ink hover:bg-ground aria-pressed:border-transparent aria-pressed:bg-accent aria-pressed:font-semibold aria-pressed:text-on-accent"
    >
      {@label}
      <span class="font-mono text-meta font-normal">{@count}</span>
    </button>
    """
  end

  # Each kind's pill label, in the order of `@results`.
  defp pills, do: for({kind, _results} <- @results, do: {kind, pill_label(kind)})

  defp pill_label(:podcasts), do: gettext("Podcasts")
  defp pill_label(:episodes), do: gettext("Episodes")
  defp pill_label(:series), do: gettext("Series")
  defp pill_label(:programmes), do: gettext("Programmes")
  defp pill_label(:channels), do: gettext("PeerTube channels")
  defp pill_label(:videos), do: gettext("PeerTube videos")
  defp pill_label(:youtube_channels), do: gettext("YouTube channels")
  defp pill_label(:youtube_videos), do: gettext("YouTube videos")

  # The index a hit comes from. The row's buttons tell a source from a single item.
  defp index(kind) when kind in [:podcasts, :episodes], do: "Apple Podcasts"
  defp index(kind) when kind in [:series, :programmes], do: "Mediathek"
  defp index(kind) when kind in [:channels, :videos], do: "PeerTube"
  defp index(_youtube), do: "YouTube"

  # One hit of the search list, drawn as its kind's row.
  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :busy, :boolean, required: true
  attr :subscribing, :string, default: nil
  attr :saving, :string, default: nil
  attr :errors, :map, required: true
  attr :more, :string, default: nil

  defp result(assigns) do
    kind = assigns.row.kind
    assigns = assign(assigns, kind: kind, hit: assigns.row.hit, index: index(kind))

    ~H"""
    <.source_row
      :if={@kind == :podcasts}
      id={@id}
      index={@index}
      picture={source_picture(@hit)}
      title={@hit.title}
      action={%{"phx-click" => "select", "phx-value-id" => @hit.id}}
      disabled={@busy or @subscribing != nil}
      subscribing={@subscribing == @hit.id}
      error={@errors[@hit.id]}
    >
      <span :if={@hit[:author]}>{@hit.author}</span>
      <span class="min-w-0 truncate font-mono" title={@hit.url}>
        {String.replace_prefix(@hit.url, "https://", "")}
      </span>
    </.source_row>
    <.item_row
      :if={@kind == :episodes}
      id={@id}
      index={@index}
      list={to_string(@kind)}
      key={@hit.key}
      title={@hit.title}
      origin={[@hit.podcast]}
      published_at={@hit.published_at}
      duration={@hit.duration}
      description={@hit.description}
      picture={source_picture(%{kind: :podcast, icon_url: @hit.icon_url})}
      more={@more == @id}
      save="save_episode"
      saving={@saving == @id}
      subscribe_label={gettext("Subscribe to %{title}", title: @hit.podcast)}
      subscribing={@subscribing}
      error={@errors[@id]}
    />
    <.source_row
      :if={@kind == :series}
      id={@id}
      index={@index}
      picture={page_picture(@hit.pages)}
      title={@hit.title}
      action={
        %{"phx-click" => "subscribe", "phx-value-list" => "series", "phx-value-key" => @hit.key}
      }
      disabled={@subscribing != nil}
      subscribing={@subscribing == @id}
      error={@errors[@id]}
    >
      <%!-- The inner element truncates; the outer one is the flex item that holds the dot. --%>
      <span :if={@hit.found != ""} class="min-w-0" title={@hit.found}>
        <span class="truncate">{gettext("found: %{title}", title: @hit.found)}</span>
      </span>
      <span>{date(@hit.found_at)}</span>
    </.source_row>
    <.item_row
      :if={@kind == :programmes}
      id={@id}
      index={@index}
      list={to_string(@kind)}
      key={@hit.key}
      title={@hit.title}
      origin={[@hit.channel, @hit.topic]}
      published_at={@hit.published_at}
      duration={@hit.duration}
      description={@hit.description}
      picture={page_picture(List.wrap(@hit.page_url))}
      page_url={@hit.page_url}
      more={@more == @id}
      save="save_programme"
      subscribe_label={gettext("Subscribe to %{title}", title: @hit.series_title)}
      subscribing={@subscribing}
      error={@errors[@id]}
    />
    <.source_row
      :if={@kind == :channels}
      id={@id}
      index={@index}
      picture={source_picture(%{kind: :peertube, icon_url: @hit.icon_url})}
      title={@hit.title}
      action={
        %{"phx-click" => "subscribe", "phx-value-list" => "channels", "phx-value-key" => @hit.key}
      }
      disabled={@subscribing != nil}
      subscribing={@subscribing == @id}
      error={@errors[@id]}
    >
      <span>{@hit.host}</span>
      <span :if={@hit.videos_count}>
        {ngettext("1 video", "%{count} videos", @hit.videos_count)}
      </span>
    </.source_row>
    <.item_row
      :if={@kind == :videos}
      id={@id}
      index={@index}
      list={to_string(@kind)}
      key={@hit.key}
      title={@hit.title}
      origin={[@hit.channel]}
      published_at={@hit.published_at}
      duration={@hit.duration}
      picture={source_picture(%{kind: :peertube, icon_url: @hit.icon_url})}
      more={@more == @id}
      save="save_video"
      saving={@saving == @id}
      subscribe_label={gettext("Subscribe to %{title}", title: @hit.channel)}
      subscribing={@subscribing}
      error={@errors[@id]}
    />
    <.source_row
      :if={@kind == :youtube_channels}
      id={@id}
      index={@index}
      picture={source_picture(%{kind: :youtube, icon_url: @hit.icon_url})}
      title={@hit.title}
      action={
        %{
          "phx-click" => "subscribe",
          "phx-value-list" => "youtube_channels",
          "phx-value-key" => @hit.key
        }
      }
      disabled={@subscribing != nil}
      subscribing={@subscribing == @id}
      error={@errors[@id]}
    >
      <span>youtube.com</span>
    </.source_row>
    <.item_row
      :if={@kind == :youtube_videos}
      id={@id}
      index={@index}
      list={to_string(@kind)}
      key={@hit.key}
      title={@hit.title}
      origin={[@hit.channel]}
      duration={@hit.duration}
      picture={source_picture(%{kind: :youtube, icon_url: @hit.icon_url})}
      more={@more == @id}
      save="save_youtube_video"
      saving={@saving == @id}
      subscribe_label={gettext("Subscribe to %{title}", title: @hit.channel)}
      subscribing={@subscribing}
      error={@errors[@id]}
    />
    """
  end

  # A result list. Shown only with a row: after live navigation an empty stream holds
  # whitespace, which `:empty` would count as content.
  defp list_class,
    do:
      "mt-3 hidden divide-y divide-line overflow-hidden rounded-xl bg-surface ring-1 ring-line has-[article]:block"

  # Rows out of view load their picture only when scrolled to.
  attr :src, :string, required: true

  defp row_picture(assigns) do
    ~H"""
    <img src={@src} alt="" loading="lazy" class="size-12 shrink-0 rounded-md bg-line object-cover" />
    """
  end

  # One source to subscribe to. The inner block holds its details.
  attr :id, :string, required: true
  attr :picture, :string, required: true
  attr :title, :string, required: true
  attr :index, :string, default: nil, doc: "the search index a hit comes from"
  attr :action, :map, required: true, doc: "the button's click event and values"
  attr :disabled, :boolean, required: true
  attr :subscribing, :boolean, required: true
  attr :error, :string, default: nil
  slot :inner_block, required: true

  defp source_row(assigns) do
    ~H"""
    <article id={@id} class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 sm:flex-nowrap">
      <.row_picture src={@picture} />
      <div class="min-w-0 flex-1">
        <h3 class="truncate text-body font-semibold">{@title}</h3>
        <p class="meta-dots flex flex-wrap items-center text-meta text-muted">
          <span :if={@index} class="font-semibold">{@index}</span>
          {render_slot(@inner_block)}
        </p>
      </div>
      <.button data-action="subscribe" disabled={@disabled} {@action}>
        {if @subscribing, do: gettext("Subscribing…"), else: gettext("Subscribe")}
      </.button>
      <p :if={@error} role="alert" class="w-full text-label text-danger">{@error}</p>
    </article>
    """
  end

  # One episode or programme with its actions in view. A long description shows two lines until
  # “more” is pressed.
  attr :id, :string, required: true
  attr :list, :string, required: true, doc: "the results' name in `@subscribable`, or `item`"
  attr :key, :string, required: true
  attr :title, :string, required: true
  attr :index, :string, default: nil, doc: "the search index a hit comes from"
  attr :origin, :list, required: true
  attr :published_at, :any, default: nil
  attr :duration, :integer, default: nil
  attr :description, :string, default: nil
  attr :picture, :string, required: true
  attr :page_url, :string, default: nil
  attr :more, :boolean, required: true
  attr :save, :string, required: true
  attr :saving, :boolean, default: false
  attr :subscribe_label, :string, required: true
  attr :subscribing, :string, default: nil
  attr :error, :string, default: nil

  defp item_row(assigns) do
    ~H"""
    <article id={@id} class="flex items-start gap-x-4 px-4 py-3">
      <.row_picture src={@picture} />
      <div class="flex min-w-0 flex-1 flex-col gap-2">
        <div class="min-w-0">
          <h3 class="text-body font-semibold">{@title}</h3>
          <p class="meta-dots flex flex-wrap items-center text-meta text-muted">
            <span :if={@index} class="font-semibold">{@index}</span>
            <span :for={part <- @origin} :if={part not in [nil, ""]} class="min-w-0" title={part}>
              <span class="truncate">{part}</span>
            </span>
            <span :if={@published_at}>{date(@published_at)}</span>
            <span :if={@duration} class="font-mono">{runtime(@duration)}</span>
          </p>
        </div>
        <%!-- The text sits flush in the tag, because `whitespace-pre-line` would show the
        template's line breaks. --%>
        <p
          :if={@description}
          data-description
          class={["text-meta whitespace-pre-line text-ink", !@more && "line-clamp-2"]}
          phx-no-format
        >{@description}</p>
        <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-label">
          <button
            :if={@description && String.length(@description) > 120}
            type="button"
            data-more
            phx-click="more"
            phx-value-row={@id}
            aria-expanded={to_string(@more)}
            class="font-semibold text-link"
          >
            {if @more, do: gettext("less"), else: gettext("more")}
          </button>
          <a
            :if={@page_url}
            href={@page_url}
            target="_blank"
            rel="noopener"
            class="font-semibold text-link"
          >
            {gettext("Open in the Mediathek")}
          </a>
        </div>
        <div class="flex flex-wrap gap-2">
          <.button
            data-action="queue"
            phx-click={@save}
            phx-value-key={@key}
            phx-value-at="queue"
            disabled={@saving}
          >
            {gettext("Add to queue")}
          </.button>
          <.button
            data-action="inbox"
            phx-click={@save}
            phx-value-key={@key}
            phx-value-at="inbox"
            disabled={@saving}
          >
            {gettext("Add to inbox")}
          </.button>
          <.button
            data-action="subscribe"
            phx-click="subscribe"
            phx-value-list={@list}
            phx-value-key={@key}
            disabled={@subscribing != nil}
          >
            {if @subscribing == @id, do: gettext("Subscribing…"), else: @subscribe_label}
          </.button>
        </div>
        <p :if={@error} role="alert" class="text-label text-danger">{@error}</p>
      </div>
    </article>
    """
  end
end
