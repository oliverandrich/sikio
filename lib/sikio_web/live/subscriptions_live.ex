# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionsLive do
  @moduledoc """
  Turns a pasted link or a search into a source somebody can look at before subscribing.

  An instance whose videos this account may now be shown has to reach the content security
  policy before one of them is played, and that policy is written on a document. Subscribing to
  one therefore asks for a page rather than patching this one.

  Nothing subscribes straight from an address. Discovery runs in the background, the result is
  shown with its title and how many items it carries, and only then is there a button. The
  candidates are held server-side under generated ids, so a forged id from the browser selects
  nothing.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents, only: [source_label: 1]

  alias Sikio.Feeds.Discovery
  alias Sikio.Library

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Subscriptions"),
       url_form: to_form(%{"url" => ""}),
       search_form: to_form(%{"term" => ""}),
       candidates: %{},
       busy: false,
       error: nil,
       searched: false
     )
     |> stream_configure(:sources, dom_id: &"source-#{&1.id}")
     |> stream_configure(:subscriptions, dom_id: &"subscription-#{&1.id}")
     |> stream(:sources, [])
     |> load_subscriptions()}
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

  def handle_event("pause", %{"id" => id, "paused" => paused}, socket) do
    case Library.pause(socket.assigns.current_account, id, paused == "true") do
      {:ok, _} -> {:noreply, load_subscriptions(socket)}
      _ -> {:noreply, put_flash(socket, :error, gettext("Subscription not found."))}
    end
  end

  def handle_event("unsubscribe", %{"id" => id}, socket) do
    case Library.unsubscribe(socket.assigns.current_account, id) do
      {:ok, _} -> {:noreply, load_subscriptions(socket)}
      _ -> {:noreply, put_flash(socket, :error, gettext("Subscription not found."))}
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
      {:ok, _} ->
        socket =
          socket
          |> put_flash(:info, gettext("Subscribed to %{title}.", title: preview.title))
          |> assign(candidates: %{}, searched: false)
          |> stream(:sources, [], reset: true)
          |> load_subscriptions()

        if Library.player_origins(account) == framed,
          do: {:noreply, socket},
          else: {:noreply, redirect(socket, to: ~p"/subscriptions")}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not save this subscription. Please try again.")
         )}
    end
  end

  defp load_subscriptions(socket) do
    subscriptions = Library.subscriptions(socket.assigns.current_account)

    socket
    |> assign(subscription_count: length(subscriptions))
    |> stream(:subscriptions, subscriptions, reset: true)
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
    <Layouts.member flash={@flash} current_account={@current_account} sidebar={@sidebar}>
      <p class="mb-4 text-xs font-semibold tracking-widest text-teal-800 uppercase dark:text-teal-300">
        {gettext("Curated by you")}
      </p>
      <.header>
        {gettext("Make room for the good stuff.")}
        <:subtitle>
          {gettext("A channel, a video, a podcast website. Paste a link and let Sikio find the feed.")}
        </:subtitle>
      </.header>
      <div class="mt-6 flex flex-wrap gap-5 text-sm font-semibold text-teal-800 dark:text-teal-300">
        <.link
          id="opml-import-link"
          navigate={~p"/subscriptions/import"}
          class="inline-flex min-h-11 items-center"
        >{gettext("Import OPML")}</.link>
        <.link
          id="opml-export-link"
          href={~p"/subscriptions.opml"}
          class="inline-flex min-h-11 items-center gap-1"
        >
          {gettext("Export OPML")}
          <Lucideicons.download aria-hidden="true" class="size-4" />
        </.link>
      </div>
      <div class="mt-10 grid gap-6 lg:grid-cols-2">
        <section class="rounded-3xl border border-stone-200 bg-white p-6 sm:p-8 dark:border-stone-800 dark:bg-stone-900">
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
          <p class="mt-5 text-xs leading-relaxed text-stone-500 dark:text-stone-400">
            {gettext(
              "YouTube channels, videos and Shorts · Podcast websites, RSS feeds and Apple Podcasts links"
            )}
          </p>
        </section>
        <section class="rounded-3xl border border-stone-200 bg-stone-100 p-6 sm:p-8 dark:border-stone-800 dark:bg-stone-800">
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
          <p class="mt-5 text-xs leading-relaxed text-stone-500 dark:text-stone-400">
            {gettext(
              "Searches Apple's German directory. Results are provided by Apple; subscriptions use the show's own RSS feed."
            )}
          </p>
        </section>
      </div>
      <div aria-live="polite" class="mt-6">
        <p :if={@busy} id="discovery-loading" class="text-sm text-teal-800 dark:text-teal-300">
          {gettext("Looking for your next good listen or watch…")}
        </p>
        <p
          :if={@error}
          id="discovery-error"
          role="alert"
          class="rounded-xl bg-red-50 p-4 text-sm text-red-900 dark:bg-red-950 dark:text-red-100"
        >
          {@error}
        </p>
        <p
          :if={@searched and map_size(@candidates) == 0}
          id="no-results"
          class="text-stone-500 dark:text-stone-400"
        >
          {gettext("No podcasts found. Try another name or paste the show's website.")}
        </p>
      </div>
      <div id="sources" phx-update="stream" class="mt-6 grid gap-4 sm:grid-cols-2">
        <article
          :for={{dom_id, source} <- @streams.sources}
          id={dom_id}
          class="rounded-2xl border border-teal-200 bg-white p-6 dark:border-teal-900 dark:bg-stone-900"
        >
          <p class="text-xs text-teal-800 dark:text-teal-300">
            {if Map.has_key?(source, :entries),
              do: gettext("Ready to subscribe"),
              else: gettext("Apple Podcasts")}
          </p>
          <h3 class="mt-2 text-xl font-semibold">{source.title}</h3>
          <p :if={source[:author]} class="mt-1 text-sm text-stone-500 dark:text-stone-400">
            {source.author}
          </p>
          <p class="mt-3 text-xs break-all text-stone-500 dark:text-stone-400">{source.url}</p>
          <p :if={source[:entries]} class="mt-3 text-sm text-stone-600 dark:text-stone-300">
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
      <section class="mt-14">
        <div class="mb-6 flex items-baseline justify-between gap-4">
          <h2 class="font-display text-3xl">{gettext("Your subscriptions")}</h2>
          <span class="text-sm text-stone-500 dark:text-stone-400">
            {gettext("%{count} sources", count: @subscription_count)}
          </span>
        </div>
        <p
          :if={@subscription_count == 0}
          id="subscriptions-empty"
          class="rounded-2xl border border-dashed border-stone-300 p-8 text-stone-500 dark:border-stone-700 dark:text-stone-400"
        >
          {gettext("Your collection starts with one good source.")}
        </p>
        <div id="subscriptions" phx-update="stream" class="space-y-3">
          <article
            :for={{dom_id, subscription} <- @streams.subscriptions}
            id={dom_id}
            class="flex flex-wrap items-center justify-between gap-5 rounded-2xl border border-stone-200 bg-white p-6 dark:border-stone-800 dark:bg-stone-900"
          >
            <div class="min-w-0 flex-1">
              <p class="text-xs font-medium text-teal-800 dark:text-teal-300">
                {source_label(subscription.feed)} · {if subscription.paused,
                  do: gettext("Polling paused"),
                  else: gettext("Active")}
              </p>
              <h3 class="mt-1 text-lg font-semibold">{subscription.feed.title}</h3>
              <p class="mt-2 text-xs break-all text-stone-500 dark:text-stone-400">
                {subscription.feed.url}
              </p>
              <p
                :if={subscription.feed.last_error}
                class="mt-2 text-sm text-orange-800 dark:text-orange-300"
              >
                {gettext("Last refresh failed. Sikio will retry; imported items are safe.")}
              </p>
            </div>
            <div class="flex gap-5 text-sm">
              <button
                phx-click="pause"
                phx-value-id={subscription.id}
                phx-value-paused={to_string(!subscription.paused)}
                class="min-h-11 text-teal-800 dark:text-teal-300"
              >{if subscription.paused, do: gettext("Resume"), else: gettext("Pause polling")}</button>
              <button
                phx-click="unsubscribe"
                phx-value-id={subscription.id}
                class="min-h-11 text-stone-500 dark:text-stone-400"
              >{gettext("Unsubscribe")}</button>
            </div>
          </article>
        </div>
        <p class="mt-5 text-xs text-stone-500 dark:text-stone-400">
          {gettext(
            "Active sources refresh every 15 minutes. A shared feed may still update for other subscribers while your polling is paused."
          )}
        </p>
      </section>
    </Layouts.member>
    """
  end
end
