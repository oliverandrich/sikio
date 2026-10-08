# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddSourceLive do
  @moduledoc """
  Adds a source from a pasted link or an Apple Podcasts search.

  A pasted link shows a preview with its title and item count first.
  A search result subscribes in one click, which fetches and parses its feed.
  Discovery runs in `start_async/3`. Candidates stay in assigns under generated ids.
  A forged id therefore selects nothing.

  A link to one video or episode also offers that item alone, saved without a subscription.
  `/add?url=…` fills in the link and starts the lookup, for bookmarklets and share sheets.

  After subscribing, the view navigates to the source's page.
  A new PeerTube instance changes the CSP `frame-src`, which is set per HTTP request.
  In that case the view uses `redirect/2` instead of `push_navigate/2`.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents, only: [source_name: 1]

  alias Sikio.Feeds.Discovery
  alias Sikio.Library
  alias SikioWeb.LibraryPaths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Add a source"),
       form: to_form(%{"q" => ""}),
       mode: nil,
       fallback: nil,
       candidates: %{},
       subscribing: nil,
       row_errors: %{},
       busy: false,
       error: nil,
       searched: false,
       item: nil,
       item_at: "queue"
     )
     |> stream_configure(:sources, dom_id: &"source-#{&1.id}")
     |> stream(:sources, [])}
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

  def handle_event("select", _params, %{assigns: %{subscribing: id}} = socket) when id != nil,
    do: {:noreply, socket}

  # Keeps the `form` assign current, so the input survives a LiveView reconnect.
  def handle_event("validate", %{"q" => q}, socket),
    do: {:noreply, assign(socket, form: to_form(%{"q" => q}))}

  # One input: a URL is discovered, any other text is searched.
  def handle_event("add", %{"q" => q}, socket), do: {:noreply, lookup(socket, q)}

  # Keeps the chosen target, so it survives a LiveView reconnect.
  def handle_event("pick_item", %{"at" => at}, socket) when at in ["queue", "inbox"],
    do: {:noreply, assign(socket, item_at: at)}

  def handle_event("pick_item", _params, socket), do: {:noreply, socket}

  def handle_event("save_item", _params, %{assigns: %{item: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_item", _params, socket), do: save_item(socket, socket.assigns.item)

  # Clears the input, the results and any pending subscribe task.
  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:subscribe)
     |> cancel_async(:item)
     |> assign(
       form: to_form(%{"q" => ""}),
       busy: false,
       error: nil,
       searched: false,
       candidates: %{},
       mode: nil,
       fallback: nil,
       subscribing: nil,
       row_errors: %{},
       item: nil,
       item_at: "queue"
     )
     |> stream(:sources, [], reset: true)
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
        subscribe(socket, preview)

      # A search result is discovered and subscribed in one click. The list stays visible.
      %{url: url} ->
        {:noreply,
         socket
         |> assign(subscribing: id, row_errors: Map.delete(socket.assigns.row_errors, id))
         |> show_candidates()
         |> start_async(:subscribe, fn -> Discovery.discover(url) end)}
    end
  end

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
    sources =
      sources
      |> Enum.with_index()
      |> Enum.map(fn {source, index} -> Map.put(source, :id, to_string(index)) end)

    {:noreply,
     socket
     |> assign(busy: false, searched: true, candidates: Map.new(sources, &{&1.id, &1}))
     |> stream(:sources, sources, reset: true)}
  end

  # Only a link to one video or episode yields an item. Its preview holds the entry.
  def handle_async(:item, {:ok, {:ok, %{preview: preview, external_id: id}}}, socket) do
    entry = Enum.find(preview.entries, &(&1.external_id == id))
    {:noreply, assign(socket, item: %{preview: preview, external_id: id, entry: entry})}
  end

  def handle_async(:item, _result, socket), do: {:noreply, socket}

  def handle_async(:subscribe, {:ok, {:ok, [preview | _]}}, socket),
    do: socket |> assign(subscribing: nil) |> subscribe(preview)

  def handle_async(:subscribe, {:ok, {:error, reason}}, socket), do: row_failed(socket, reason)
  def handle_async(:subscribe, _result, socket), do: row_failed(socket, :unavailable)

  def handle_async(:sources, {:ok, {:error, reason}}, socket), do: failed(socket, reason)
  def handle_async(:sources, {:exit, _reason}, socket), do: failed(socket, :unavailable)

  defp failed(socket, reason), do: {:noreply, assign(socket, busy: false, error: message(reason))}

  defp row_failed(socket, reason) do
    errors = Map.put(socket.assigns.row_errors, socket.assigns.subscribing, message(reason))
    {:noreply, socket |> assign(subscribing: nil, row_errors: errors) |> show_candidates()}
  end

  # A stream re-renders a row only when it is inserted again.
  # Re-inserting all candidates in order updates each row's state.
  defp show_candidates(socket) do
    candidates =
      socket.assigns.candidates
      |> Map.values()
      |> Enum.sort_by(&String.to_integer(&1.id))

    stream(socket, :sources, candidates, reset: true)
  end

  defp discover(socket, url),
    do:
      socket
      |> searching(:link)
      |> start_async(:sources, fn -> Discovery.discover(url) end)
      |> start_async(:item, fn -> Discovery.item(url) end)

  defp search(socket, term),
    do: socket |> searching(:search) |> start_async(:sources, fn -> Discovery.search(term) end)

  # A new lookup cancels a pending subscribe task.
  defp searching(socket, mode) do
    socket
    |> cancel_async(:subscribe)
    |> cancel_async(:item)
    |> assign(
      busy: true,
      error: nil,
      searched: false,
      candidates: %{},
      mode: mode,
      fallback: nil,
      subscribing: nil,
      row_errors: %{},
      item: nil,
      item_at: "queue"
    )
    |> stream(:sources, [], reset: true)
  end

  # Saving into the inbox keeps an earlier playback state, and an enqueue can fail. The page
  # opens the list that holds the entry afterwards.
  defp save_item(socket, %{preview: preview, external_id: id}) do
    account = socket.assigns.current_account
    framed = Library.player_origins(account)
    at = String.to_existing_atom(socket.assigns.item_at)

    with {:ok, %{id: entry_id}} <- Library.save(account, preview, id, at),
         %{} = entry <- Library.entry(account, entry_id) do
      place = place(entry.playback)

      message =
        case place do
          "queue" -> gettext("Added %{title} to the queue.", title: entry.title)
          "inbox" -> gettext("Added %{title} to the inbox.", title: entry.title)
          _ -> gettext("Saved %{title}.", title: entry.title)
        end

      socket
      |> put_flash(:info, message)
      |> navigate(framed, LibraryPaths.library_path(%{"status" => place}, entry))
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not save this item. Please try again."))}
    end
  end

  # The list that shows an entry with this playback state, as `Library` filters them.
  defp place(%{queue_rank: rank}) when not is_nil(rank), do: "queue"
  defp place(%{status: :heard}), do: "heard"
  defp place(%{status: status}) when status not in [nil, :new], do: "all"
  defp place(_new), do: "inbox"

  # A new PeerTube instance changes the CSP `frame-src`, which only a full page load applies.
  defp navigate(socket, framed, to) do
    if Library.player_origins(socket.assigns.current_account) == framed,
      do: {:noreply, push_navigate(socket, to: to)},
      else: {:noreply, redirect(socket, to: to)}
  end

  defp subscribe(socket, preview) do
    account = socket.assigns.current_account
    framed = Library.player_origins(account)

    case Library.subscribe(account, preview) do
      {:ok, subscription} ->
        # An existing subscription keeps its custom name.
        name = source_name(subscription)
        to = LibraryPaths.source_path(subscription)

        socket
        |> put_flash(:info, gettext("Subscribed to %{title}.", title: name))
        |> navigate(framed, to)

      # Re-inserts the rows, so no row keeps its pending state after a failure.
      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save this subscription. Please try again."))
         |> show_candidates()}
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
            <span class="block">
              {gettext(
                "Links to YouTube and PeerTube channels and videos, podcast websites, RSS feeds and Apple Podcasts."
              )}
            </span>
            <span class="block">{gettext("Anything else is searched for in Apple Podcasts.")}</span>
          </p>
        </.form>
        <div
          aria-live="polite"
          class="mx-auto mt-6 flex max-w-2xl flex-col gap-3 text-center empty:hidden"
        >
          <p :if={@busy} id="discovery-loading" class="text-label text-muted">
            {gettext("Looking for your next good listen or watch…")}
          </p>
          <p
            :if={@searched and map_size(@candidates) == 0}
            id="no-results"
            class="text-muted"
          >
            {gettext("No podcasts found. Try another name or paste the show's website.")}
          </p>
        </div>
        <%!-- `role="alert"` outside the `aria-live` region, so it is announced once. --%>
        <div
          :if={@error}
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
        <section
          :if={@item}
          id="single-item"
          aria-labelledby="single-item-title"
          class="mt-6 rounded-xl bg-surface px-4 py-3 ring-1 ring-line"
        >
          <p class="text-meta font-semibold text-muted">{gettext("Only this item")}</p>
          <h3 id="single-item-title" class="mt-0.5 text-body font-semibold">
            {@item.entry.title}
          </h3>
          <p class="text-meta text-muted">{@item.preview.title}</p>
          <.form
            for={%{}}
            id="single-item-form"
            phx-change="pick_item"
            phx-submit="save_item"
            class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2"
          >
            <fieldset class="flex flex-1 flex-wrap items-center gap-x-4 gap-y-2">
              <legend class="sr-only">{gettext("Add to")}</legend>
              <label class="flex items-center gap-2.5 text-label text-ink">
                <input
                  type="radio"
                  name="at"
                  value="queue"
                  checked={@item_at == "queue"}
                  class="size-4 accent-accent"
                />
                {gettext("Queue")}
              </label>
              <label class="flex items-center gap-2.5 text-label text-ink">
                <input
                  type="radio"
                  name="at"
                  value="inbox"
                  checked={@item_at == "inbox"}
                  class="size-4 accent-accent"
                />
                {gettext("Inbox")}
              </label>
            </fieldset>
            <.button id="add-item">{gettext("Add")}</.button>
          </.form>
        </section>
        <h2
          :if={@mode == :search and map_size(@candidates) > 0}
          id="results-heading"
          class="mt-6 flex items-baseline gap-2 text-label font-semibold"
        >
          {gettext("Podcasts")}
          <span class="font-normal text-muted">{gettext("via Apple Podcasts")}</span>
        </h2>
        <p :if={@mode == :search and map_size(@candidates) > 0} class="mt-1 text-meta text-muted">
          {gettext(
            "Searches Apple's German directory. Results are provided by Apple; subscriptions use the show's own RSS feed."
          )}
        </p>
        <div
          id="sources"
          phx-update="stream"
          class="mt-3 divide-y divide-line overflow-hidden rounded-xl bg-surface ring-1 ring-line empty:hidden"
        >
          <article
            :for={{dom_id, source} <- @streams.sources}
            id={dom_id}
            class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 sm:flex-nowrap"
          >
            <div class="min-w-0 flex-1">
              <h3 class="truncate text-body font-semibold">{source.title}</h3>
              <p class="meta-dots flex flex-wrap items-center text-meta text-muted">
                <span :if={source[:author]}>{source.author}</span>
                <span :if={source[:entries]}>
                  {gettext("%{count} recent items available", count: length(source.entries))}
                </span>
                <span class="min-w-0 truncate font-mono" title={source.url}>
                  {String.replace_prefix(source.url, "https://", "")}
                </span>
              </p>
            </div>
            <.button
              phx-click="select"
              phx-value-id={source.id}
              disabled={@busy or @subscribing != nil}
            >
              {if @subscribing == source.id,
                do: gettext("Subscribing…"),
                else: gettext("Subscribe")}
            </.button>
            <p :if={@row_errors[source.id]} role="alert" class="w-full text-label text-danger">
              {@row_errors[source.id]}
            </p>
          </article>
        </div>
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
end
