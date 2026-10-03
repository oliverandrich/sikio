# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLive do
  @moduledoc """
  The personal inbox: the newest items from the sources this account subscribed to.

  The list and the item shown in it live in the URL, so both survive a reload and the browser's
  back button; `SikioWeb.Sidebar.library_path/3` spells the addresses. Selecting an item patches
  the address and keeps the list standing: from `lg` the item shows in a column beside the list,
  below it on its own.
  Everything on the page is kept current from notifications rather than by polling: new episodes,
  progress from another tab, manual status changes and subscriptions added or removed elsewhere.
  """
  use SikioWeb, :live_view

  import SikioWeb.AudioFace
  import SikioWeb.MediaComponents

  alias Sikio.Chapters
  alias Sikio.Library
  alias Sikio.Playback
  alias SikioWeb.Notes
  alias SikioWeb.Pictures

  @impl true
  # Enough rows for the tallest screen, so the next batch is asked for before the list runs out.
  @batch 25

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       selected: nil,
       notes: nil,
       chapters: [],
       read: nil,
       filters: nil,
       entries: [],
       more?: false,
       search_open?: false,
       chosen_for_width: nil
     )}
  end

  # The list is read again only when the filters change. The rows are keyed, so choosing another
  # item sends only the two rows whose selection changed and the list stands.
  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    {filters, item} = SikioWeb.Sidebar.read_path(path, params)
    filters = offered(filters)
    # An address with a search shows the field, a reload or the Back button included.
    socket = assign(socket, :search_open?, socket.assigns.search_open? or filters["q"] != "")

    # Any other item than the one the page chose for a wide screen is the reader's own choice.
    socket =
      if to_string(socket.assigns.chosen_for_width) == to_string(item),
        do: socket,
        else: assign(socket, :chosen_for_width, nil)

    socket =
      if filters == socket.assigns.filters,
        do: socket,
        else: socket |> assign(filters: filters, entries: []) |> reload()

    case select(socket, item) do
      {:ok, socket} -> {:noreply, socket |> reach() |> named(path, query)}
      :error -> {:noreply, push_navigate(socket, to: address(socket, filters))}
    end
  end

  # An address names a source and an item by number; the titles after the numbers are for the
  # reader. One that reads otherwise, after a rename or typed by hand, is corrected in place.
  defp named(socket, "/", _query), do: socket

  defp named(socket, path, query) do
    canonical = address(socket, socket.assigns.filters, socket.assigns.selected)
    current = if query in [nil, ""], do: path, else: "#{path}?#{query}"

    if canonical == current,
      do: socket,
      else: push_patch(socket, to: canonical, replace: true)
  end

  # The library's address for `filters` and `item`, naming sources by their titles.
  defp address(socket, filters, item \\ nil),
    do: SikioWeb.Sidebar.library_path(filters, item, socket.assigns.sidebar.titles)

  # An item opened by its address may lie beyond the batches loaded. The list grows until it
  # shows the item, or until it has passed where the item would be, which a filtered-out item is.
  defp reach(%{assigns: %{selected: nil}} = socket), do: socket

  defp reach(%{assigns: %{selected: selected, entries: entries, more?: more?}} = socket) do
    if position(socket) || !more? || (entries != [] and !before?(List.last(entries), selected)),
      do: socket,
      else: socket |> load_more() |> reach()
  end

  # Whether `a` comes before `b` in the list: newer first, undated last, the higher id first.
  defp before?(%{published_at: nil}, %{published_at: %DateTime{}}), do: false
  defp before?(%{published_at: %DateTime{}}, %{published_at: nil}), do: true

  defp before?(a, b) do
    case a.published_at && DateTime.compare(a.published_at, b.published_at) do
      :gt -> true
      :lt -> false
      _ -> a.id > b.id
    end
  end

  @impl true
  def handle_event("move", %{"key" => key}, socket) when key in ["j", "k"] do
    current = position(socket)
    # j past the last row loaded loads the next batch first.
    socket =
      if key == "j" and current == length(socket.assigns.entries) - 1,
        do: load_more(socket),
        else: socket

    entries = socket.assigns.entries

    next =
      case {key, current} do
        {"j", nil} -> List.first(entries)
        {"k", nil} -> nil
        {"j", index} -> Enum.at(entries, index + 1)
        {"k", 0} -> nil
        {"k", index} -> Enum.at(entries, index - 1)
      end

    if next,
      do: {:noreply, push_patch(socket, to: address(socket, socket.assigns.filters, next))},
      else: {:noreply, socket}
  end

  def handle_event("move", _params, socket), do: {:noreply, socket}

  def handle_event("load_more", _params, socket), do: {:noreply, load_more(socket)}

  # The mini player's title: what plays, in the list on screen when that holds it, else in the
  # list of its source. The link's own navigation was cancelled for this, so a playing item that
  # has left the library meanwhile is said rather than left silent.
  def handle_event("show", %{"id" => id}, socket) do
    %{current_account: account, filters: filters} = socket.assigns

    case Library.entry(account, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("This item is no longer in your library."))}

      entry ->
        filters =
          if Library.listed?(account, filters, entry.id),
            do: filters,
            else: Library.normalize_filters(%{"source" => to_string(entry.feed_id)})

        {:noreply, push_patch(socket, to: address(socket, filters, entry))}
    end
  end

  # A wide screen keeps something in the detail; the browser asks when nothing is chosen. The
  # address is replaced, so Back does not return to the empty view.
  def handle_event(
        "select_first",
        _params,
        %{assigns: %{selected: nil, entries: [first | _]}} = socket
      ),
      do:
        {:noreply,
         socket
         |> assign(:chosen_for_width, first.id)
         |> push_patch(
           to: address(socket, socket.assigns.filters, first),
           replace: true
         )}

  def handle_event("select_first", _params, socket), do: {:noreply, socket}

  # Turned narrow, the detail would cover the list. An item the page chose is let go; one the
  # reader chose stays.
  def handle_event("release_first", _params, %{assigns: %{chosen_for_width: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("release_first", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:chosen_for_width, nil)
       |> push_patch(to: address(socket, socket.assigns.filters), replace: true)}

  def handle_event("search", %{"q" => text}, socket), do: {:noreply, searched(socket, text)}
  # The field is open or folded on the page's word, so a patch never folds it mid-edit. Opening
  # puts the cursor in it; folding clears the search and gives the focus back to the magnifier.
  def handle_event("open_search", _params, socket) do
    {:noreply,
     socket |> assign(:search_open?, true) |> push_event("focus", %{id: "search-input"})}
  end

  def handle_event("close_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_open?, false)
     |> push_event("focus", %{id: "toggle-search"})
     |> searched("")}
  end

  def handle_event("toggle_search", params, socket),
    do:
      handle_event(
        if(socket.assigns.search_open?, do: "close_search", else: "open_search"),
        params,
        socket
      )

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
        {:noreply, push_patch(socket, to: address(socket, socket.assigns.filters))}
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
         socket
         |> assign(reading(socket, entry))
         |> assign(selected: entry, page_title: entry.title)}
    end
  end

  # Reading the notes is the costly part of the detail, and an event rereads the same item several
  # times a minute while it plays. Chapters and notes are read again only when the notes changed.
  # The chapters a publisher listed come out of the notes, so they show once, in their own box.
  # The chapters depend on the length as well, which a player may measure only later.
  defp reading(socket, entry) do
    read = {entry.id, entry.description, length_of(entry)}

    if socket.assigns.read == read do
      Map.take(socket.assigns, [:notes, :chapters, :read])
    else
      format = entry.description_format || :html
      {chapters, rest} = Chapters.split(entry.description, format, length_of(entry))
      %{chapters: chapters, notes: Notes.notes(rest, format), read: read}
    end
  end

  # The tally counts every place without a query. A search is counted by the database.
  defp total(socket, %{"q" => ""} = filters),
    do: socket.assigns.sidebar.counts |> Library.tally(filters) |> Library.total(filters)

  defp total(socket, filters), do: Library.count(socket.assigns.current_account, filters)

  defp position(%{assigns: %{selected: nil}}), do: nil

  defp position(%{assigns: %{selected: selected, entries: entries}}),
    do: Enum.find_index(entries, &(&1.id == selected.id))

  # The list grows by a batch as its end comes into view; there are no pages to turn.
  defp load_more(%{assigns: %{more?: false}} = socket), do: socket

  defp load_more(socket) do
    %{current_account: account, filters: filters, entries: entries} = socket.assigns
    batch = Library.entries(account, filters, limit: @batch, after: List.last(entries))
    assign(socket, entries: entries ++ batch, more?: length(batch) == @batch)
  end

  # Read again after an update, as many rows as were loaded, so the list never shrinks under the
  # reader's scroll.
  defp reload(socket) do
    account = socket.assigns.current_account
    filters = socket.assigns.filters
    subscriptions = socket.assigns.sidebar.sources
    limit = max(length(socket.assigns.entries), @batch)
    entries = Library.entries(account, filters, limit: limit)
    # The sidebar and the chips count each place on its own; the heading counts what is shown.
    counts = Library.tally(socket.assigns.sidebar.counts, %{})

    socket
    |> assign(
      empty?: subscriptions == [],
      entries: entries,
      more?: length(entries) == limit,
      counts: counts,
      total: total(socket, filters),
      heading: heading(filters, subscriptions),
      filtered?: place_of(filters) != filters
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

  defp count_label(total), do: ngettext("%{count} item", "%{count} items", total)

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
        data-selected={@selected && @selected.id}
        data-rows={length(@entries)}
        class="lg:grid lg:h-svh lg:grid-cols-[28rem_minmax(0,1fr)]"
      >
        <%!-- From lg the window stands still. The list and the detail scroll on their own, and
        neither springs back at its end. Each takes the focus, so the keyboard can scroll it. --%>
        <div
          id="list-pane"
          tabindex="0"
          class={[
            "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent",
            "min-w-0 lg:h-svh lg:overflow-y-auto lg:overscroll-none lg:border-r lg:border-line lg:bg-surface",
            @selected && "hidden lg:block"
          ]}
        >
          <%!-- Heading, search and filters stay in view while the list scrolls beneath them. --%>
          <div id="list-head" class="lg:sticky lg:top-0 lg:z-10 lg:bg-surface">
            <div class="flex items-start justify-between gap-3 px-6 pt-6 pb-4 sm:px-12 lg:px-4 lg:pt-5 lg:pb-3">
              <div class="flex min-w-0 flex-col gap-0.5">
                <h1 id="library-heading" class="text-title font-semibold">{@heading}</h1>
                <span :if={!@empty?} id="library-count" class="font-mono text-meta text-muted">
                  {count_label(@total)}
                </span>
              </div>
              <div class="flex shrink-0 items-center gap-2">
                <button
                  :if={!@empty?}
                  id="toggle-search"
                  type="button"
                  aria-controls="search-form"
                  aria-expanded={to_string(@search_open?)}
                  aria-label={gettext("Search")}
                  phx-click="toggle_search"
                  class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink aria-expanded:text-accent"
                >
                  <Lucideicons.search aria-hidden="true" class="size-4.5" />
                </button>
                <.button
                  id="add-subscription"
                  class="shrink-0 lg:hidden"
                  navigate={~p"/subscriptions"}
                >
                  <Lucideicons.plus aria-hidden="true" class="size-4" />
                  {gettext("Add a source")}
                </.button>
              </div>
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
                  to={
                    SikioWeb.Sidebar.place_path("source", to_string(source.feed_id), @sidebar.titles)
                  }
                  active={SikioWeb.Sidebar.place?(@filters, "source", to_string(source.feed_id))}
                  count={Map.get(@counts.sources, source.feed_id, 0)}
                >
                  {source.feed.title}
                </.chip>
              </div>
            </details>
            <form
              :if={!@empty?}
              id="search-form"
              role="search"
              phx-change="search"
              phx-submit="search"
              hidden={!@search_open?}
              class="px-6 pb-3 sm:px-12 lg:px-4"
            >
              <input
                id="search-input"
                type="search"
                name="q"
                value={@filters["q"]}
                phx-debounce="300"
                placeholder={gettext("Search in %{place}", place: @heading)}
                aria-label={gettext("Search in %{place}", place: @heading)}
                autocomplete="off"
                class="w-full rounded-full border border-control bg-surface px-4 py-2 text-label text-ink placeholder:text-muted focus-visible:outline-2 focus-visible:outline-accent"
              />
            </form>
            <div :if={!@empty?} class="px-6 pb-3 sm:px-12 lg:border-b lg:border-line lg:px-4 lg:pb-4">
              <button
                id="toggle-filters"
                type="button"
                aria-controls="list-filters"
                aria-expanded="false"
                phx-click={toggle_filters()}
                class="inline-flex min-h-9 items-center gap-1.5 rounded-full border border-line bg-surface px-3 text-label font-semibold text-ink lg:hidden"
              >
                <Lucideicons.sliders_horizontal aria-hidden="true" class="size-3.5" />
                {gettext("Filter")}
              </button>
              <div
                id="list-filters"
                phx-mounted={@filtered? && show_filters()}
                class="mt-3 hidden flex-wrap items-center gap-x-4 gap-y-2 lg:mt-0 lg:flex"
              >
                <.segments :if={@filters["source"] == ""} label={gettext("Medium")}>
                  <.segment
                    :for={
                      {value, label} <- [
                        {"", gettext("All")},
                        {"video", gettext("Video")},
                        {"audio", gettext("Audio")}
                      ]
                    }
                    id={"filter-kind-#{if value == "", do: "all", else: value}"}
                    to={
                      SikioWeb.Sidebar.library_path(
                        Map.put(@filters, "kind", value),
                        nil,
                        @sidebar.titles
                      )
                    }
                    active={@filters["kind"] == value}
                  >
                    {label}
                  </.segment>
                </.segments>
                <.segments :if={@filters["source"] != ""} label={gettext("Status")}>
                  <.segment
                    :for={{value, key, label} <- views()}
                    id={"filter-status-#{key}"}
                    to={
                      SikioWeb.Sidebar.library_path(
                        Map.put(@filters, "status", value),
                        nil,
                        @sidebar.titles
                      )
                    }
                    active={@filters["status"] == value}
                  >
                    {label}
                  </.segment>
                </.segments>
              </div>
            </div>
          </div>
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
          <div
            :if={!@empty?}
            id="entries"
            phx-viewport-bottom={@more? && "load_more"}
            class="border-t border-line bg-surface empty:hidden lg:border-t-0"
          >
            <.entry_row
              :for={entry <- @entries}
              :key={entry.id}
              id={"entries-#{entry.id}"}
              entry={entry}
              to={SikioWeb.Sidebar.library_path(@filters, entry, @sidebar.titles)}
              selected={@selected && @selected.id == entry.id}
            />
          </div>
        </div>
        <section
          id="item-detail"
          data-entry-id={@selected && @selected.id}
          aria-label={gettext("Selected item")}
          tabindex="0"
          class={[
            "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent",
            "min-w-0 px-6 py-6 sm:px-12 lg:h-svh lg:overflow-y-auto lg:overscroll-none lg:px-7 lg:py-6",
            !@selected && "hidden lg:block"
          ]}
        >
          <.detail
            :if={@selected}
            entry={@selected}
            notes={@notes}
            chapters={@chapters}
            back={SikioWeb.Sidebar.library_path(@filters, nil, @sidebar.titles)}
          />
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
            <.status_mark entry={@entry} status={@status} />
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

  # A reconnect sends the form again, so an unchanged search changes nothing. A search keeps the
  # item that is open and replaces the address rather than adding a step for each word typed.
  defp searched(socket, text) do
    filters = Map.put(socket.assigns.filters, "q", text)

    if Library.normalize_filters(filters) == Library.normalize_filters(socket.assigns.filters),
      do: socket,
      else:
        push_patch(socket,
          replace: true,
          to: address(socket, filters, socket.assigns.selected)
        )
  end

  # Only filters the page offers may narrow it: a source has one medium and no medium filter.
  defp offered(%{"source" => source} = filters) when source != "", do: %{filters | "kind" => ""}
  defp offered(filters), do: filters

  # On a phone the filters fold away. The browser alone opens and closes them, so a patch never
  # folds them under the reader's finger; a filtered page opens with them shown.
  defp toggle_filters do
    JS.toggle_class("hidden flex", to: "#list-filters")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#toggle-filters")
  end

  defp show_filters do
    JS.remove_class("hidden", to: "#list-filters")
    |> JS.add_class("flex", to: "#list-filters")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#toggle-filters")
  end

  # The place the filters narrow: a source, or else a view by its status.
  defp place_of(%{"source" => source} = filters) when source != "",
    do: %{filters | "status" => "", "kind" => ""}

  defp place_of(filters), do: %{filters | "kind" => ""}

  attr :label, :string, required: true
  slot :inner_block, required: true

  # A row of choices of which one holds, labelled for those who do not see the row.
  defp segments(assigns) do
    ~H"""
    <div role="group" aria-label={@label} class="flex flex-wrap gap-2">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :to, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp segment(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@to}
      aria-current={@active && "true"}
      class="inline-flex min-h-8 items-center rounded-full border border-line bg-surface px-3 text-label text-ink hover:bg-ground aria-[current=true]:border-transparent aria-[current=true]:bg-selection aria-[current=true]:font-semibold aria-[current=true]:text-accent"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, default: nil
  attr :rest, :global, include: ~w(target rel)
  slot :icon, required: true

  # An action at the card's head: an icon and its name, a link when it leads somewhere. A card
  # narrower than three names and the meta line keeps the names for screen readers only. The
  # card's width follows the columns beside it, so it decides rather than the window.
  defp card_action(assigns) do
    assigns =
      assign(
        assigns,
        :class,
        "inline-flex h-9 items-center gap-1.5 rounded-full px-3 text-label font-medium text-muted hover:bg-ground hover:text-ink"
      )

    ~H"""
    <a :if={@href} id={@id} href={@href} class={@class} {@rest}>
      {render_slot(@icon)}
      <span class="@max-2xl:sr-only">{@label}</span>
    </a>
    <button :if={!@href} id={@id} type="button" class={@class} {@rest}>
      {render_slot(@icon)}
      <span class="@max-2xl:sr-only">{@label}</span>
    </button>
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

  attr :entry, :map, required: true
  attr :status, :atom, required: true

  # Where the reader stands, as the row and the detail say it: new, the time left, or done.
  defp status_mark(assigns) do
    ~H"""
    <span :if={@status == :in_progress} class="font-mono font-medium text-signal-strong">
      {time_left(@entry)}
    </span>
    <span :if={@status != :in_progress} class="inline-flex items-center gap-1.5">
      <span :if={@status == :new} aria-hidden="true" class="size-1.5 rounded-full bg-signal"></span>
      <Lucideicons.check :if={@status == :completed} aria-hidden="true" class="size-3.5" />
      {status_label(@entry)}
    </span>
    """
  end

  # Where the card's player stands before it plays: where the dock's would pick it up.
  defp cue_position(%{playback: nil}), do: 0
  defp cue_position(%{playback: playback}), do: Playback.resume_position(playback)

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
  attr :chapters, :list, required: true
  attr :entry, :map, required: true

  # The chapters the publisher listed. Each starts the item at its place, or moves the player
  # there when it already plays; the one reached is marked.
  defp chapters(assigns) do
    assigns = assign(assigns, :current, current_chapter(assigns.chapters, assigns.entry))

    ~H"""
    <nav id="item-chapters" aria-label={gettext("Chapters")} class="rounded-xl bg-ground p-2">
      <ol class="flex flex-col">
        <li :for={chapter <- @chapters}>
          <button
            type="button"
            phx-click={JS.dispatch("sikio:play", detail: %{id: @entry.id, position: chapter.at})}
            aria-current={chapter == @current && "true"}
            class="flex w-full items-baseline gap-3 rounded-lg px-2 py-1.5 text-left text-label hover:bg-surface aria-[current]:bg-surface aria-[current]:font-semibold aria-[current]:text-accent"
          >
            <span class="w-14 shrink-0 font-mono text-meta text-muted tabular-nums">
              {runtime(chapter.at) || "0:00"}
            </span>
            <span>{chapter.title}</span>
          </button>
        </li>
      </ol>
    </nav>
    """
  end

  # The chapter the item has reached, once it was started and until it was heard to the end.
  defp current_chapter(chapters, %{playback: %{status: :in_progress, position: position}}) do
    chapters |> Enum.filter(&(&1.at <= position)) |> List.last()
  end

  defp current_chapter(_chapters, _entry), do: nil

  attr :entry, :map, required: true
  attr :notes, :any, required: true, doc: "the filtered notes, or nil"
  attr :chapters, :list, required: true, doc: "the chapters the notes listed"
  attr :back, :string, required: true

  defp detail(assigns) do
    entry = assigns.entry

    assigns =
      assign(assigns,
        status: status(entry),
        runtime: runtime(length_of(entry)),
        original: original(entry)
      )

    ~H"""
    <.link patch={@back} class="mb-4 inline-block text-label font-semibold text-accent lg:hidden">
      {gettext("← Your library")}
    </.link>
    <article class="@container flex flex-col gap-4 rounded-2xl bg-surface p-6 shadow-sm ring-1 ring-line">
      <div class="flex items-start gap-3">
        <span
          aria-hidden="true"
          class="flex size-8 shrink-0 items-center justify-center rounded-full bg-accent/15 text-meta font-semibold text-accent"
        >
          {initial(@entry.feed.title)}
        </span>
        <div class="flex min-w-0 grow flex-col">
          <p class="truncate text-label font-semibold text-accent">{@entry.feed.title}</p>
          <p
            id="playback-status"
            aria-live="polite"
            class="flex flex-wrap items-center gap-x-1.5 text-meta text-muted"
          >
            <span>{medium_label(@entry)}</span>
            <span :if={@entry.published_at} aria-hidden="true">·</span>
            <span :if={@entry.published_at} class="font-mono">{date(@entry.published_at)}</span>
            <span :if={@runtime} aria-hidden="true">·</span>
            <span :if={@runtime} class="font-mono">{@runtime}</span>
            <span aria-hidden="true">·</span>
            <.status_mark entry={@entry} status={@status} />
          </p>
        </div>
        <div id="item-actions" class="-mt-1 -mr-2 flex shrink-0 items-center gap-1">
          <.card_action
            :if={@status != :completed}
            id="mark-completed"
            label={mark_done_label(@entry)}
            phx-click="mark"
            phx-value-id={@entry.id}
            phx-value-status="completed"
          >
            <:icon><Lucideicons.check aria-hidden="true" class="size-4.5" /></:icon>
          </.card_action>
          <.card_action
            :if={@status == :completed}
            id="mark-new"
            label={mark_new_label(@entry)}
            phx-click="mark"
            phx-value-id={@entry.id}
            phx-value-status="new"
          >
            <:icon><Lucideicons.rotate_ccw aria-hidden="true" class="size-4.5" /></:icon>
          </.card_action>
          <.card_action
            :if={@original}
            id="open-original"
            label={elem(@original, 1)}
            href={elem(@original, 0)}
            target="_blank"
            rel="noopener noreferrer"
          >
            <:icon><Lucideicons.external_link aria-hidden="true" class="size-4.5" /></:icon>
          </.card_action>
        </div>
      </div>
      <%!-- The player's place. The dock lays the playing player over it; until then it shows what
      would play and loads nothing from anybody else. See assets/js/dock_place.mjs. --%>
      <div
        id="player-slot"
        phx-mounted={JS.ignore_attributes(["style", "data-pinned", "data-playing"])}
      >
        <button
          :if={video?(@entry)}
          id="start-playback"
          type="button"
          phx-click={JS.dispatch("sikio:play", detail: %{id: @entry.id})}
          class="group block w-full rounded-xl text-left focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          <span class="relative block aspect-video w-full overflow-hidden rounded-xl bg-line">
            <img
              src={Pictures.path(Sikio.Pictures.candidates(@entry), kind_mark(@entry))}
              alt=""
              class="size-full object-cover"
            />
            <span class="absolute inset-0 flex items-center justify-center bg-black/10">
              <span class="flex size-16 items-center justify-center rounded-full bg-accent text-on-accent shadow-lg transition group-hover:scale-105">
                <Lucideicons.play aria-hidden="true" class="size-7 fill-current" />
              </span>
            </span>
            <span class="sr-only">{play_label(@entry)}</span>
          </span>
        </button>
        <%!-- An episode shows the player itself. Nothing loads until it is used; see
        assets/js/audio_cue.mjs. --%>
        <.audio_face
          :if={!video?(@entry)}
          id="audio-cue"
          phx-hook="AudioCue"
          cue={@entry}
          length={length_of(@entry)}
          position={cue_position(@entry)}
          data-entry-id={@entry.id}
          data-position-of={
            gettext("%{position} of %{duration}", position: "{position}", duration: "{duration}")
          }
        />
      </div>
      <%!-- The medium first, then the text about it. The title and the notes share one column at a
      reading measure in the card's middle; the card keeps the column's width. --%>
      <section class="mx-auto flex w-full max-w-[80ch] flex-col gap-3 pt-2">
        <h2 class="text-[26px] leading-tight font-semibold">{@entry.title}</h2>
        <.chapters :if={@chapters != []} chapters={@chapters} entry={@entry} />
        <div class="flex flex-col gap-3 border-t border-line pt-4">
          <div :if={@notes} id="item-notes" class="notes text-body text-ink">
            {@notes}
          </div>
          <p :if={!@notes} id="item-no-notes" class="text-muted">
            {gettext("The publisher sent no notes for this item.")}
          </p>
        </div>
      </section>
    </article>
    """
  end
end
