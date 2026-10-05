# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddSourceLive do
  @moduledoc """
  Turns a pasted link or a search into a source to preview before subscribing.

  Nothing subscribes straight from an address. Discovery runs in the background. The preview shows
  the title and the number of items before any button appears. Candidates stay on the server
  under generated ids, so a forged id selects nothing.

  Subscribing leads to the source's page. A new PeerTube instance must enter the content security
  policy, which a page load writes. Such a subscription loads the page instead of navigating to it.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents, only: [source_name: 1]

  alias Sikio.Feeds.Discovery
  alias Sikio.Library
  alias SikioWeb.Sidebar

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
       busy: false,
       error: nil,
       searched: false
     )
     |> stream_configure(:sources, dom_id: &"source-#{&1.id}")
     |> stream(:sources, [])}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{busy: true}} = socket)
      when event in ["add", "search_instead", "select"],
      do: {:noreply, socket}

  # The change handler exists so a reconnecting browser can be given back what was typed.
  def handle_event("validate", %{"q" => q}, socket),
    do: {:noreply, assign(socket, form: to_form(%{"q" => q}))}

  # One field: an address is looked up, anything else is searched for.
  def handle_event("add", %{"q" => q}, socket) do
    socket = assign(socket, form: to_form(%{"q" => q}))

    case Discovery.intent(q) do
      :empty ->
        {:noreply, socket}

      # Without a scheme the address was a guess, so its words can still be searched.
      {:link, url} ->
        fallback = if String.contains?(url, "://"), do: nil, else: url
        {:noreply, socket |> discover(url) |> assign(fallback: fallback)}

      {:search, term} ->
        {:noreply, search(socket, term)}
    end
  end

  # A word with a dot read as an address and led nowhere; the same words are searched instead.
  def handle_event("search_instead", _params, %{assigns: %{fallback: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("search_instead", _params, socket),
    do: {:noreply, search(socket, socket.assigns.fallback)}

  def handle_event("select", %{"id" => id}, socket) do
    case socket.assigns.candidates[id] do
      nil -> {:noreply, socket}
      %{entries: _} = preview -> subscribe(socket, preview)
      %{url: url} -> {:noreply, discover(socket, url)}
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

  def handle_async(:sources, {:ok, {:error, reason}}, socket), do: failed(socket, reason)
  def handle_async(:sources, {:exit, _reason}, socket), do: failed(socket, :unavailable)

  defp failed(socket, reason), do: {:noreply, assign(socket, busy: false, error: message(reason))}

  defp discover(socket, url),
    do:
      socket
      |> searching(:link)
      |> start_async(:sources, fn -> Discovery.discover(url) end)

  defp search(socket, term),
    do: socket |> searching(:search) |> start_async(:sources, fn -> Discovery.search(term) end)

  defp searching(socket, mode) do
    socket
    |> assign(busy: true, error: nil, searched: false, candidates: %{}, mode: mode, fallback: nil)
    |> stream(:sources, [], reset: true)
  end

  defp subscribe(socket, preview) do
    account = socket.assigns.current_account
    framed = Library.player_origins(account)

    case Library.subscribe(account, preview) do
      {:ok, subscription} ->
        # An earlier subscription keeps the name its member gave it.
        name = source_name(subscription)
        to = Sidebar.source_path(subscription)

        socket = put_flash(socket, :info, gettext("Subscribed to %{title}.", title: name))

        if Library.player_origins(account) == framed,
          do: {:noreply, push_navigate(socket, to: to)},
          else: {:noreply, redirect(socket, to: to)}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not save this subscription. Please try again.")
         )}
    end
  end

  # Each failure says what somebody can do next, because "could not read this source" on its own
  # leaves them guessing whether to retry, fix the link or give up.
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
      <%!-- Centred, as a search page is; the results below take the full width. --%>
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
              class={[field_class(), "min-h-11 min-w-0 flex-1 py-0 sm:min-h-9"]}
            />
            <.button variant="primary">
              {gettext("Find")}
              <Lucideicons.arrow_right aria-hidden="true" class="size-4" />
            </.button>
          </fieldset>
          <%!-- Two sentences, each on a line of its own. --%>
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
        <%!-- An alert of its own, outside the polite region, so it is announced once. --%>
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
              variant={if Map.has_key?(source, :entries), do: "primary"}
              phx-click="select"
              phx-value-id={source.id}
              disabled={@busy}
            >
              {if Map.has_key?(source, :entries),
                do: gettext("Subscribe"),
                else: gettext("Preview feed")}
            </.button>
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
