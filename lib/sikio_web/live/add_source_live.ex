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
       url_form: to_form(%{"url" => ""}),
       search_form: to_form(%{"term" => ""}),
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
      when event in ["discover", "search", "select"],
      do: {:noreply, socket}

  # Both change handlers exist so a reconnecting browser can be given back what was typed.
  def handle_event("validate-url", %{"url" => url}, socket),
    do: {:noreply, assign(socket, url_form: to_form(%{"url" => url}))}

  def handle_event("validate-term", %{"term" => term}, socket),
    do: {:noreply, assign(socket, search_form: to_form(%{"term" => term}))}

  def handle_event("discover", %{"url" => url}, socket) do
    {:noreply, socket |> assign(url_form: to_form(%{"url" => url})) |> discover(url)}
  end

  def handle_event("search", %{"term" => term}, socket) do
    {:noreply,
     socket
     |> assign(search_form: to_form(%{"term" => term}))
     |> searching()
     |> start_async(:sources, fn -> Discovery.search(term) end)}
  end

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
    do: socket |> searching() |> start_async(:sources, fn -> Discovery.discover(url) end)

  defp searching(socket) do
    socket
    |> assign(busy: true, error: nil, searched: false, candidates: %{})
    |> stream(:sources, [], reset: true)
  end

  defp subscribe(socket, preview) do
    account = socket.assigns.current_account
    framed = Library.player_origins(account)

    case Library.subscribe(account, preview) do
      {:ok, subscription} ->
        # An earlier subscription keeps the name its member gave it.
        name = source_name(subscription)

        to =
          Sidebar.place_path("source", to_string(subscription.feed_id), %{
            subscription.feed_id => name
          })

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
      <p class="mb-4 text-meta font-semibold text-muted">
        {gettext("Curated by you")}
      </p>
      <.header>
        {gettext("Make room for the good stuff.")}
        <:subtitle>
          {gettext("A channel, a video, a podcast website. Paste a link and let Sikio find the feed.")}
        </:subtitle>
      </.header>
      <p class="mt-4 text-label text-muted">
        {gettext("Coming from another app?")}
        <.link id="add-opml" navigate={~p"/subscriptions/import"} class="font-semibold text-link">
          {gettext("Import OPML")}
        </.link>
      </p>
      <div class="mt-8 grid gap-6 lg:grid-cols-2">
        <section class="rounded-control border border-line bg-surface p-6 sm:p-8">
          <h2 class="mb-6 text-lg font-semibold">{gettext("Start with a link")}</h2>
          <.form for={@url_form} id="discover-form" phx-change="validate-url" phx-submit="discover">
            <fieldset disabled={@busy}>
              <.input
                name="url"
                value={@url_form[:url].value}
                label={gettext("YouTube or podcast URL")}
                required
                placeholder="youtube.com/@your-favourite-channel"
              />
              <.button variant="primary">
                {gettext("Find feed")}
                <Lucideicons.arrow_right aria-hidden="true" class="size-4" />
              </.button>
            </fieldset>
          </.form>
          <p id="discover-hint" class="mt-5 text-meta leading-relaxed text-muted">
            {gettext(
              "YouTube channels, videos and Shorts · PeerTube channels and videos · Podcast websites, RSS feeds and Apple Podcasts links"
            )}
          </p>
        </section>
        <section class="rounded-control border border-line bg-ground p-6 sm:p-8">
          <h2 class="mb-6 text-lg font-semibold">{gettext("Or find a podcast")}</h2>
          <.form for={@search_form} id="search-form" phx-change="validate-term" phx-submit="search">
            <fieldset disabled={@busy}>
              <.input
                name="term"
                value={@search_form[:term].value}
                label={gettext("Search Apple Podcasts")}
                required
                placeholder={gettext("Show name or topic")}
              />
              <.button variant="primary">
                {gettext("Search podcasts")}
                <Lucideicons.search aria-hidden="true" class="size-4" />
              </.button>
            </fieldset>
          </.form>
          <p class="mt-5 text-meta leading-relaxed text-muted">
            {gettext(
              "Searches Apple's German directory. Results are provided by Apple; subscriptions use the show's own RSS feed."
            )}
          </p>
        </section>
      </div>
      <div aria-live="polite" class="mt-6">
        <p :if={@busy} id="discovery-loading" class="text-label text-muted">
          {gettext("Looking for your next good listen or watch…")}
        </p>
        <p
          :if={@error}
          id="discovery-error"
          role="alert"
          class="rounded-control bg-danger-surface p-4 text-label text-danger"
        >
          {@error}
        </p>
        <p
          :if={@searched and map_size(@candidates) == 0}
          id="no-results"
          class="text-muted"
        >
          {gettext("No podcasts found. Try another name or paste the show's website.")}
        </p>
      </div>
      <div id="sources" phx-update="stream" class="mt-6 grid gap-4 sm:grid-cols-2">
        <article
          :for={{dom_id, source} <- @streams.sources}
          id={dom_id}
          class="rounded-control border border-accent bg-surface p-6"
        >
          <p class="text-meta text-muted">
            {if Map.has_key?(source, :entries),
              do: gettext("Ready to subscribe"),
              else: gettext("Apple Podcasts")}
          </p>
          <h3 class="mt-2 text-xl font-semibold">{source.title}</h3>
          <p :if={source[:author]} class="mt-1 text-label text-muted">
            {source.author}
          </p>
          <p class="mt-3 text-meta break-all text-muted">{source.url}</p>
          <p :if={source[:entries]} class="mt-3 text-label text-muted">
            {gettext("%{count} recent items available", count: length(source.entries))}
          </p>
          <.button
            class="mt-5"
            variant="primary"
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
    </Layouts.member>
    """
  end
end
