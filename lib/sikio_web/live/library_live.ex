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
  alias Sikio.Tags
  alias SikioWeb.LibraryLive.Rows
  alias SikioWeb.Notes
  alias SikioWeb.SubscriptionSettings

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
       marking: nil,
       mark_options: nil,
       renaming: nil,
       deleting: nil,
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
    {filters, item} = SikioWeb.LibraryPaths.read_path(path, params)
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
            above: nil,
            marking: nil,
            renaming: nil,
            deleting: nil
          )
          |> close_settings()
          |> reload()

    case select(socket, item) do
      {:ok, socket} -> {:noreply, socket |> Rows.reach() |> named(path, query)}
      :error -> {:noreply, push_navigate(socket, to: address(socket, filters))}
    end
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
  defp chosen_tag(socket) do
    tag = socket.assigns.filters["tag"]
    Enum.find(socket.assigns.sidebar.tags, &(to_string(&1.id) == tag))
  end

  defp rename_error(:taken), do: gettext("Another tag is called that already.")
  defp rename_error(:blank), do: gettext("A tag needs a name.")
  defp rename_error(:not_found), do: gettext("This tag is no longer there.")

  # Closes the source settings dialog, which applies only to the place it was opened on.
  defp close_settings(socket) do
    if connected?(socket),
      do: send_update(SubscriptionSettings, id: "subscription-settings", open: :close)

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

  # Converts the dialog's checkboxes into the exclusion options of `Playback.mark_all/3`.
  defp marking(%{in_progress: in_progress, playing: playing, playing_id: playing_id}),
    do: [in_progress: in_progress, keep: if(playing, do: nil, else: playing_id)]

  defp entry_id(value) do
    case Integer.parse(value || "") do
      {id, ""} -> id
      _ -> nil
    end
  end

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

  defp list_path(filters, titles), do: SikioWeb.LibraryPaths.library_path(filters, nil, titles)

  # Builds the library URL for `filters` and `item`, with source and tag slugs.
  defp address(socket, filters, item \\ nil),
    do: SikioWeb.LibraryPaths.library_path(filters, item, socket.assigns.sidebar.titles)

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
          if Library.listed?(account, filters, entry.id),
            do: filters,
            else: Library.normalize_filters(%{"source" => to_string(entry.feed_id)})

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

  def handle_event("toggle_search", params, socket),
    do:
      handle_event(
        if(socket.assigns.search_open?, do: "close_search", else: "open_search"),
        params,
        socket
      )

  # Opens a confirmation with the count from `Playback.markable`, which applies the archive rule.
  def handle_event("mark_all", _params, socket) do
    case Playback.markable(socket.assigns.current_account, socket.assigns.filters) do
      0 ->
        {:noreply, put_flash(socket, :info, gettext("Nothing here is left to archive."))}

      count ->
        {:noreply,
         assign(socket,
           marking: count,
           mark_options: %{in_progress: true, playing: true, playing_id: nil}
         )}
    end
  end

  # A checkbox change recounts the items to archive. This LiveView does not hold the playing
  # item, so the client sends its id; see assets/js/playing_entry.mjs.
  def handle_event("mark_options", params, socket) do
    options = %{
      in_progress: params["in_progress"] != "false",
      playing: params["playing"] != "false",
      playing_id: entry_id(params["playing_id"])
    }

    count =
      Playback.markable(
        socket.assigns.current_account,
        socket.assigns.filters,
        marking(options)
      )

    {:noreply, assign(socket, marking: count, mark_options: options)}
  end

  def handle_event("cancel_mark_all", _params, socket),
    do: {:noreply, socket |> assign(:marking, nil) |> push_event("focus", %{id: "mark-all"})}

  # The change triggers a PubSub broadcast. Its handler reloads the list and the sidebar.
  def handle_event("confirm_mark_all", _params, socket) do
    {:ok, _count} =
      Playback.mark_all(
        socket.assigns.current_account,
        socket.assigns.filters,
        marking(socket.assigns.mark_options)
      )

    {:noreply, assign(socket, :marking, nil)}
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

  # Renames the shown tag from the list header. A taken name shows an error in the open dialog.
  # A successful rename patches the URL to the new slug.
  def handle_event("rename_tag", _params, socket) do
    case chosen_tag(socket) do
      nil -> {:noreply, socket}
      tag -> {:noreply, assign(socket, :renaming, %{tag: tag, name: tag.name, error: nil})}
    end
  end

  def handle_event("rename_options", %{"name" => name}, socket),
    do: {:noreply, update(socket, :renaming, &%{&1 | name: name, error: nil})}

  def handle_event("submit_rename_tag", %{"name" => name} = params, socket) do
    {:noreply, socket} = handle_event("rename_options", params, socket)
    handle_event("confirm_rename_tag", %{"name" => name}, socket)
  end

  def handle_event("cancel_rename_tag", _params, socket),
    do: {:noreply, socket |> assign(:renaming, nil) |> push_event("focus", %{id: "rename-tag"})}

  def handle_event("confirm_rename_tag", _params, %{assigns: %{renaming: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_rename_tag", _params, socket) do
    %{tag: tag, name: name} = socket.assigns.renaming

    case Tags.rename(socket.assigns.current_account, tag.id, name) do
      # Refreshes the sidebar first, so `address` and `handle_params` use the new name.
      {:ok, _renamed} ->
        socket = socket |> assign(:renaming, nil) |> SikioWeb.Sidebar.refresh()
        {:noreply, push_patch(socket, to: address(socket, socket.assigns.filters), replace: true)}

      {:error, reason} ->
        {:noreply, update(socket, :renaming, &%{&1 | error: rename_error(reason)})}
    end
  end

  # Deleting a tag needs a confirmation that names it. Its subscriptions remain.
  def handle_event("delete_tag", _params, socket),
    do: {:noreply, assign(socket, :deleting, chosen_tag(socket))}

  def handle_event("cancel_delete_tag", _params, socket),
    do: {:noreply, socket |> assign(:deleting, nil) |> push_event("focus", %{id: "delete-tag"})}

  def handle_event("confirm_delete_tag", _params, %{assigns: %{deleting: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_delete_tag", _params, socket) do
    Tags.delete(socket.assigns.current_account, socket.assigns.deleting.id)

    {:noreply,
     socket
     |> assign(:deleting, nil)
     |> push_patch(to: SikioWeb.LibraryPaths.start_path())}
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

  # `:left` follows an unsubscribe from the shown source, so the page patches to the start path.
  def handle_info({SubscriptionSettings, :left}, socket),
    do: {:noreply, push_patch(socket, to: SikioWeb.LibraryPaths.start_path())}

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

  # Without a search the total comes from the sidebar counts. A search runs a count query.
  defp total(socket, %{"q" => ""} = filters),
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
      empty?: socket.assigns.sidebar.sources == [],
      counts: counts,
      total: total(socket, filters),
      heading: heading(filters, socket.assigns.sidebar),
      filtered?: place_of(filters) != filters
    )
  end

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
            <.confirm_dialog
              :if={@marking}
              name="mark-all"
              title={gettext("Archive everything here?")}
              confirm_label={gettext("Archive")}
            >
              <p>
                {ngettext(
                  "%{count} item in this list will be archived. It stays out of your history.",
                  "%{count} items in this list will be archived. They stay out of your history.",
                  @marking
                )}
              </p>
              <form id="mark-all-options" phx-change="mark_options" class="mt-4 flex flex-col gap-2">
                <label class="flex items-center gap-2.5 text-label text-ink">
                  <input type="hidden" name="in_progress" value="false" />
                  <input
                    type="checkbox"
                    name="in_progress"
                    value="true"
                    checked={@mark_options.in_progress}
                    class="size-4 accent-accent"
                  />
                  {gettext("Include items in progress")}
                </label>
                <%!-- The PlayingEntry hook shows this only while the player has an item. --%>
                <div
                  id="mark-all-playing"
                  phx-hook="PlayingEntry"
                  phx-mounted={JS.ignore_attributes(["hidden"])}
                  hidden
                >
                  <input type="hidden" name="playing_id" value={@mark_options.playing_id} />
                  <label class="flex items-center gap-2.5 text-label text-ink">
                    <input type="hidden" name="playing" value="false" />
                    <input
                      type="checkbox"
                      name="playing"
                      value="true"
                      checked={@mark_options.playing}
                      class="size-4 accent-accent"
                    />
                    {gettext("Include the item in the player")}
                  </label>
                </div>
              </form>
            </.confirm_dialog>
            <.confirm_dialog
              :if={@renaming}
              name="rename-tag"
              title={gettext("Rename %{name}", name: @renaming.tag.name)}
              confirm_label={gettext("Rename")}
            >
              <form
                id="rename-tag-form"
                phx-change="rename_options"
                phx-submit="submit_rename_tag"
                class="flex flex-col gap-2"
              >
                <input
                  type="text"
                  name="name"
                  value={@renaming.name}
                  maxlength="40"
                  aria-label={gettext("Name")}
                  class={dialog_field()}
                />
                <p :if={@renaming.error} class="text-label text-danger">{@renaming.error}</p>
              </form>
            </.confirm_dialog>
            <.confirm_dialog
              :if={@deleting}
              name="delete-tag"
              title={gettext("Delete %{name}?", name: @deleting.name)}
              confirm_label={gettext("Delete tag")}
              variant="danger"
            >
              <p>{gettext("The subscriptions stay; only the tag goes.")}</p>
            </.confirm_dialog>
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
                      SikioWeb.LibraryPaths.library_path(
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
