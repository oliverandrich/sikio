# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLive do
  @moduledoc """
  The personal inbox: the newest items from the sources this account subscribed to.

  The filters live in the URL, so a narrowed view survives a reload and the browser's back button.
  Everything on the page is kept current from notifications rather than by polling: new episodes,
  progress from another tab, manual status changes and subscriptions added or removed elsewhere.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents

  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Playback

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe(socket.assigns.current_account)
      Events.subscribe_updates(socket.assigns.current_account)
    end

    {:ok, socket |> assign(page_title: gettext("Library")) |> stream(:entries, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:filters, Library.normalize_filters(params)) |> reload()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters =
      params
      |> Library.normalize_filters()
      |> Enum.reject(fn {_, value} -> value == "" end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/?#{filters}")}
  end

  def handle_event("mark", %{"id" => id, "status" => status}, socket)
      when status in ["new", "completed"] do
    status = if status == "new", do: :new, else: :completed

    case Playback.mark(socket.assigns.current_account, id, status) do
      {:ok, _} ->
        {:noreply, reload(socket)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("This item is no longer in your library."))}
    end
  end

  @impl true
  def handle_info({:playback_changed, _state}, socket), do: {:noreply, reload(socket)}
  def handle_info({:subscription_removed, _feed_id}, socket), do: {:noreply, reload(socket)}
  def handle_info(:library_changed, socket), do: {:noreply, reload(socket)}

  defp reload(socket) do
    account = socket.assigns.current_account
    filters = socket.assigns.filters
    subscriptions = Library.subscriptions(account)
    entries = Library.entries(account, filters)

    socket
    |> assign(
      empty?: subscriptions == [],
      no_matches?: entries == [],
      filters_active?: Enum.any?(filters, fn {_, value} -> value != "" end),
      filter_form: to_form(filters, as: :filters),
      sources: source_options(subscriptions, filters["source"])
    )
    |> stream(:entries, entries, reset: true)
  end

  # A source that was filtered on and has since been removed keeps a place in the list, so the
  # select still shows what is being filtered by rather than silently jumping to another source.
  defp source_options(subscriptions, selected) do
    options = subscriptions |> Enum.map(&{&1.feed.title, to_string(&1.feed_id)}) |> Enum.sort()

    if selected != "" and not Enum.any?(options, fn {_, id} -> id == selected end),
      do: [{gettext("Unavailable source"), selected} | options],
      else: options
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member flash={@flash} current_account={@current_account}>
      <p class="mb-5 text-xs font-semibold tracking-widest text-teal-800 uppercase dark:text-teal-300">
        {gettext("The personal library of %{username}", username: @current_account.username)}
      </p>
      <div class="flex flex-wrap items-end justify-between gap-6">
        <.header>
          {gettext("Your time.")}<br />{gettext("Your queue.")}
          <:subtitle>
            {gettext("The latest videos and episodes from the sources you chose.")}
          </:subtitle>
        </.header>
        <.button id="add-subscription" variant="primary" navigate={~p"/subscriptions"}>
          <Lucideicons.plus aria-hidden="true" class="size-4" />
          {gettext("Add a source")}
        </.button>
      </div>
      <.form
        for={@filter_form}
        id="library-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mt-10 grid gap-4 rounded-2xl border border-stone-200 bg-white p-5 sm:grid-cols-3 dark:border-stone-800 dark:bg-stone-900"
      >
        <label
          :for={
            {key, label, options} <- [
              {"source", gettext("Source"), [{gettext("All sources"), ""} | @sources]},
              {"kind", gettext("Media type"),
               [
                 {gettext("All media"), ""},
                 {gettext("YouTube"), "youtube"},
                 {gettext("Podcasts"), "podcast"}
               ]},
              {"status", gettext("Status"),
               [
                 {gettext("All statuses"), ""},
                 {gettext("New"), "new"},
                 {gettext("In progress"), "in_progress"},
                 {gettext("Completed"), "completed"}
               ]}
            ]
          }
          class="min-w-0 text-sm font-medium"
        >
          <span class="mb-2 block">{label}</span>
          <select
            id={"filter-#{key}"}
            name={@filter_form[key].name}
            class="w-full rounded-xl border border-stone-300 bg-white px-3 py-3 dark:border-stone-700 dark:bg-stone-800"
          >
            {Phoenix.HTML.Form.options_for_select(options, @filter_form[key].value)}
          </select>
        </label>
        <.link
          :if={@filters_active?}
          id="clear-filters"
          patch={~p"/"}
          class="text-sm font-semibold text-teal-800 sm:col-span-3 dark:text-teal-300"
        >{gettext("Clear filters")}</.link>
      </.form>
      <section
        :if={@empty?}
        id="library-empty"
        class="mt-14 rounded-3xl border border-stone-200 bg-white p-8 sm:p-14 dark:border-stone-800 dark:bg-stone-900"
      >
        <span class="mb-6 inline-flex size-14 items-center justify-center rounded-2xl bg-teal-50 text-teal-800 dark:bg-teal-950 dark:text-teal-300">
          <Lucideicons.circle_play aria-hidden="true" class="size-7" />
        </span>
        <h2 class="font-display text-3xl">{gettext("Space for something good.")}</h2>
        <p class="mt-4 max-w-lg leading-relaxed text-stone-600 dark:text-stone-300">
          {gettext(
            "Paste a YouTube channel, a video or a podcast website. Or find your next listen in Apple Podcasts."
          )}
        </p>
        <.link
          navigate={~p"/subscriptions"}
          class="mt-6 inline-block text-sm font-semibold text-teal-800 dark:text-teal-300"
        >{gettext("Find your first source →")}</.link>
      </section>
      <section :if={!@empty?} class="mt-12">
        <div class="mb-6 flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="font-display text-3xl">{gettext("Fresh from your feeds")}</h2>
          <p class="text-xs text-stone-500 dark:text-stone-400">
            {gettext("Up to 100 matching items · Updates live")}
          </p>
        </div>
        <p
          :if={@no_matches?}
          id="library-no-matches"
          role="status"
          class="mb-6 rounded-2xl border border-stone-200 bg-white p-8 text-stone-600 dark:border-stone-800 dark:bg-stone-900 dark:text-stone-300"
        >
          {gettext("No items match this view. Try another filter, or wait for new episodes.")}
        </p>
        <div id="entries" phx-update="stream" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <article
            :for={{dom_id, entry} <- @streams.entries}
            id={dom_id}
            class="flex flex-col rounded-2xl border border-stone-200 bg-white p-6 dark:border-stone-800 dark:bg-stone-900"
          >
            <span class="mb-5 flex size-10 items-center justify-center rounded-xl bg-teal-50 text-teal-800 dark:bg-teal-950 dark:text-teal-300">
              <Lucideicons.circle_play :if={video?(entry)} aria-hidden="true" class="size-5" />
              <Lucideicons.mic :if={!video?(entry)} aria-hidden="true" class="size-5" />
            </span>
            <p class="text-xs font-medium text-teal-800 dark:text-teal-300">{entry.feed.title}</p>
            <h3 class="mt-2 grow text-lg leading-snug font-semibold">{entry.title}</h3>
            <p class="mt-5 text-xs text-stone-500 dark:text-stone-400">
              {kind_label(entry)}
              <span :if={entry.published_at}>
                · {Calendar.strftime(entry.published_at, "%d %b %Y")}
              </span>
            </p>
            <p class="mt-3 text-xs font-semibold text-teal-800 dark:text-teal-300">
              {status_label(entry)}
              <span :if={status(entry) == :in_progress}>
                · {timestamp(entry.playback.position)}
              </span>
            </p>
            <div class="mt-5 flex flex-wrap items-center gap-4 border-t border-stone-100 pt-4 dark:border-stone-800">
              <.link
                id={"play-#{entry.id}"}
                navigate={~p"/library/#{entry.id}"}
                class="font-semibold text-teal-800 dark:text-teal-300"
              >{play_label(entry)} →</.link>
              <button
                :if={status(entry) != :completed}
                id={"complete-#{entry.id}"}
                phx-click="mark"
                phx-value-id={entry.id}
                phx-value-status="completed"
                class="min-h-11 text-xs text-stone-600 dark:text-stone-300"
              >
                {mark_done_label(entry)}
              </button>
              <button
                :if={status(entry) != :new}
                id={"reset-#{entry.id}"}
                phx-click="mark"
                phx-value-id={entry.id}
                phx-value-status="new"
                class="min-h-11 text-xs text-stone-600 dark:text-stone-300"
              >
                {mark_new_label(entry)}
              </button>
            </div>
          </article>
        </div>
      </section>
    </Layouts.member>
    """
  end
end
