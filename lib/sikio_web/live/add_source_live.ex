# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddSourceLive do
  @moduledoc """
  Adds a source from a pasted link or a search in Apple Podcasts, the Mediathek and PeerTube.

  A pasted link shows a preview with its title and item count first.
  Subscribing asks which present items to take and where later ones go. A search result's feed
  is fetched after the answer.
  A search also asks MediathekViewWeb. A programme from it is saved on its own, as an item.
  A search also asks a PeerTube index for channels and videos. A video is saved as its link is.
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
  alias Sikio.Library
  alias SikioWeb.LibraryPaths
  alias SikioWeb.SubscriptionSettings

  # Each tab with the assign that holds its results, in the order `choose_tab/1` tries them.
  @results [
    podcasts: :candidates,
    episodes: :episodes,
    series: :series,
    programmes: :programmes,
    channels: :channels,
    videos: :videos
  ]

  @tabs Enum.map(@results, fn {tab, _results} -> to_string(tab) end)

  # Each search besides Apple's podcast search with the assign that holds its state.
  @states %{
    episodes: :episodes_state,
    programmes: :programmes_state,
    channels: :channels_state,
    videos: :videos_state
  }

  # The rows that fetch their item before saving it, by the event that saves one.
  @fetched %{"save_episode" => :episodes, "save_video" => :videos}

  # Each list's rows subscribe to a source: its row id prefix, the fields with its address and
  # name, and the `Discovery` function that fetches it. A capture here would be a compile-time
  # dependency.
  @subscribable %{
    "episodes" => {:episodes, "episode-", :feed_url, :podcast, :discover},
    "series" => {:series, "series-", :series_url, :title, :mediathek_series},
    "programmes" => {:programmes, "programme-", :series_url, :series_title, :mediathek_series},
    "channels" => {:channels, "channel-", :url, :title, :discover},
    "videos" => {:videos, "video-", :channel_url, :channel, :discover}
  }

  @existing ~w(newest all none)

  # A series taken whole is fetched once with this many programmes. Its refreshes ask for 20.
  @whole_series 100

  # Each stream with the assign that holds its results and the field that orders them.
  @lists [
    {:sources, :candidates, :id},
    {:episodes, :episodes, :key},
    {:series, :series, :key},
    {:programmes, :programmes, :key},
    {:channels, :channels, :key},
    {:videos, :videos, :key}
  ]

  @lookups [:subscribe, :item, :programmes, :episodes, :fetched_item, :channels, :videos]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Add a source"),
       form: to_form(%{"q" => ""}),
       mode: nil,
       busy: false
     )
     |> stream_configure(:sources, dom_id: &"source-#{&1.id}")
     |> stream_configure(:programmes, dom_id: &"programme-#{&1.key}")
     |> stream_configure(:episodes, dom_id: &"episode-#{&1.key}")
     |> stream_configure(:series, dom_id: &"series-#{&1.key}")
     |> stream_configure(:channels, dom_id: &"channel-#{&1.key}")
     |> stream_configure(:videos, dom_id: &"video-#{&1.key}")
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

  # A tab keeps its place once the account picked it, while the other searches still answer.
  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, assign(socket, tab: String.to_existing_atom(tab), tab_picked: true)}

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
    {name, prefix, url, title, fetch} = @subscribable[list]

    case socket.assigns[name][key] do
      %{^url => address} = row when is_binary(address) ->
        {:noreply, ask(socket, prefix <> key, row[title], {fetch, address})}

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
      {"episode-" <> key, gettext("This episode is no longer in its podcast's feed."),
       fn -> Discovery.episode_item(episode) end}

  defp fetching(:videos, key, video),
    do:
      {"video-" <> key,
       gettext("This video could not be read from its PeerTube instance. Try again later."),
       fn -> Discovery.peertube_video_item(video.url) end}

  defp lookup(socket, q) do
    socket = assign(socket, form: to_form(%{"q" => q}))

    case Discovery.intent(q) do
      :empty ->
        socket

      # Input without a scheme only resembles a URL. It is kept as `fallback` for a search.
      {:link, url} ->
        fallback = if String.contains?(url, "://"), do: nil, else: url
        socket |> discover(url) |> assign(fallback: fallback)

      {:search, term} ->
        search(socket, term)
    end
  end

  @impl true
  def handle_async(:sources, {:ok, {:ok, sources}}, socket) do
    sources = keyed(sources, :id)

    {:noreply,
     socket
     |> assign(busy: false, searched: true, candidates: Map.new(sources, &{&1.id, &1}))
     |> show_sources(sources)
     |> choose_tab()}
  end

  def handle_async(:programmes, {:ok, {:ok, found}}, socket) do
    found = found |> Enum.map(&with_series/1) |> keyed(:key)
    series = found |> grouped() |> keyed(:key)

    {:noreply,
     socket
     |> assign(
       programmes: Map.new(found, &{&1.key, &1}),
       series: Map.new(series, &{&1.key, &1}),
       programmes_state: :done
     )
     |> stream(:programmes, found, reset: true)
     |> stream(:series, series, reset: true)
     |> choose_tab()}
  end

  def handle_async(source, {:ok, {:ok, found}}, socket)
      when source in [:episodes, :channels, :videos] do
    found = keyed(found, :key)

    {:noreply,
     socket
     |> assign([{source, Map.new(found, &{&1.key, &1})}, {@states[source], :done}])
     |> stream(source, found, reset: true)
     |> choose_tab()}
  end

  # The podcast search reports an invalid term. The other searches stay silent about it.
  def handle_async(source, {:ok, {:error, :invalid_search}}, socket)
      when is_map_key(@states, source),
      do: {:noreply, assign(socket, @states[source], nil)}

  def handle_async(source, _failed, socket) when is_map_key(@states, source),
    do: {:noreply, socket |> assign(@states[source], :failed) |> choose_tab()}

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
  def handle_async(:item, {:ok, {:ok, %{preview: _, external_id: _} = item}}, socket),
    do: {:noreply, show_item(socket, item)}

  def handle_async(:item, _result, socket), do: {:noreply, socket}

  def handle_async(:subscribe, {:ok, {opts, {:ok, [preview | _]}}}, socket),
    do: socket |> assign(subscribing: nil) |> subscribe(preview, opts)

  def handle_async(:subscribe, {:ok, {_opts, {:error, reason}}}, socket),
    do: row_failed(socket, reason)

  def handle_async(:subscribe, _result, socket), do: row_failed(socket, :unavailable)

  def handle_async(:sources, {:ok, {:error, reason}}, socket), do: failed(socket, reason)
  def handle_async(:sources, {:exit, _reason}, socket), do: failed(socket, :unavailable)

  defp failed(socket, reason),
    do: {:noreply, socket |> assign(busy: false, error: message(reason)) |> choose_tab()}

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

  # The first tab with results opens, unless the account picked one.
  defp choose_tab(%{assigns: %{tab_picked: true}} = socket), do: socket

  defp choose_tab(socket) do
    tab =
      Enum.find_value(@results, :podcasts, fn {tab, results} ->
        map_size(socket.assigns[results]) > 0 && tab
      end)

    assign(socket, tab: tab)
  end

  # A stream re-renders a row only when it is inserted again.
  # Re-inserting all rows in order updates each row's state.
  defp show_rows(socket) do
    Enum.reduce(@lists, socket, fn {stream, results, key}, socket ->
      rows = socket.assigns[results] |> Map.values() |> Enum.sort_by(&String.to_integer(&1[key]))
      stream(socket, stream, rows, reset: true)
    end)
  end

  defp discover(socket, url),
    do:
      socket
      |> searching(:link)
      |> start_async(:sources, fn -> Discovery.discover(url) end)
      |> start_async(:item, fn -> Discovery.item(url) end)

  defp search(socket, term) do
    socket
    |> searching(:search)
    |> assign(
      programmes_state: :searching,
      episodes_state: :searching,
      channels_state: :searching,
      videos_state: :searching
    )
    |> start_async(:sources, fn -> Discovery.search(term) end)
    |> start_async(:episodes, fn -> Discovery.episode_search(term) end)
    |> start_async(:programmes, fn -> Discovery.mediathek_search(term) end)
    |> start_async(:channels, fn -> Discovery.peertube_channel_search(term) end)
    |> start_async(:videos, fn -> Discovery.peertube_video_search(term) end)
  end

  # A new lookup cancels a pending subscribe task.
  defp searching(socket, mode) do
    socket
    |> cancel_lookups()
    |> assign(busy: true, mode: mode)
    |> without_results()
  end

  defp cancel_lookups(socket), do: Enum.reduce(@lookups, socket, &cancel_async(&2, &1))

  # The state of a page that has looked nothing up yet.
  defp without_results(socket) do
    socket
    |> assign(
      error: nil,
      searched: false,
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
      saving: nil,
      more: nil,
      tab: :podcasts,
      tab_picked: false
    )
    |> stream(:sources, [], reset: true)
    |> stream(:programmes, [], reset: true)
    |> stream(:episodes, [], reset: true)
    |> stream(:series, [], reset: true)
    |> stream(:channels, [], reset: true)
    |> stream(:videos, [], reset: true)
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

      # Re-inserts the rows, so no row keeps its pending state after a failure.
      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save this subscription. Please try again."))
         |> show_rows()}
    end
  end

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

  defp message(:invalid_search),
    do: gettext("Enter between 2 and 120 characters to search Apple Podcasts.")

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
            {gettext(
              "Paste a link to a podcast, a YouTube or PeerTube channel or video, or search Apple Podcasts, the Mediathek and PeerTube."
            )}
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
        reports its errors in its own tab. --%>
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
        <%!-- A search shows its two sources as tabs. Each tab reports its count, loading and
        errors. The panels stay in the DOM, because a stream loses its rows when its container
        leaves it. --%>
        <div
          :if={@mode == :search}
          id="search-tabs"
          role="tablist"
          aria-label={gettext("Search results")}
          class="mt-8 -mx-4 flex gap-1 overflow-x-auto overflow-y-hidden border-b border-line px-4 [scrollbar-width:none] sm:mx-0 sm:px-0"
        >
          <.search_tab
            tab="podcasts"
            selected={@tab == :podcasts}
            label={gettext("Podcasts")}
            count={if @busy, do: "…", else: map_size(@candidates)}
          />
          <.search_tab
            tab="episodes"
            selected={@tab == :episodes}
            label={gettext("Episodes")}
            count={if @episodes_state == :searching, do: "…", else: map_size(@episodes)}
          />
          <.search_tab
            tab="series"
            selected={@tab == :series}
            label={gettext("Series")}
            count={if @programmes_state == :searching, do: "…", else: map_size(@series)}
          />
          <.search_tab
            tab="programmes"
            selected={@tab == :programmes}
            label={gettext("Programmes")}
            count={if @programmes_state == :searching, do: "…", else: map_size(@programmes)}
          />
          <.search_tab
            tab="channels"
            selected={@tab == :channels}
            label={gettext("PeerTube channels")}
            count={if @channels_state == :searching, do: "…", else: map_size(@channels)}
          />
          <.search_tab
            tab="videos"
            selected={@tab == :videos}
            label={gettext("PeerTube videos")}
            count={if @videos_state == :searching, do: "…", else: map_size(@videos)}
          />
        </div>
        <div
          id="panel-podcasts"
          role={@mode == :search && "tabpanel"}
          aria-labelledby={@mode == :search && "tab-podcasts"}
          class={[(@mode == :search and @tab != :podcasts) && "hidden"]}
        >
          <p :if={@mode == :search} class="mt-3 text-meta text-muted">
            {gettext("Via Apple Podcasts. Subscriptions use the show's own RSS feed.")}
          </p>
          <p :if={@mode == :search and @busy} class="mt-3 text-label text-muted">
            {gettext("Searching Apple Podcasts…")}
          </p>
          <p
            :if={@searched and map_size(@candidates) == 0 and is_nil(@error) and is_nil(@item)}
            id="no-results"
            class="mt-3 text-muted"
          >
            {gettext("No podcasts found. Try another name or paste the show's website.")}
          </p>
          <p
            :if={@error && @mode == :search}
            id="search-error"
            role="alert"
            class="mt-3 text-label text-danger"
          >
            {@error}
          </p>
          <%!-- Shown only with a row. After live navigation an empty stream holds whitespace,
          which `:empty` would count as content. --%>
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
        </div>
        <div
          id="panel-episodes"
          role="tabpanel"
          aria-labelledby="tab-episodes"
          class={[@tab != :episodes && "hidden"]}
        >
          <p class="mt-3 text-meta text-muted">
            {gettext("Single episodes via Apple Podcasts. An episode is added on its own.")}
          </p>
          <.search_state
            id="episodes"
            state={@episodes_state}
            count={map_size(@episodes)}
            searching={gettext("Searching Apple Podcasts…")}
            empty={gettext("No episodes found.")}
            failed={gettext("Apple Podcasts search is unavailable right now. Try again later.")}
          />
          <div id="episodes" phx-update="stream" class={list_class()}>
            <.item_row
              :for={{dom_id, episode} <- @streams.episodes}
              id={dom_id}
              list="episodes"
              key={episode.key}
              title={episode.title}
              origin={[episode.podcast]}
              published_at={episode.published_at}
              duration={episode.duration}
              description={episode.description}
              picture={source_picture(%{kind: :podcast, icon_url: episode.icon_url})}
              more={@more == dom_id}
              save="save_episode"
              saving={@saving == dom_id}
              subscribe_label={gettext("Subscribe to %{title}", title: episode.podcast)}
              subscribing={@subscribing}
              error={@row_errors[dom_id]}
            />
          </div>
        </div>
        <div
          id="panel-series"
          role="tabpanel"
          aria-labelledby="tab-series"
          class={[@tab != :series && "hidden"]}
        >
          <p class="mt-3 text-meta text-muted">
            {gettext(
              "Series via MediathekViewWeb, from the German public broadcasters. A subscription follows a topic on its channel."
            )}
          </p>
          <.search_state
            id="series"
            state={@programmes_state}
            count={map_size(@series)}
            searching={gettext("Searching the Mediathek…")}
            empty={gettext("No series found in the Mediathek.")}
            failed={gettext("The Mediathek search is unavailable right now. Try again later.")}
          />
          <div id="series" phx-update="stream" class={list_class()}>
            <.source_row
              :for={{dom_id, series} <- @streams.series}
              id={dom_id}
              picture={page_picture(series.pages)}
              title={series.title}
              action={
                %{
                  "phx-click" => "subscribe",
                  "phx-value-list" => "series",
                  "phx-value-key" => series.key
                }
              }
              disabled={@subscribing != nil}
              subscribing={@subscribing == dom_id}
              error={@row_errors[dom_id]}
            >
              <%!-- The inner element truncates; the outer one is the flex item that holds the dot. --%>
              <span :if={series.found != ""} class="min-w-0" title={series.found}>
                <span class="truncate">{gettext("found: %{title}", title: series.found)}</span>
              </span>
              <span>{date(series.found_at)}</span>
            </.source_row>
          </div>
        </div>
        <div
          id="panel-programmes"
          role="tabpanel"
          aria-labelledby="tab-programmes"
          class={[@tab != :programmes && "hidden"]}
        >
          <p class="mt-3 text-meta text-muted">
            {gettext(
              "Films and programmes via MediathekViewWeb, from the German public broadcasters. A programme is added on its own."
            )}
          </p>
          <.search_state
            id="programmes"
            state={@programmes_state}
            count={map_size(@programmes)}
            searching={gettext("Searching the Mediathek…")}
            empty={gettext("No programmes found in the Mediathek.")}
            failed={gettext("The Mediathek search is unavailable right now. Try again later.")}
          />
          <div id="programmes" phx-update="stream" class={list_class()}>
            <.item_row
              :for={{dom_id, programme} <- @streams.programmes}
              id={dom_id}
              list="programmes"
              key={programme.key}
              title={programme.title}
              origin={[programme.channel, programme.topic]}
              published_at={programme.published_at}
              duration={programme.duration}
              description={programme.description}
              picture={page_picture(List.wrap(programme.page_url))}
              page_url={programme.page_url}
              more={@more == dom_id}
              save="save_programme"
              subscribe_label={gettext("Subscribe to %{title}", title: programme.series_title)}
              subscribing={@subscribing}
              error={@row_errors[dom_id]}
            />
          </div>
        </div>
        <div
          id="panel-channels"
          role="tabpanel"
          aria-labelledby="tab-channels"
          class={[@tab != :channels && "hidden"]}
        >
          <p class="mt-3 text-meta text-muted">
            {gettext(
              "Channels on PeerTube instances, via a search index across instances. Subscriptions use the channel's own feed."
            )}
          </p>
          <.search_state
            id="channels"
            state={@channels_state}
            count={map_size(@channels)}
            searching={gettext("Searching PeerTube…")}
            empty={gettext("No channels found on PeerTube.")}
            failed={gettext("The PeerTube search is unavailable right now. Try again later.")}
          />
          <div id="channels" phx-update="stream" class={list_class()}>
            <.source_row
              :for={{dom_id, channel} <- @streams.channels}
              id={dom_id}
              picture={source_picture(%{kind: :peertube, icon_url: channel.icon_url})}
              title={channel.title}
              action={
                %{
                  "phx-click" => "subscribe",
                  "phx-value-list" => "channels",
                  "phx-value-key" => channel.key
                }
              }
              disabled={@subscribing != nil}
              subscribing={@subscribing == dom_id}
              error={@row_errors[dom_id]}
            >
              <span>{channel.host}</span>
              <span :if={channel.videos_count}>
                {ngettext("1 video", "%{count} videos", channel.videos_count)}
              </span>
            </.source_row>
          </div>
        </div>
        <div
          id="panel-videos"
          role="tabpanel"
          aria-labelledby="tab-videos"
          class={[@tab != :videos && "hidden"]}
        >
          <p class="mt-3 text-meta text-muted">
            {gettext(
              "Videos on PeerTube instances, via a search index across instances. A video is added on its own."
            )}
          </p>
          <.search_state
            id="videos"
            state={@videos_state}
            count={map_size(@videos)}
            searching={gettext("Searching PeerTube…")}
            empty={gettext("No videos found on PeerTube.")}
            failed={gettext("The PeerTube search is unavailable right now. Try again later.")}
          />
          <div id="videos" phx-update="stream" class={list_class()}>
            <.item_row
              :for={{dom_id, video} <- @streams.videos}
              id={dom_id}
              list="videos"
              key={video.key}
              title={video.title}
              origin={[video.channel]}
              published_at={video.published_at}
              duration={video.duration}
              picture={source_picture(%{kind: :peertube, icon_url: video.icon_url})}
              more={@more == dom_id}
              save="save_video"
              saving={@saving == dom_id}
              subscribe_label={gettext("Subscribe to %{title}", title: video.channel)}
              subscribing={@subscribing}
              error={@row_errors[dom_id]}
            />
          </div>
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

  attr :tab, :string, required: true
  attr :selected, :boolean, required: true
  attr :label, :string, required: true
  attr :count, :any, required: true

  defp search_tab(assigns) do
    ~H"""
    <button
      id={"tab-" <> @tab}
      type="button"
      role="tab"
      aria-selected={to_string(@selected)}
      aria-controls={"panel-" <> @tab}
      phx-click="tab"
      phx-value-tab={@tab}
      class={[
        "-mb-px flex items-center gap-2 border-b-2 px-3 py-2 text-label font-semibold",
        if(@selected, do: "border-ink text-ink", else: "border-transparent text-muted hover:text-ink")
      ]}
    >
      {@label}
      <span class="rounded-full bg-ground px-2 font-mono text-meta font-normal">{@count}</span>
    </button>
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

  # The loading, empty and failed lines of one search.
  attr :id, :string, required: true
  attr :state, :atom, required: true
  attr :count, :integer, required: true
  attr :searching, :string, required: true
  attr :empty, :string, required: true
  attr :failed, :string, required: true

  defp search_state(assigns) do
    ~H"""
    <p :if={@state == :searching} id={@id <> "-loading"} class="mt-3 text-label text-muted">
      {@searching}
    </p>
    <p :if={@state == :done and @count == 0} id={"no-" <> @id} class="mt-3 text-muted">{@empty}</p>
    <p :if={@state == :failed} id={@id <> "-error"} role="alert" class="mt-3 text-label text-danger">
      {@failed}
    </p>
    """
  end

  # One episode or programme with its actions in view. A long description shows two lines until
  # “more” is pressed.
  attr :id, :string, required: true
  attr :list, :string, required: true, doc: "the results' name in `@subscribable`, or `item`"
  attr :key, :string, required: true
  attr :title, :string, required: true
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
