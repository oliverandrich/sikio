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
  alias Sikio.Playback
  alias SikioWeb.Pictures

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Library")) |> stream(:entries, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:filters, Library.normalize_filters(params)) |> reload()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply,
     push_patch(socket,
       to: params |> Library.normalize_filters() |> SikioWeb.Sidebar.library_path()
     )}
  end

  def handle_event("mark", %{"id" => id, "status" => status}, socket)
      when status in ["new", "completed"] do
    status = if status == "new", do: :new, else: :completed

    # The change is broadcast, and the broadcast reloads the list along with the sidebar.
    case Playback.mark(socket.assigns.current_account, id, status) do
      {:ok, _} ->
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("This item is no longer in your library."))}
    end
  end

  @doc "Every library event may change which items this view lists. See `SikioWeb.Sidebar`."
  def handle_library_event(_event, socket), do: {:noreply, reload(socket)}

  defp reload(socket) do
    account = socket.assigns.current_account
    filters = socket.assigns.filters
    subscriptions = socket.assigns.sidebar.sources
    entries = Library.entries(account, filters)

    socket
    |> assign(
      empty?: subscriptions == [],
      no_matches?: entries == [],
      shown: length(entries),
      total: Library.total(socket.assigns.sidebar.counts, filters),
      heading: heading(filters, subscriptions),
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
      do: [{source_title([], selected), selected} | options],
      else: options
  end

  # The view's name: the source when one is chosen, otherwise the status.
  defp heading(%{"source" => source}, subscriptions) when source != "",
    do: source_title(subscriptions, source)

  defp heading(%{"status" => status}, _subscriptions),
    do: Enum.find_value(views(), fn {value, _key, label} -> value == status && label end)

  defp source_title(subscriptions, source) do
    Enum.find_value(subscriptions, gettext("Unavailable source"), fn subscription ->
      to_string(subscription.feed_id) == source && subscription.feed.title
    end)
  end

  defp count_label(shown, total) when shown < total,
    do: gettext("%{shown} of %{total} items", shown: shown, total: total)

  defp count_label(_shown, total), do: ngettext("%{count} item", "%{count} items", total)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      filters={@filters}
      patch
    >
      <div class="max-w-3xl">
        <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-baseline gap-3">
            <h1 id="library-heading" class="text-title font-semibold">{@heading}</h1>
            <span :if={!@empty?} id="library-count" class="text-meta text-muted">
              {count_label(@shown, @total)}
            </span>
          </div>
          <.button id="add-subscription" class="lg:hidden" navigate={~p"/subscriptions"}>
            <Lucideicons.plus aria-hidden="true" class="size-4" />
            {gettext("Add a source")}
          </.button>
        </div>
        <.form
          for={@filter_form}
          id="library-filters"
          phx-change="filter"
          phx-submit="filter"
          class="mb-4 grid gap-3 rounded-control border border-line bg-surface p-4 sm:grid-cols-3 lg:hidden"
        >
          <label
            :for={
              {key, label, options} <- [
                {"source", gettext("Source"), [{gettext("All sources"), ""} | @sources]},
                {"kind", gettext("Media type"),
                 [
                   {gettext("All media"), ""},
                   {gettext("Video"), "video"},
                   {gettext("Audio"), "audio"}
                 ]},
                {"status", gettext("Status"),
                 for({value, _key, label} <- views(), do: {label, value})}
              ]
            }
            class="min-w-0 text-label font-semibold"
          >
            <span class="mb-1 block">{label}</span>
            <select
              id={"filter-#{key}"}
              name={@filter_form[key].name}
              class="w-full rounded-control border border-control bg-surface px-3 py-2 font-normal text-ink"
            >
              {Phoenix.HTML.Form.options_for_select(options, @filter_form[key].value)}
            </select>
          </label>
          <.link
            :if={@filters_active?}
            id="clear-filters"
            patch={~p"/"}
            class="text-label font-semibold text-accent sm:col-span-3"
          >{gettext("Clear filters")}</.link>
        </.form>
        <section
          :if={@empty?}
          id="library-empty"
          class="rounded-control border border-line bg-surface p-8"
        >
          <h2 class="text-title font-semibold">{gettext("Space for something good.")}</h2>
          <p class="mt-2 max-w-lg text-muted">
            {gettext(
              "Paste a YouTube channel, a video or a podcast website. Or find your next listen in Apple Podcasts."
            )}
          </p>
          <.button class="mt-5" variant="primary" navigate={~p"/subscriptions"}>
            {gettext("Find your first source →")}
          </.button>
        </section>
        <p
          :if={!@empty? and @no_matches?}
          id="library-no-matches"
          role="status"
          class="rounded-control border border-line bg-surface p-6 text-muted"
        >
          {gettext("No items match this view. Try another filter, or wait for new episodes.")}
        </p>
        <div
          :if={!@empty?}
          id="entries"
          phx-update="stream"
          class="overflow-hidden rounded-control border border-line bg-surface empty:hidden"
        >
          <.entry_row :for={{dom_id, entry} <- @streams.entries} id={dom_id} entry={entry} />
        </div>
      </div>
    </Layouts.member>
    """
  end

  # One item: its picture, source, title and where the reader stands. The picture comes through
  # Sikio's own host and tries the item's picture, its source's artwork, then a mark for its kind,
  # so every row keeps its shape.
  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp entry_row(assigns) do
    assigns =
      assign(assigns, status: status(assigns.entry), runtime: runtime(assigns.entry.duration))

    ~H"""
    <article
      id={@id}
      data-status={@status}
      class="flex items-start gap-1 border-b border-line last:border-b-0"
    >
      <.link
        id={"play-#{@entry.id}"}
        navigate={~p"/library/#{@entry.id}"}
        class="flex min-w-0 grow gap-3 py-3 pl-4 hover:bg-ground"
      >
        <span class="relative h-[54px] w-24 shrink-0 overflow-hidden rounded-md bg-line">
          <img
            src={Pictures.path(Sikio.Pictures.candidates(@entry), kind_mark(@entry))}
            alt=""
            loading="lazy"
            class="size-full object-cover"
          />
          <span
            :if={@runtime}
            id={"runtime-#{@entry.id}"}
            class="absolute right-1 bottom-1 rounded bg-black/75 px-1 text-[11px] font-semibold text-white"
          >
            {@runtime}
          </span>
        </span>
        <span class="flex min-w-0 flex-col gap-1">
          <span class="truncate text-meta font-semibold text-accent">{@entry.feed.title}</span>
          <span class={[
            "line-clamp-2 text-body",
            @status == :completed && "text-muted",
            @status != :completed && "font-semibold text-ink"
          ]}>
            {@entry.title}
          </span>
          <span class="flex flex-wrap items-center gap-x-2 gap-y-1 text-meta text-muted">
            <.progress :if={@status == :in_progress} entry={@entry} />
            <span :if={@status != :in_progress} class="inline-flex items-center gap-1.5">
              <span :if={@status == :new} aria-hidden="true" class="size-1.5 rounded-full bg-accent"></span>
              <Lucideicons.check :if={@status == :completed} aria-hidden="true" class="size-3.5" />
              {status_label(@entry)}
            </span>
            <span class="inline-flex items-center gap-1">
              <Lucideicons.circle_play :if={video?(@entry)} aria-hidden="true" class="size-3.5" />
              <Lucideicons.mic :if={!video?(@entry)} aria-hidden="true" class="size-3.5" />
              {kind_label(@entry)}
            </span>
            <span :if={@entry.published_at}>
              {Calendar.strftime(@entry.published_at, "%d %b %Y")}
            </span>
          </span>
        </span>
      </.link>
      <.mark_button
        :if={@status != :completed}
        id={"complete-#{@entry.id}"}
        entry={@entry}
        status="completed"
        label={mark_done_label(@entry)}
      >
        <Lucideicons.check aria-hidden="true" class="size-4" />
      </.mark_button>
      <.mark_button
        :if={@status != :new}
        id={"reset-#{@entry.id}"}
        entry={@entry}
        status="new"
        label={mark_new_label(@entry)}
      >
        <Lucideicons.rotate_ccw aria-hidden="true" class="size-4" />
      </.mark_button>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :status, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp mark_button(assigns) do
    ~H"""
    <button
      id={@id}
      phx-click="mark"
      phx-value-id={@entry.id}
      phx-value-status={@status}
      aria-label={@label}
      title={@label}
      class="m-1.5 flex size-11 shrink-0 items-center justify-center rounded-control text-muted hover:bg-ground hover:text-ink"
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # How far somebody got, as a bar when the length is known and as a time when it is not.
  attr :entry, :map, required: true

  defp progress(assigns) do
    playback = assigns.entry.playback
    duration = playback.duration || assigns.entry.duration

    percent =
      if duration && duration > 0, do: min(round(playback.position / duration * 100), 100)

    assigns = assign(assigns, percent: percent, position: playback.position)

    ~H"""
    <span class="inline-flex items-center gap-2 font-semibold text-accent">
      <span
        :if={@percent}
        role="progressbar"
        aria-label={gettext("Progress")}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={@percent}
        class="h-1 w-16 overflow-hidden rounded-full bg-line"
      >
        <span class="block h-full bg-accent" style={"width: #{@percent}%"}></span>
      </span>
      {status_label(@entry)} · {timestamp(@position)}
    </span>
    """
  end

  defp kind_mark(entry),
    do: if(video?(entry), do: ~p"/images/kind-video.svg", else: ~p"/images/kind-audio.svg")
end
