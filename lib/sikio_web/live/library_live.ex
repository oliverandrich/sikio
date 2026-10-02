# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLive do
  @moduledoc """
  The personal inbox: the newest items from the sources this account subscribed to.

  The filters live in the URL, so a narrowed view survives a reload and the browser's back button.
  Selecting an item patches the address to `/library/:id` and keeps the list standing: from `lg`
  the item shows in a column beside the list, below it on its own.
  Everything on the page is kept current from notifications rather than by polling: new episodes,
  progress from another tab, manual status changes and subscriptions added or removed elsewhere.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents

  alias Sikio.Library
  alias Sikio.Playback
  alias SikioWeb.Notes
  alias SikioWeb.Pictures

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, selected: nil, notes: nil, filters: nil, entries: [])}
  end

  # The list is read again only when the filters change. The rows are keyed, so choosing another
  # item sends only the two rows whose selection changed and the list stands.
  @impl true
  def handle_params(params, _uri, socket) do
    filters = Library.normalize_filters(params)
    place = SikioWeb.Sidebar.place(filters)

    if place == filters,
      do: show(params, filters, socket),
      else:
        {:noreply,
         push_patch(socket, to: SikioWeb.Sidebar.library_path(place, params["id"]), replace: true)}
  end

  defp show(params, filters, socket) do
    socket =
      if filters == socket.assigns.filters,
        do: socket,
        else: socket |> assign(:filters, filters) |> reload()

    case select(socket, params["id"]) do
      {:ok, socket} -> {:noreply, socket}
      :error -> {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("move", %{"key" => key}, socket) when key in ["j", "k"] do
    ids = Enum.map(socket.assigns.entries, & &1.id)
    current = socket.assigns.selected && Enum.find_index(ids, &(&1 == socket.assigns.selected.id))

    next =
      case {key, current} do
        {"j", nil} -> List.first(ids)
        {"k", nil} -> nil
        {"j", index} -> Enum.at(ids, index + 1)
        {"k", 0} -> nil
        {"k", index} -> Enum.at(ids, index - 1)
      end

    if next,
      do:
        {:noreply,
         push_patch(socket, to: SikioWeb.Sidebar.library_path(socket.assigns.filters, next))},
      else: {:noreply, socket}
  end

  def handle_event("move", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_mark", _params, %{assigns: %{selected: nil}} = socket),
    do: {:noreply, socket}

  # The status is read again rather than taken from the selection, which the mark's broadcast
  # only updates after a second press may already have arrived.
  def handle_event("toggle_mark", _params, %{assigns: %{selected: selected}} = socket) do
    case Library.entry(socket.assigns.current_account, selected.id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("This item is no longer in your library."))}

      entry ->
        status = if status(entry) == :completed, do: "new", else: "completed"
        handle_event("mark", %{"id" => entry.id, "status" => status}, socket)
    end
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

  @doc """
  Answers the library's events, which arrive through `SikioWeb.Sidebar`.

  A progress sample that keeps the status updates the one item in place. Anything else may change
  which items this view lists, so the list is read again and the selected item with it; an item
  that left the library closes.
  """
  # Progress cannot move an item between views, since filters look at the status, the kind and
  # the source. The one item takes the new place; nothing is read again.
  def handle_library_event({:playback_progressed, state}, socket) do
    {:noreply,
     socket
     |> update(:entries, fn entries -> Enum.map(entries, &progressed(&1, state)) end)
     |> update(:selected, &(&1 && progressed(&1, state)))}
  end

  def handle_library_event(_event, %{assigns: %{selected: nil}} = socket),
    do: {:noreply, reload(socket)}

  def handle_library_event(_event, socket) do
    socket = reload(socket)

    case select(socket, socket.assigns.selected.id) do
      {:ok, socket} ->
        {:noreply, socket}

      :error ->
        {:noreply, push_patch(socket, to: SikioWeb.Sidebar.library_path(socket.assigns.filters))}
    end
  end

  # A notification older than what is shown is dropped, so a late one cannot undo a mark.
  defp progressed(entry, state) do
    if entry.id == state.entry_id and Playback.newer?(entry, state),
      do: %{entry | playback: state},
      else: entry
  end

  defp select(socket, nil),
    do: {:ok, assign(socket, selected: nil, page_title: gettext("Library"))}

  defp select(socket, id) do
    case Library.entry(socket.assigns.current_account, id) do
      nil ->
        :error

      entry ->
        {:ok,
         assign(socket, selected: entry, page_title: entry.title, notes: notes(socket, entry))}
    end
  end

  # Filtering notes is the costly part of the detail, and an event rereads the same item several
  # times a minute while it plays. The notes are filtered again only when they changed.
  defp notes(%{assigns: %{selected: %{id: id, description: description}, notes: notes}}, %{
         id: id,
         description: description
       }),
       do: notes

  defp notes(_socket, entry),
    do: Notes.notes(entry.description, entry.description_format || :html)

  defp reload(socket) do
    account = socket.assigns.current_account
    filters = socket.assigns.filters
    subscriptions = socket.assigns.sidebar.sources
    entries = Library.entries(account, filters)
    # The sidebar and the chips count each place on its own; the heading counts what is shown.
    counts = Library.tally(socket.assigns.sidebar.counts, %{})

    socket
    |> assign(
      empty?: subscriptions == [],
      no_matches?: entries == [],
      entries: entries,
      shown: length(entries),
      counts: counts,
      total: socket.assigns.sidebar.counts |> Library.tally(filters) |> Library.total(filters),
      heading: heading(filters, subscriptions)
    )
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
      counts={@counts}
      patch
      bleed
      section={:library}
    >
      <div
        id="library"
        phx-hook="ReaderKeys"
        class="lg:grid lg:min-h-svh lg:grid-cols-[28rem_minmax(0,1fr)] lg:items-start"
      >
        <div class={[
          "min-w-0 lg:min-h-svh lg:self-stretch lg:border-r lg:border-line lg:bg-surface",
          @selected && "hidden lg:block"
        ]}>
          <div class="flex flex-wrap items-center justify-between gap-3 px-6 pt-6 pb-4 sm:px-12 lg:border-b lg:border-line lg:px-4 lg:pt-5 lg:pb-4">
            <div class="flex flex-col gap-0.5">
              <h1 id="library-heading" class="text-title font-semibold">{@heading}</h1>
              <span :if={!@empty?} id="library-count" class="font-mono text-meta text-muted">
                {count_label(@shown, @total)}
              </span>
            </div>
            <p
              :if={!@empty? and !@no_matches?}
              class="hidden items-center gap-1 text-meta text-muted lg:flex"
            >
              <kbd class={kbd_class()}>j</kbd>
              <kbd class={kbd_class()}>k</kbd>
              <span class="ml-0.5">{gettext("to browse")}</span>
              <kbd class={["ml-2", kbd_class()]}>m</kbd>
              <span class="ml-0.5">{gettext("to mark")}</span>
            </p>
            <.button id="add-subscription" class="lg:hidden" navigate={~p"/subscriptions"}>
              <Lucideicons.plus aria-hidden="true" class="size-4" />
              {gettext("Add a source")}
            </.button>
          </div>
          <nav
            id="library-chips"
            aria-label={gettext("Views")}
            class="mb-3 flex gap-2 overflow-x-auto px-6 pb-1 sm:px-12 lg:hidden"
          >
            <.chip
              :for={{status, key, label} <- views()}
              id={"chip-view-#{key}"}
              to={SikioWeb.Sidebar.place_path("status", status)}
              active={SikioWeb.Sidebar.place?(@filters, "status", status)}
              count={@counts[key]}
            >
              {label}
            </.chip>
          </nav>
          <details
            :if={@sidebar.sources != [] or @filters["source"] != ""}
            id="chip-sources"
            open={@filters["source"] != ""}
            class="mb-4 px-6 sm:px-12 lg:hidden"
          >
            <summary class="inline-flex min-h-9 cursor-pointer list-none items-center gap-1.5 rounded-full border border-line bg-surface px-3 text-label font-semibold text-ink">
              {if @filters["source"] != "", do: @heading, else: gettext("Sources")}
              <Lucideicons.chevron_down aria-hidden="true" class="size-3.5" />
            </summary>
            <div class="mt-2 flex flex-wrap gap-2">
              <.chip
                :for={source <- @sidebar.sources}
                id={"chip-source-#{source.feed_id}"}
                to={SikioWeb.Sidebar.place_path("source", to_string(source.feed_id))}
                active={SikioWeb.Sidebar.place?(@filters, "source", to_string(source.feed_id))}
                count={Map.get(@counts.sources, source.feed_id, 0)}
              >
                {source.feed.title}
              </.chip>
            </div>
          </details>
          <section
            :if={@empty?}
            id="library-empty"
            class="mx-6 rounded-2xl bg-surface p-8 shadow-sm ring-1 ring-line sm:mx-12 lg:m-4"
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
            class="px-6 py-6 text-muted sm:px-12 lg:px-4"
          >
            {gettext("No items match this view. Try another filter, or wait for new episodes.")}
          </p>
          <div
            :if={!@empty?}
            id="entries"
            class="border-t border-line bg-surface empty:hidden lg:border-t-0"
          >
            <.entry_row
              :for={entry <- @entries}
              :key={entry.id}
              id={"entries-#{entry.id}"}
              entry={entry}
              to={SikioWeb.Sidebar.library_path(@filters, entry.id)}
              selected={@selected && @selected.id == entry.id}
            />
          </div>
        </div>
        <section
          id="item-detail"
          data-entry-id={@selected && @selected.id}
          aria-label={gettext("Selected item")}
          class={[
            "min-w-0 px-6 py-6 sm:px-12 lg:sticky lg:top-0 lg:px-7 lg:pt-(--dock-inset) lg:pb-6",
            !@selected && "hidden lg:block"
          ]}
        >
          <.detail
            :if={@selected}
            entry={@selected}
            notes={@notes}
            back={SikioWeb.Sidebar.library_path(@filters)}
          />
          <p :if={!@selected} class="rounded-2xl border border-dashed border-line p-8 text-muted">
            {gettext("Choose an item to see it here. j and k move through the list.")}
          </p>
        </section>
      </div>
    </Layouts.member>
    """
  end

  # One item: its picture, source, title and where the reader stands. The picture comes through
  # Sikio's own host and tries the item's picture, its source's artwork, then a mark for its kind,
  # so every row keeps its shape.
  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :to, :string, required: true
  attr :selected, :boolean, required: true

  defp entry_row(assigns) do
    assigns =
      assign(assigns, status: status(assigns.entry), runtime: runtime(length_of(assigns.entry)))

    ~H"""
    <article
      id={@id}
      data-status={@status}
      class={[
        "border-b border-line last:border-b-0 lg:last:border-b",
        @selected && "bg-selection shadow-[inset_3px_0_0_var(--color-accent)]"
      ]}
    >
      <.link
        id={"play-#{@entry.id}"}
        patch={@to}
        aria-current={@selected && "true"}
        class={[
          "flex min-w-0 gap-3 px-6 py-3 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent sm:px-12 lg:px-4",
          !@selected && "hover:bg-ground/50"
        ]}
      >
        <span class="relative h-21 w-28 shrink-0 overflow-hidden rounded-lg bg-line">
          <img
            src={Pictures.path(Sikio.Pictures.candidates(@entry), kind_mark(@entry))}
            alt=""
            loading="lazy"
            class="size-full object-cover"
          />
          <span
            :if={@runtime}
            id={"runtime-#{@entry.id}"}
            class="absolute right-1 bottom-2 rounded bg-black/75 px-1 font-mono text-[11px] font-medium text-white"
          >
            {@runtime}
          </span>
          <.progress :if={@status == :in_progress} entry={@entry} />
        </span>
        <span class="flex min-w-0 grow flex-col gap-1">
          <span class="truncate text-meta font-semibold text-accent">{@entry.feed.title}</span>
          <span class={[
            "mb-auto line-clamp-2 text-body",
            @status == :completed && "text-muted",
            @status != :completed && "font-semibold text-ink"
          ]}>
            {@entry.title}
          </span>
          <span class="flex flex-wrap items-center gap-x-1.5 text-meta text-muted">
            <span
              :if={@status == :in_progress}
              class="font-mono font-medium text-signal-strong"
            >
              {time_left(@entry)}
            </span>
            <span :if={@status != :in_progress} class="inline-flex items-center gap-1.5">
              <span :if={@status == :new} aria-hidden="true" class="size-1.5 rounded-full bg-signal"></span>
              <Lucideicons.check :if={@status == :completed} aria-hidden="true" class="size-3.5" />
              {status_label(@entry)}
            </span>
            <span aria-hidden="true">·</span>
            <span>{medium_label(@entry)}</span>
            <span :if={@entry.published_at} aria-hidden="true">·</span>
            <span :if={@entry.published_at} class="font-mono">{short_date(@entry.published_at)}</span>
          </span>
        </span>
      </.link>
    </article>
    """
  end

  # One choice in the phone's chip row: the same addresses and counts as the sidebar.
  attr :id, :string, required: true
  attr :to, :string, required: true
  attr :active, :boolean, default: false
  attr :count, :integer, default: 0
  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@to}
      aria-current={@active && "page"}
      class={[
        "inline-flex min-h-9 shrink-0 items-center gap-1.5 rounded-full border border-line bg-surface px-3 text-label font-semibold whitespace-nowrap text-ink",
        "aria-[current=page]:border-ink aria-[current=page]:bg-ink aria-[current=page]:text-surface"
      ]}
    >
      {render_slot(@inner_block)}
      <span :if={@count > 0} class="font-mono text-meta font-normal opacity-70">{@count}</span>
    </.link>
    """
  end

  # How far somebody got, as a bar along the foot of the picture when the length is known.
  attr :entry, :map, required: true

  defp progress(assigns) do
    assigns = assign(assigns, :percent, percent(assigns.entry))

    ~H"""
    <span
      :if={@percent}
      role="progressbar"
      aria-label={gettext("Progress")}
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@percent}
      class="absolute inset-x-0 bottom-0 h-1 bg-black/40"
    >
      <span class="block h-full bg-signal" style={"width: #{@percent}%"}></span>
    </span>
    """
  end

  defp percent(%{playback: playback} = entry) do
    duration = length_of(entry)
    if duration && duration > 0, do: min(round(playback.position / duration * 100), 100)
  end

  # The length the player measured, or else the one the feed stated. YouTube's feed states none,
  # so a video has a length only once this account has played it.
  defp length_of(%{playback: %{duration: duration}}) when is_number(duration), do: duration
  defp length_of(entry), do: entry.duration

  # What is left to hear or watch, in whole minutes. Without a length, or past it, the status says it.
  defp time_left(%{playback: playback} = entry) do
    duration = length_of(entry)

    if duration && duration > playback.position,
      do:
        gettext("%{minutes} min left",
          minutes: max(round((duration - playback.position) / 60), 1)
        ),
      else: status_label(entry)
  end

  # The selected item: what it is, where the reader stands, and the way to play it. Playing
  # happens in the dock, which this asks through a browser event so the media never moves.
  attr :entry, :map, required: true
  attr :notes, :any, required: true, doc: "the filtered notes, or nil"
  attr :back, :string, required: true

  defp detail(assigns) do
    entry = assigns.entry

    assigns =
      assign(assigns,
        status: status(entry),
        runtime: runtime(length_of(entry))
      )

    ~H"""
    <.link patch={@back} class="mb-4 inline-block text-label font-semibold text-accent lg:hidden">
      {gettext("← Your library")}
    </.link>
    <article
      data-dock-anchor
      class="flex flex-col gap-4 rounded-2xl bg-surface p-6 shadow-sm ring-1 ring-line"
    >
      <div class="flex items-center gap-3">
        <span
          aria-hidden="true"
          class="flex size-8 shrink-0 items-center justify-center rounded-full bg-accent/15 text-meta font-semibold text-accent"
        >
          {initial(@entry.feed.title)}
        </span>
        <div class="flex min-w-0 flex-col">
          <p class="truncate text-label font-semibold text-accent">{@entry.feed.title}</p>
          <p id="playback-status" aria-live="polite" class="text-meta text-muted">
            {kind_label(@entry)}
            <span :if={@entry.published_at}>
              · <span class="font-mono">{date(@entry.published_at)}</span>
            </span>
            <span :if={@runtime}>· <span class="font-mono">{@runtime}</span></span>
            · {status_label(@entry)}
            <span :if={@entry.playback && @entry.playback.position > 0}>
              · {gettext("Saved at")}
              <span class="font-mono">{timestamp(@entry.playback.position)}</span>
            </span>
          </p>
        </div>
      </div>
      <h2 class="text-title font-semibold">{@entry.title}</h2>
      <div class="flex flex-wrap items-center gap-3">
        <.button
          id="start-playback"
          variant="primary"
          phx-click={JS.dispatch("sikio:play", detail: %{id: @entry.id})}
        >
          <Lucideicons.play aria-hidden="true" class="size-4 fill-current" />
          {play_label(@entry)}
        </.button>
        <.button
          :if={@status != :completed}
          id="mark-completed"
          phx-click="mark"
          phx-value-id={@entry.id}
          phx-value-status="completed"
        >
          <Lucideicons.check aria-hidden="true" class="size-4" />
          {mark_done_label(@entry)}
        </.button>
        <.button
          :if={@status != :new}
          id="mark-new"
          phx-click="mark"
          phx-value-id={@entry.id}
          phx-value-status="new"
        >
          <Lucideicons.rotate_ccw aria-hidden="true" class="size-4" />
          {mark_new_label(@entry)}
        </.button>
        <a
          :if={@entry.feed.kind == :youtube}
          id="open-original"
          href={"https://www.youtube.com/watch?v=#{@entry.video_id}"}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex min-h-11 items-center gap-1.5 px-2 text-label text-muted hover:text-ink"
        >
          <Lucideicons.external_link aria-hidden="true" class="size-4" />
          {gettext("Open on YouTube")}
        </a>
      </div>
      <section class="flex flex-col gap-3 border-t border-line pt-4">
        <h3 class="text-meta font-semibold tracking-wider text-muted uppercase">
          {gettext("From the feed")}
        </h3>
        <div :if={@notes} id="item-notes" class="notes max-w-prose text-body text-ink">
          {@notes}
        </div>
        <p :if={!@notes} id="item-no-notes" class="text-muted">
          {gettext("The publisher sent no notes for this item.")}
        </p>
      </section>
      <p class="text-meta text-muted">{privacy_note(@entry)}</p>
      <p class="border-t border-line pt-4 text-meta text-muted">
        {gettext(
          "Playback stays with you as you browse your library and subscriptions. Your place is saved every five seconds, on pause and after seeking. Reaching the end marks this item complete. You can always change that yourself."
        )}
      </p>
    </article>
    """
  end

  defp kbd_class,
    do:
      "inline-flex h-5 min-w-5 items-center justify-center rounded-md border border-line bg-ground px-1 font-mono text-[11px] font-medium text-ink"
end
