# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLive do
  @moduledoc """
  The library: the account's items listed by status, source, tag or search.

  The list and the selected item are encoded in the URL, so both survive a reload and Back.
  `SikioWeb.LibraryPaths.library_path/3` builds the URLs. Selecting an item is a `push_patch`.
  From `lg` the item shows in a column beside the list. Below `lg` it replaces the list.
  PubSub events keep the page current without polling.
  They cover new episodes, progress from another tab, status changes and subscription changes.
  """
  use SikioWeb, :live_view
  @behaviour SikioWeb.LibraryEvents

  import SikioWeb.LibraryComponents
  import SikioWeb.MediaComponents

  alias Sikio.Chapters
  alias Sikio.Feeds
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Preferences
  alias SikioWeb.DateGroups
  alias SikioWeb.LibraryLive.Calendar
  alias SikioWeb.LibraryLive.Rows
  alias SikioWeb.LibraryPaths
  alias SikioWeb.MarkAll
  alias SikioWeb.Notes
  alias SikioWeb.SubscriptionSettings
  alias SikioWeb.TagSettings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       selected: nil,
       notes: nil,
       chapters: [],
       read: nil,
       filters: nil,
       entries: [],
       above: nil,
       more?: false,
       search_open?: false,
       calendar_open?: false,
       calendar_month: nil,
       heard_days: %{},
       chosen_for_width: nil,
       time_zone_offset: time_zone_offset(get_connect_params(socket)),
       tab: :inbox
     )}
  end

  # The browser's UTC offset in minutes, from the connect params.
  # The static render has no connect params and uses UTC.
  defp time_zone_offset(%{"time_zone_offset" => offset})
       when is_integer(offset) and abs(offset) <= 14 * 60,
       do: offset

  defp time_zone_offset(_params), do: 0

  # The list is reloaded only when the filters change. Rows use `:key`, so a new selection
  # sends only the two rows whose `selected` changed.
  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    {filters, item} = read(path, params, socket.assigns.current_account)
    filters = %{filters | "offset" => socket.assigns.time_zone_offset}
    # A URL with `q` opens the search field, also after a reload or Back.
    # `/search` is the phone's Search tab. It lists all items and focuses the field.
    socket =
      assign(
        socket,
        :search_open?,
        socket.assigns.search_open? or filters["q"] != "" or path == "/search"
      )

    socket =
      if path == "/search" and connected?(socket),
        do: push_event(socket, "focus", %{id: "search-input"}),
        else: socket

    socket = assign(socket, :tab, tab(path, filters))

    # Any item other than the one `select_first` chose is a user selection.
    socket =
      if to_string(socket.assigns.chosen_for_width) == to_string(item),
        do: socket,
        else: assign(socket, :chosen_for_width, nil)

    socket =
      if filters == socket.assigns.filters,
        do: socket,
        else:
          socket
          |> assign(
            filters: filters,
            entries: [],
            above: nil
          )
          |> calendar()
          |> close_settings()
          |> reload()

    case select(socket, item) do
      {:ok, socket} -> {:noreply, socket |> Rows.reach() |> named(path, query)}
      :error -> {:noreply, push_navigate(socket, to: address(socket, filters))}
    end
  end

  # `/` opens the start page. It is read on each visit, so a deleted start tag falls back at once.
  defp read("/", params, account),
    do: LibraryPaths.read_path("/", params, LibraryPaths.start_filters(Preferences.get(account)))

  defp read(path, params, _account), do: LibraryPaths.read_path(path, params)

  # The start page's own address. A deleted start tag has already fallen back.
  defp start_path(socket) do
    socket.assigns.current_account
    |> Preferences.get()
    |> LibraryPaths.start_filters()
    |> LibraryPaths.library_path(nil, socket.assigns.sidebar.titles)
  end

  # Only the ids in the path are parsed; the slugs are for display.
  # A non-canonical URL, after a rename or typed by hand, is replaced with `push_patch`.
  defp named(socket, "/", _query), do: socket
  defp named(socket, "/search", _query), do: socket

  defp named(socket, path, query) do
    canonical = address(socket, socket.assigns.filters, socket.assigns.selected)
    current = if query in [nil, ""], do: path, else: "#{path}?#{query}"

    if canonical == current,
      do: socket,
      else: push_patch(socket, to: canonical, replace: true)
  end

  # Returns the filtered tag from the `:sidebar` assign.
  # Whether the account follows the feed, so it has a source page.
  defp followed?(socket, feed_id),
    do: Enum.any?(socket.assigns.sidebar.sources, &(&1.feed_id == feed_id))

  defp chosen_tag(socket) do
    tag = socket.assigns.filters["tag"]
    Enum.find(socket.assigns.sidebar.tags, &(to_string(&1.id) == tag))
  end

  # Closes the source, tag and archive dialogs, which apply only to the place they were opened on.
  defp close_settings(socket) do
    if connected?(socket) do
      send_update(SubscriptionSettings, id: "subscription-settings", open: :close)
      send_update(TagSettings, id: "tag-settings", open: :close)
      send_update(MarkAll, id: "mark-all-dialog", open: :close)
    end

    socket
  end

  # Returns the shown source's `page_url`, or nil.
  defp website(sources, source) do
    if subscription = shown_subscription(sources, source), do: subscription.feed.page_url
  end

  # Returns the shown source's subscription from the `:sidebar` assign.
  defp chosen_subscription(socket),
    do: shown_subscription(socket.assigns.sidebar.sources, socket.assigns.filters["source"])

  defp shown_subscription(sources, source),
    do: Enum.find(sources, &(to_string(&1.feed_id) == source))

  # Returns the active phone tab. A search is Search; the unfiltered inbox and queue have tabs.
  # Every other place belongs to Library.
  defp tab("/search", _filters), do: :search
  defp tab(_path, %{"q" => q}) when q != "", do: :search
  defp tab(_path, %{"status" => "inbox", "source" => "", "tag" => ""}), do: :inbox
  defp tab(_path, %{"status" => "queue", "source" => "", "tag" => ""}), do: :queue
  defp tab(_path, _filters), do: :library

  # The phone header's back link: from an item to its list, from a Library place to `/library`.
  defp back(selected, _tab, heading, list) when selected != nil,
    do: %{patch: list, label: heading}

  defp back(nil, :library, _heading, _list), do: %{to: ~p"/library", label: gettext("Library")}
  defp back(nil, _tab, _heading, _list), do: nil

  defp list_path(filters, titles), do: LibraryPaths.library_path(filters, nil, titles)

  # Builds the library URL for `filters` and `item`, with source and tag slugs.
  defp address(socket, filters, item \\ nil),
    do: LibraryPaths.library_path(filters, item, socket.assigns.sidebar.titles)

  @impl true
  def handle_event("move", %{"key" => key}, socket) when key in ["j", "k"] do
    socket = Rows.extend(socket, key)
    current = Rows.position(socket)
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

  def handle_event("load_more", _params, socket), do: {:noreply, Rows.load_more(socket)}
  # A list emptied by changes elsewhere loads again from its top.
  def handle_event("load_less", _params, %{assigns: %{entries: [], above: above}} = socket)
      when above != nil,
      do: {:noreply, socket |> assign(:above, nil) |> reload()}

  def handle_event("load_less", _params, socket), do: {:noreply, Rows.load_less(socket)}

  # Opens a playing item, from the mini player's title or after the queue plays on.
  # It opens in the current list if listed there, else in its source's list.
  # The client cancels the title link's navigation, so a removed item gets an error flash.
  def handle_event("show", %{"id" => id}, socket) do
    %{current_account: account, filters: filters} = socket.assigns

    case Library.entry(account, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("This item is no longer in your library."))}

      entry ->
        filters =
          cond do
            Library.listed?(account, filters, entry.id) ->
              filters

            followed?(socket, entry.feed_id) ->
              Library.normalize_filters(%{"source" => to_string(entry.feed_id)})

            # A singly saved item has no source page.
            true ->
              Library.normalize_filters(%{"status" => ""})
          end

        {:noreply, push_patch(socket, to: address(socket, filters, entry))}
    end
  end

  # Sent when the player finished the shown item and no queue item follows.
  # The detail closes if the current list no longer contains the item.
  # A manual mark does not send this, so the detail stays open and the mark can be undone.
  def handle_event("played_out", %{"id" => id}, socket) do
    %{current_account: account, filters: filters, selected: selected} = socket.assigns

    if selected && to_string(selected.id) == id &&
         not Library.listed?(account, filters, selected.id),
       do: {:noreply, push_patch(socket, to: address(socket, filters))},
       else: {:noreply, socket}
  end

  # From `lg` the detail always shows an item. The ReaderKeys hook pushes this when none is
  # selected. The URL is replaced, so Back does not return to the empty detail.
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

  # Below `lg` the detail replaces the list. An item chosen by `select_first` is deselected;
  # a user selection stays.
  def handle_event("release_first", _params, %{assigns: %{chosen_for_width: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("release_first", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:chosen_for_width, nil)
       |> push_patch(to: address(socket, socket.assigns.filters), replace: true)}

  def handle_event("search", %{"q" => text}, socket), do: {:noreply, searched(socket, text)}
  # Only `close_search` closes the field, so a patch never closes it while typing.
  # Opening focuses the input. Closing clears the search and focuses the toggle button.
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

  # Closing the calendar removes its day filter. `handle_params` keeps it closed.
  # The selection goes too: an item far down would load a window around it, not the top.
  def handle_event("toggle_calendar", _params, %{assigns: %{calendar_open?: true}} = socket) do
    socket = assign(socket, calendar_open?: false, heard_days: %{})
    filters = socket.assigns.filters

    if filters["day"] == "",
      do: {:noreply, socket},
      else: {:noreply, push_patch(socket, to: address(socket, %{filters | "day" => ""}))}
  end

  def handle_event("toggle_calendar", _params, socket),
    do: {:noreply, socket |> assign(:calendar_open?, true) |> with_heard_days()}

  # The calendar does not move past the reader's current month.
  def handle_event("calendar_month", %{"step" => step}, socket)
      when step in ["-1", "1"] and socket.assigns.calendar_month != nil do
    month = Date.shift(socket.assigns.calendar_month, month: String.to_integer(step))

    {:noreply,
     socket |> assign(:calendar_month, at_most_this_month(socket, month)) |> with_heard_days()}
  end

  def handle_event("calendar_month", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_search", params, socket),
    do:
      handle_event(
        if(socket.assigns.search_open?, do: "close_search", else: "open_search"),
        params,
        socket
      )

  # Opens a confirmation with the count from `Playback.markable`, which applies the archive rule.
  # Counts first, so an empty list gets a message instead of a dialog.
  def handle_event("mark_all", _params, socket) do
    %{current_account: account, filters: filters} = socket.assigns

    case Playback.markable(account, filters) do
      0 ->
        {:noreply, put_flash(socket, :info, gettext("Nothing here is left to archive."))}

      count ->
        send_update(MarkAll, id: "mark-all-dialog", open: {count, filters})
        {:noreply, socket}
    end
  end

  # Opens the `SikioWeb.SubscriptionSettings` dialog for the shown source.
  def handle_event("edit_subscription", _params, socket) do
    if subscription = chosen_subscription(socket) do
      send_update(SubscriptionSettings,
        id: "subscription-settings",
        open: {:edit, subscription, "edit-subscription"}
      )
    end

    {:noreply, socket}
  end

  # Opens the `SikioWeb.TagSettings` dialog to rename or delete the shown tag.
  def handle_event(action, _params, socket) when action in ["rename_tag", "delete_tag"] do
    if tag = chosen_tag(socket) do
      open = if action == "rename_tag", do: :rename, else: :delete
      send_update(TagSettings, id: "tag-settings", open: {open, tag})
    end

    {:noreply, socket}
  end

  def handle_event("toggle_mark", _params, %{assigns: %{selected: nil}} = socket),
    do: {:noreply, socket}

  # The status is read from the database, not from `selected`. A second key press can arrive
  # before the first mark's broadcast updates `selected`.
  def handle_event("toggle_mark", _params, %{assigns: %{selected: selected}} = socket) do
    case Library.entry(socket.assigns.current_account, selected.id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("This item is no longer in your library."))}

      entry ->
        status = if status(entry) in [:heard, :archived], do: "new", else: "heard"
        handle_event("mark", %{"id" => entry.id, "status" => status}, socket)
    end
  end

  def handle_event("queue", %{"id" => id, "at" => at}, socket) when at in ["first", "last"],
    do:
      changed(
        socket,
        Playback.enqueue(socket.assigns.current_account, id, String.to_existing_atom(at))
      )

  # Sent after a drag or an arrow-key move. The broadcast reloads the queue in its new order.
  def handle_event("reorder", %{"id" => id, "index" => index}, socket) when is_integer(index),
    do: changed(socket, Playback.move(socket.assigns.current_account, id, index))

  # A singly saved item leaves the library, and the detail closes. Its playback state stays.
  def handle_event("remove_entry", %{"id" => id}, socket) do
    Library.remove_entry(socket.assigns.current_account, id)
    {:noreply, push_patch(socket, to: address(socket, socket.assigns.filters))}
  end

  def handle_event("dequeue", %{"id" => id}, socket),
    do: changed(socket, Playback.dequeue(socket.assigns.current_account, id))

  def handle_event("mark", %{"id" => id, "status" => status}, socket)
      when status in ["new", "heard", "archived"],
      do:
        changed(
          socket,
          Playback.mark(socket.assigns.current_account, id, String.to_existing_atom(status))
        )

  # The change triggers a PubSub broadcast. Its handler reloads the list and the sidebar.
  defp changed(socket, result) do
    case result do
      {:ok, _} ->
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("This item is no longer in your library."))}
    end
  end

  @impl SikioWeb.LibraryEvents
  @doc """
  Handles library events forwarded by `SikioWeb.LibraryEvents`.

  `:playback_progressed` updates the matching entry in place.
  Any other event may change which items the list contains.
  It reloads the list and the selected entry. A selected entry that left the library closes.
  """
  # Progress cannot move an item between lists. Filters use status, source, tag and search text.
  # Only the matching entry gets the new position; nothing is reloaded.
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

  # A state older than the shown one is ignored, so a late message cannot undo a mark.
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
         |> fetch_chapters(entry)
         |> assign(reading(socket, entry))
         |> assign(selected: entry, page_title: entry.title)}
    end
  end

  # Parsing the notes is the expensive part of the detail.
  # Library events reselect a playing item several times a minute.
  # Chapters and notes are recomputed only when id, description, length or feed chapters change.
  # Chapters listed in the notes are removed from them and shown in their own box.
  # The player may measure the length later. Feed chapters may arrive after the item was opened.
  defp reading(socket, entry) do
    read = {entry.id, entry.description, length_of(entry), entry.chapters}

    if socket.assigns.read == read,
      do: Map.take(socket.assigns, [:notes, :chapters, :read]),
      else: Map.put(read_notes(entry), :read, read)
  end

  # Returns the chapters and the rendered notes; see `Sikio.Chapters.of/2`.
  defp read_notes(entry) do
    {chapters, notes} = Chapters.of(entry, length_of(entry))
    %{chapters: chapters, notes: Notes.notes(notes, entry.description_format || :html)}
  end

  # Fetches a missing chapters file with `start_async` when a different item is selected.
  # Reselecting the same item after an event skips the fetch.
  defp fetch_chapters(%{assigns: %{selected: %{id: id}}} = socket, %{id: id}), do: socket

  defp fetch_chapters(socket, %{chapters: nil, chapters_url: url} = entry) when is_binary(url) do
    if connected?(socket),
      do: start_async(socket, :chapters, fn -> {entry.id, Feeds.chapters(entry)} end),
      else: socket
  end

  defp fetch_chapters(socket, _entry), do: socket

  @impl true
  def handle_info({SubscriptionSettings, :saved}, socket),
    do: {:noreply, SikioWeb.Sidebar.refresh(socket)}

  # `:left` follows an unsubscribe from the shown source, so the page patches to the start page.
  def handle_info({SubscriptionSettings, :left}, socket),
    do: {:noreply, push_patch(socket, to: start_path(socket))}

  # A rename refreshes the sidebar first, so `address` and `handle_params` use the new name.
  def handle_info({TagSettings, :renamed}, socket) do
    socket = SikioWeb.Sidebar.refresh(socket)
    {:noreply, push_patch(socket, to: address(socket, socket.assigns.filters), replace: true)}
  end

  def handle_info({TagSettings, :deleted}, socket),
    do: {:noreply, push_patch(socket, to: start_path(socket))}

  def handle_info({SubscriptionSettings, :not_found}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Subscription not found."))}

  @impl true
  def handle_async(:chapters, {:ok, {id, {:ok, chapters}}}, socket) do
    case socket.assigns.selected do
      %{id: ^id} = selected ->
        selected = %{selected | chapters: chapters}
        {:noreply, socket |> assign(reading(socket, selected)) |> assign(:selected, selected)}

      _ ->
        {:noreply, socket}
    end
  end

  # A failed fetch is not stored. The next selection of the item retries it.
  def handle_async(:chapters, _result, socket), do: {:noreply, socket}

  # Without a search or a day the total comes from the sidebar counts.
  # Both of those run a count query.
  defp total(socket, %{"q" => "", "day" => ""} = filters),
    do:
      socket.assigns.sidebar.counts
      |> Library.tally(filters, socket.assigns.sidebar.tag_feeds)
      |> Library.total(filters)

  defp total(socket, filters), do: Library.count(socket.assigns.current_account, filters)

  # Rereads the rows with the counts and the heading around them.
  defp reload(socket) do
    filters = socket.assigns.filters
    # Sidebar and chips show unfiltered counts per place. The heading shows `total` for the list.
    counts = Library.tally(socket.assigns.sidebar.counts, %{}, socket.assigns.sidebar.tag_feeds)

    socket
    |> Rows.reread()
    |> assign(
      # A new library follows nothing and holds no saved entry, so the sidebar counts no rows.
      empty?: socket.assigns.sidebar.sources == [] and socket.assigns.sidebar.counts == [],
      counts: counts,
      total: total(socket, filters),
      heading: heading(filters, socket.assigns.sidebar),
      filtered?: place_of(filters) != filters
    )
    |> with_heard_days()
  end

  # Only the history has a calendar. A day opens it on the day's month, at most the current one.
  # Without a day it keeps the month browsed to, or shows the reader's current month.
  defp calendar(%{assigns: %{filters: %{"status" => "heard", "day" => ""}}} = socket),
    do: assign(socket, :calendar_month, socket.assigns.calendar_month || this_month(socket))

  defp calendar(%{assigns: %{filters: %{"status" => "heard", "day" => day}}} = socket) do
    month = day |> Date.from_iso8601!() |> Date.beginning_of_month()
    assign(socket, calendar_open?: true, calendar_month: at_most_this_month(socket, month))
  end

  defp calendar(socket), do: assign(socket, calendar_open?: false, calendar_month: nil)

  defp with_heard_days(socket), do: assign(socket, :heard_days, heard_days(socket))

  # A closed calendar shows no days, so it reads none.
  defp heard_days(%{assigns: %{calendar_open?: false}}), do: %{}
  defp heard_days(%{assigns: %{calendar_month: nil}}), do: %{}

  defp heard_days(socket) do
    %{current_account: account, filters: filters, calendar_month: month} = socket.assigns
    Library.heard_days(account, filters, month)
  end

  defp today(offset), do: DateGroups.local_day(DateTime.utc_now(), offset)

  defp at_most_this_month(socket, month), do: Enum.min([month, this_month(socket)], Date)

  defp this_month(socket),
    do: socket.assigns.time_zone_offset |> today() |> Date.beginning_of_month()

  # A search across all items is titled Search. A search within a place keeps the place's name.
  defp name(:search, %{"status" => "", "source" => "", "tag" => ""}, _heading),
    do: gettext("Search")

  defp name(_tab, _filters, heading), do: heading

  # Returns the list heading: the source or tag name if set, else the status view's label.
  defp heading(%{"source" => source}, sidebar) when source != "",
    do: source_title(sidebar.sources, source)

  defp heading(%{"tag" => tag}, sidebar) when tag != "",
    do:
      Enum.find_value(sidebar.tags, gettext("Unavailable tag"), fn t ->
        to_string(t.id) == tag && t.name
      end)

  defp heading(%{"status" => status}, _sidebar),
    do: Enum.find_value(views(), fn {value, _key, label} -> value == status && label end)

  defp source_title(subscriptions, source) do
    Enum.find_value(subscriptions, gettext("Unavailable source"), fn subscription ->
      to_string(subscription.feed_id) == source && source_name(subscription)
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
      tab={@tab}
      title={if(@selected, do: @selected.title, else: name(@tab, @filters, @heading))}
      back={
        back(@selected, @tab, name(@tab, @filters, @heading), list_path(@filters, @sidebar.titles))
      }
    >
      <div
        id="library"
        phx-hook="ReaderKeys"
        data-selected={@selected && @selected.id}
        data-rows={length(@entries)}
        class="lg:grid lg:h-svh lg:grid-cols-[28rem_minmax(0,1fr)]"
      >
        <%!-- From lg the page does not scroll. List and detail scroll independently, with
        `overscroll-none`. Each has `tabindex="0"`, so the keyboard can scroll it. --%>
        <div
          id="list-pane"
          tabindex="0"
          phx-mounted={JS.ignore_attributes("style")}
          class={[
            "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent",
            "min-w-0 lg:h-svh lg:overflow-y-auto lg:overscroll-none lg:border-r lg:border-line lg:bg-surface",
            @selected && "hidden lg:block"
          ]}
        >
          <%!-- From lg the heading, search and filters are sticky above the list. --%>
          <div
            id="list-head"
            phx-hook="ListHead"
            class="lg:sticky lg:top-0 lg:z-10 lg:border-b lg:border-line lg:bg-surface"
          >
            <%!-- The heading spans the head's full width, so a long source name wraps later.
                 The count and the actions share the line below it. --%>
            <div class="flex flex-col gap-0.5 px-6 pt-6 pb-4 sm:px-12 lg:px-4 lg:pt-5 lg:pb-3">
              <h1
                id="library-heading"
                data-large-title={!@selected}
                class="text-title font-semibold"
              >
                {name(@tab, @filters, @heading)}
              </h1>
              <div class="flex min-h-9 items-center justify-between gap-3">
                <span
                  :if={!@empty?}
                  id="library-count"
                  class="font-mono text-meta tracking-tighter text-muted"
                >
                  {count_label(@total)}
                </span>
                <div class="ml-auto flex shrink-0 items-center gap-2">
                  <%!-- Archive all is hidden for an empty list, the queue and the history. --%>
                  <button
                    :if={@total > 0 and @filters["status"] not in ["queue", "heard"]}
                    id="mark-all"
                    type="button"
                    aria-label={gettext("Archive all")}
                    title={gettext("Archive all")}
                    phx-click="mark_all"
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
                  >
                    <Lucideicons.check_check aria-hidden="true" class="size-4.5" />
                  </button>
                  <button
                    :if={@filters["tag"] != ""}
                    id="rename-tag"
                    type="button"
                    aria-label={gettext("Rename tag")}
                    title={gettext("Rename tag")}
                    phx-click="rename_tag"
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
                  >
                    <Lucideicons.pencil aria-hidden="true" class="size-4.5" />
                  </button>
                  <button
                    :if={@filters["tag"] != ""}
                    id="delete-tag"
                    type="button"
                    aria-label={gettext("Delete tag")}
                    title={gettext("Delete tag")}
                    phx-click="delete_tag"
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
                  >
                    <Lucideicons.trash_2 aria-hidden="true" class="size-4.5" />
                  </button>
                  <%!-- Opens the source's settings: name, target list for new episodes, tags and
                       unsubscribe. --%>
                  <button
                    :if={@filters["source"] != ""}
                    id="edit-subscription"
                    type="button"
                    aria-label={gettext("Edit subscription")}
                    title={gettext("Edit subscription")}
                    phx-click="edit_subscription"
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
                  >
                    <Lucideicons.pencil aria-hidden="true" class="size-4.5" />
                  </button>
                  <.link
                    :if={site = website(@sidebar.sources, @filters["source"])}
                    id="open-website"
                    href={site}
                    target="_blank"
                    rel="noopener noreferrer"
                    aria-label={gettext("Open website")}
                    title={gettext("Open website")}
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
                  >
                    <Lucideicons.external_link aria-hidden="true" class="size-4.5" />
                  </.link>
                  <button
                    :if={!@empty? and @filters["status"] == "heard"}
                    id="toggle-calendar"
                    type="button"
                    aria-controls="history-calendar"
                    aria-expanded={to_string(@calendar_open?)}
                    aria-label={gettext("Calendar")}
                    title={gettext("Calendar")}
                    phx-click="toggle_calendar"
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink aria-expanded:text-accent"
                  >
                    <Lucideicons.calendar_days aria-hidden="true" class="size-4.5" />
                  </button>
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
                </div>
              </div>
            </div>
            <.live_component module={MarkAll} id="mark-all-dialog" current_account={@current_account} />
            <.live_component
              module={TagSettings}
              id="tag-settings"
              current_account={@current_account}
            />
            <.live_component
              module={SubscriptionSettings}
              id="subscription-settings"
              current_account={@current_account}
              tags={@sidebar.tags}
            />
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
            <Calendar.calendar
              :if={!@empty? and @calendar_month}
              open={@calendar_open?}
              month={@calendar_month}
              today={today(@time_zone_offset)}
              days={@heard_days}
              filters={@filters}
              titles={@sidebar.titles}
            />
            <%!-- Status filters show within a source or tag. Elsewhere statuses are places. --%>
            <div
              :if={!@empty? and (@filters["source"] != "" or @filters["tag"] != "")}
              class="px-6 pb-3 sm:px-12 lg:px-4 lg:pb-4"
            >
              <button
                id="toggle-filters"
                type="button"
                aria-controls="list-filters"
                aria-expanded="false"
                phx-click={toggle_filters()}
                class="inline-flex min-h-9 items-center gap-1.5 rounded-full border border-line bg-surface px-3 text-label font-semibold text-ink aria-expanded:border-transparent aria-expanded:bg-accent aria-expanded:text-on-accent lg:hidden"
              >
                <Lucideicons.sliders_horizontal aria-hidden="true" class="size-3.5" />
                {gettext("Filter")}
              </button>
              <div
                id="list-filters"
                phx-mounted={@filtered? && show_filters()}
                class="mt-3 hidden flex-wrap items-center gap-x-4 gap-y-2 lg:mt-0 lg:flex"
              >
                <.segments label={gettext("Status")}>
                  <.segment
                    :for={{value, key, label} <- segments()}
                    id={"filter-status-#{key}"}
                    to={
                      LibraryPaths.library_path(
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
            class="mx-6 rounded-xl bg-surface p-8 ring-1 ring-line sm:mx-12 lg:m-4"
          >
            <h2 class="text-title font-semibold">{gettext("Space for something good.")}</h2>
            <p class="mt-2 max-w-lg text-muted">
              {gettext(
                "Paste a YouTube channel, a video or a podcast website. Or find your next listen in Apple Podcasts."
              )}
            </p>
            <.button class="mt-5" variant="primary" navigate={~p"/add"}>
              {gettext("Find your first source →")}
            </.button>
          </section>
          <div
            :if={!@empty?}
            id="entries"
            phx-hook="QueueSort"
            phx-viewport-top={@above && "load_less"}
            phx-viewport-bottom={@more? && "load_more"}
            class="border-t border-line bg-surface empty:hidden lg:border-t-0"
          >
            <.list_row
              :for={row <- Rows.grouped(@entries, @filters, @time_zone_offset, @above)}
              :key={row_id(row)}
              row={row}
              filters={@filters}
              titles={@sidebar.titles}
              selected={@selected && @selected.id}
            />
          </div>
          <.list_empty :if={!@empty? and @entries == []} filters={@filters} />
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
          />
        </section>
      </div>
    </Layouts.member>
    """
  end

  # A reconnect resubmits the form, so an unchanged search is a no-op. A search keeps the selected
  # item. It replaces the history entry instead of adding one per change.
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

  # Below `lg` the filters are collapsed. JS commands toggle them on the client only,
  # so a patch never collapses them. A filtered list mounts with them expanded.
  defp toggle_filters do
    JS.toggle_class("hidden flex", to: "#list-filters")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#toggle-filters")
  end

  defp show_filters do
    JS.remove_class("hidden", to: "#list-filters")
    |> JS.add_class("flex", to: "#list-filters")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#toggle-filters")
  end

  # Returns the filters of the place: without the status for a source or tag, else unchanged.
  defp place_of(%{"source" => source} = filters) when source != "",
    do: %{filters | "status" => ""}

  defp place_of(%{"tag" => tag} = filters) when tag != "",
    do: %{filters | "status" => ""}

  defp place_of(filters), do: filters
end
