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
  alias Sikio.Feeds
  alias Sikio.Library
  alias Sikio.Playback
  alias Sikio.Tags
  alias SikioWeb.DateGroups
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
       marking: nil,
       mark_options: nil,
       unsubscribing: nil,
       tagging: nil,
       renaming: nil,
       deleting: nil,
       chosen_for_width: nil,
       time_zone_offset: time_zone_offset(get_connect_params(socket)),
       tab: :new
     )}
  end

  # The reader's offset from UTC in minutes, sent by the browser. The static render, before it
  # connects, counts days in UTC.
  defp time_zone_offset(%{"time_zone_offset" => offset})
       when is_integer(offset) and abs(offset) <= 14 * 60,
       do: offset

  defp time_zone_offset(_params), do: 0

  # The list is read again only when the filters change. The rows are keyed, so choosing another
  # item sends only the two rows whose selection changed and the list stands.
  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    {filters, item} = SikioWeb.Sidebar.read_path(path, params)
    # An address with a search shows the field, a reload or the Back button included. Search, a
    # phone's tab of its own, opens every item with the field ready for the keys.
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

    # Any other item than the one the page chose for a wide screen is the reader's own choice.
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
            marking: nil,
            unsubscribing: nil,
            tagging: nil,
            renaming: nil,
            deleting: nil
          )
          |> reload()

    case select(socket, item) do
      {:ok, socket} -> {:noreply, socket |> reach() |> named(path, query)}
      :error -> {:noreply, push_navigate(socket, to: address(socket, filters))}
    end
  end

  # An address names a source and an item by number; the titles after the numbers are for the
  # reader. One that reads otherwise, after a rename or typed by hand, is corrected in place.
  defp named(socket, "/", _query), do: socket
  defp named(socket, "/search", _query), do: socket

  defp named(socket, path, query) do
    canonical = address(socket, socket.assigns.filters, socket.assigns.selected)
    current = if query in [nil, ""], do: path, else: "#{path}?#{query}"

    if canonical == current,
      do: socket,
      else: push_patch(socket, to: canonical, replace: true)
  end

  # The tag the list shows, as the sidebar holds it.
  defp chosen_tag(socket) do
    tag = socket.assigns.filters["tag"]
    Enum.find(socket.assigns.sidebar.tags, &(to_string(&1.id) == tag))
  end

  defp rename_error(:taken), do: gettext("Another tag is called that already.")
  defp rename_error(:blank), do: gettext("A tag needs a name.")
  defp rename_error(:not_found), do: gettext("This tag is no longer there.")

  # The subscription to the source the list shows, as the sidebar holds it.
  defp chosen_subscription(socket) do
    source = socket.assigns.filters["source"]
    Enum.find(socket.assigns.sidebar.sources, &(to_string(&1.feed_id) == source))
  end

  # The dialog's ticks as what `Playback.mark_all/3` leaves out.
  defp marking(%{in_progress: in_progress, playing: playing, playing_id: playing_id}),
    do: [in_progress: in_progress, keep: if(playing, do: nil, else: playing_id)]

  defp entry_id(value) do
    case Integer.parse(value || "") do
      {id, ""} -> id
      _ -> nil
    end
  end

  # The list's rows with a heading wherever the date group changes, by the date the list runs by.
  defp grouped(entries, filters, offset) do
    by = Library.sorted_by(filters)
    now = DateTime.utc_now()

    entries
    |> Enum.chunk_by(&(Library.sort_date(&1, by) |> DateGroups.group(now, offset) |> elem(0)))
    |> Enum.flat_map(fn [first | _] = chunk ->
      {key, label} = DateGroups.group(Library.sort_date(first, by), now, offset)
      [{:heading, key, label} | Enum.map(chunk, &{:entry, &1})]
    end)
  end

  # A question before something that changes much at once. Rendered only while it asks and
  # opened as it appears, see assets/js/app.js; it takes the focus itself, so no button shows a
  # ring before anybody tabs. A patch keeps it open, since the server never renders `open`. Its
  # buttons and Escape send `cancel_<name>` and `confirm_<name>`.
  attr :name, :string, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  slot :inner_block, required: true

  defp confirm_dialog(assigns) do
    assigns = assign(assigns, :event, String.replace(assigns.name, "-", "_"))

    ~H"""
    <dialog
      id={"#{@name}-confirm"}
      tabindex="-1"
      autofocus
      aria-labelledby={"#{@name}-heading"}
      phx-mounted={JS.ignore_attributes(["open"]) |> JS.dispatch("sikio:show")}
      phx-window-keydown={"cancel_#{@event}"}
      phx-key="Escape"
      class="m-auto w-[min(26rem,calc(100vw-2rem))] rounded-2xl bg-surface p-6 text-ink shadow-xl outline-none backdrop:bg-black/40"
    >
      <h2 id={"#{@name}-heading"} class="text-title font-semibold">{@title}</h2>
      <div class="mt-2 text-body text-muted">{render_slot(@inner_block)}</div>
      <div class="mt-6 flex justify-end gap-2">
        <.button id={"cancel-#{@name}"} type="button" phx-click={"cancel_#{@event}"}>
          {gettext("Cancel")}
        </.button>
        <.button
          id={"confirm-#{@name}"}
          type="button"
          variant="primary"
          phx-click={"confirm_#{@event}"}
        >
          {@confirm_label}
        </.button>
      </div>
    </dialog>
    """
  end

  defp row_id({:heading, {year, month}, _label}), do: "group-#{year}-#{month}"
  defp row_id({:heading, key, _label}), do: "group-#{key}"
  defp row_id({:entry, entry}), do: "entries-#{entry.id}"

  # A heading between date groups, or an entry. Headings stay in view under the list's own head
  # while their group scrolls past; see assets/js/list_head.mjs for the head's height.
  attr :row, :any, required: true
  attr :filters, :map, required: true
  attr :titles, :map, required: true, doc: "the sources' titles, which addresses name"
  attr :selected, :any, required: true, doc: "the id of the entry shown beside the list"

  defp list_row(%{row: {:heading, _key, label}} = assigns) do
    assigns = assign(assigns, :label, label)

    ~H"""
    <h2
      id={row_id(@row)}
      data-group
      class="border-b border-line bg-surface px-6 pt-4 pb-1.5 text-meta font-semibold tracking-wider text-muted uppercase sm:px-12 lg:sticky lg:top-(--list-head) lg:z-[5] lg:px-4"
    >
      {@label}
    </h2>
    """
  end

  defp list_row(%{row: {:entry, entry}} = assigns) do
    assigns = assign(assigns, :entry, entry)

    ~H"""
    <.entry_row
      id={row_id(@row)}
      entry={@entry}
      to={SikioWeb.Sidebar.library_path(@filters, @entry, @titles)}
      selected={@selected == @entry.id}
      source_shown={@filters["source"] == ""}
    />
    """
  end

  # A phone's tab: searching is Search, what is new and what is in progress are their own tabs,
  # every other place is the Library's.
  defp tab("/search", _filters), do: :search
  defp tab(_path, %{"q" => q}) when q != "", do: :search
  defp tab(_path, %{"status" => "new", "source" => "", "tag" => ""}), do: :new
  defp tab(_path, %{"status" => "in_progress", "source" => "", "tag" => ""}), do: :in_progress
  defp tab(_path, _filters), do: :library

  attr :filters, :map, required: true

  # An empty list says what it would hold, and gives no advice.
  defp list_empty(assigns) do
    {title, why} = nothing(assigns.filters)
    assigns = assign(assigns, title: title, why: why)

    ~H"""
    <section
      id="list-empty"
      role="status"
      class="border-t border-line px-6 py-12 text-center sm:px-12 lg:border-t-0 lg:px-4"
    >
      <p class="font-semibold text-ink">{@title}</p>
      <p :if={@why} class="mt-1 text-label text-muted">{@why}</p>
    </section>
    """
  end

  # What an empty list says: what it would hold, and a line on why when there is one.
  defp nothing(%{"q" => q}) when q not in [nil, ""],
    do: {gettext("Nothing matches “%{query}”.", query: q), nil}

  defp nothing(%{"status" => "new"}),
    do: {gettext("Nothing new."), gettext("You’re all caught up.")}

  defp nothing(%{"status" => "in_progress"}),
    do:
      {gettext("Nothing in progress."),
       gettext("What you start playing waits here, so you can go on with it.")}

  defp nothing(%{"status" => "completed"}), do: {gettext("Nothing finished yet."), nil}

  defp nothing(_filters),
    do: {gettext("No items yet."), gettext("New items arrive as your sources publish them.")}

  # Where a phone's bar leads back: an item to its list, a place within the Library to the Library.
  defp back(selected, _tab, heading, list) when selected != nil,
    do: %{patch: list, label: heading}

  defp back(nil, :library, _heading, _list), do: %{to: ~p"/library", label: gettext("Library")}
  defp back(nil, _tab, _heading, _list), do: nil

  defp list_path(filters, titles), do: SikioWeb.Sidebar.library_path(filters, nil, titles)

  # The library's address for `filters` and `item`, naming sources by their titles.
  defp address(socket, filters, item \\ nil),
    do: SikioWeb.Sidebar.library_path(filters, item, socket.assigns.sidebar.titles)

  # An item opened by its address may lie beyond the batches loaded. The list grows until it
  # shows the item, or until it has passed where the item would be, which a filtered-out item is.
  defp reach(%{assigns: %{selected: nil}} = socket), do: socket

  defp reach(%{assigns: %{selected: selected, entries: entries, more?: more?}} = socket) do
    by = Library.sorted_by(socket.assigns.filters)

    if position(socket) || !more? ||
         (entries != [] and !Library.before?(List.last(entries), selected, by)),
       do: socket,
       else: socket |> load_more() |> reach()
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

  # The double check asks first and names how many it would mark, by the rule that marks them.
  def handle_event("mark_all", _params, socket) do
    case Playback.markable(socket.assigns.current_account, socket.assigns.filters) do
      0 ->
        {:noreply, put_flash(socket, :info, gettext("Everything here is finished already."))}

      count ->
        {:noreply,
         assign(socket,
           marking: count,
           mark_options: %{in_progress: true, playing: true, playing_id: nil}
         )}
    end
  end

  # A tick changes what is marked, so the question counts again. Which item plays only the page
  # knows, and it sends it along; see assets/js/playing_entry.mjs.
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

  # The change is broadcast, and the broadcast reloads the list along with the sidebar.
  def handle_event("confirm_mark_all", _params, socket) do
    {:ok, _count} =
      Playback.mark_all(
        socket.assigns.current_account,
        socket.assigns.filters,
        marking(socket.assigns.mark_options)
      )

    {:noreply, assign(socket, :marking, nil)}
  end

  # A source's tags are chosen in a dialog: the account's tags to tick, and a field for a new one.
  # What is ticked and typed is followed as it changes, and saved when confirmed.
  def handle_event("edit_tags", _params, socket) do
    case chosen_subscription(socket) do
      nil ->
        {:noreply, socket}

      subscription ->
        tags = Tags.of(socket.assigns.current_account, subscription.id)

        {:noreply,
         assign(socket,
           tagging: %{subscription: subscription, chosen: Enum.map(tags, & &1.name), new: ""}
         )}
    end
  end

  def handle_event("tag_options", params, socket) do
    tagging = %{socket.assigns.tagging | chosen: params["tags"] || [], new: params["new"] || ""}
    {:noreply, assign(socket, :tagging, tagging)}
  end

  # Enter in the field saves what the form holds, as the button does.
  def handle_event("submit_edit_tags", params, socket) do
    {:noreply, socket} = handle_event("tag_options", params, socket)
    handle_event("confirm_edit_tags", %{}, socket)
  end

  def handle_event("cancel_edit_tags", _params, socket),
    do: {:noreply, socket |> assign(:tagging, nil) |> push_event("focus", %{id: "edit-tags"})}

  # A second press arrives after the first has closed the dialog.
  def handle_event("confirm_edit_tags", _params, %{assigns: %{tagging: nil}} = socket),
    do: {:noreply, socket}

  # Several new tags may be typed at once, set apart by commas.
  def handle_event("confirm_edit_tags", _params, socket) do
    %{subscription: subscription, chosen: chosen, new: new} = socket.assigns.tagging
    names = chosen ++ String.split(new, ",")
    Tags.set(socket.assigns.current_account, subscription.id, names)
    {:noreply, assign(socket, :tagging, nil)}
  end

  # A tag is renamed in its own header. A name another tag holds is said in the dialog, which
  # stays open; a new name moves the address along with it.
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
      # Read at once, so the address the page checks itself against already has the new name.
      {:ok, _renamed} ->
        socket = socket |> assign(:renaming, nil) |> SikioWeb.Sidebar.refresh()
        {:noreply, push_patch(socket, to: address(socket, socket.assigns.filters), replace: true)}

      {:error, reason} ->
        {:noreply, update(socket, :renaming, &%{&1 | error: rename_error(reason)})}
    end
  end

  # A tag is deleted after a question that names it. Its subscriptions stay.
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
     |> push_patch(to: SikioWeb.Sidebar.place_path("status", "new"))}
  end

  # A source is left after a question that names it, from the subscription the sidebar holds.
  def handle_event("unsubscribe", _params, socket) do
    case chosen_subscription(socket) do
      nil -> {:noreply, socket}
      subscription -> {:noreply, assign(socket, :unsubscribing, subscription)}
    end
  end

  def handle_event("cancel_unsubscribe", _params, socket),
    do:
      {:noreply,
       socket |> assign(:unsubscribing, nil) |> push_event("focus", %{id: "unsubscribe"})}

  # The source's list has nothing left to show, so the page goes to what is new.
  def handle_event("confirm_unsubscribe", _params, socket) do
    case Library.unsubscribe(socket.assigns.current_account, socket.assigns.unsubscribing.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:unsubscribing, nil)
         |> push_patch(to: SikioWeb.Sidebar.place_path("status", "new"))}

      _ ->
        {:noreply,
         socket
         |> assign(:unsubscribing, nil)
         |> put_flash(:error, gettext("Subscription not found."))}
    end
  end

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
         |> fetch_chapters(entry)
         |> assign(reading(socket, entry))
         |> assign(selected: entry, page_title: entry.title)}
    end
  end

  # Reading the notes is the costly part of the detail, and an event rereads the same item several
  # times a minute while it plays. Chapters and notes are read again only when the notes changed.
  # The chapters a publisher listed come out of the notes, so they show once, in their own box.
  # The chapters depend on the length as well, which a player may measure only later, and on
  # what the feed names, which may arrive after the item was opened.
  defp reading(socket, entry) do
    read = {entry.id, entry.description, length_of(entry), entry.chapters}

    if socket.assigns.read == read,
      do: Map.take(socket.assigns, [:notes, :chapters, :read]),
      else: Map.put(read_notes(entry), :read, read)
  end

  # The chapters and the notes beside them; see Sikio.Chapters.of/2.
  defp read_notes(entry) do
    {chapters, notes} = Chapters.of(entry, length_of(entry))
    %{chapters: chapters, notes: Notes.notes(notes, entry.description_format || :html)}
  end

  # A podcast's chapters file is fetched once somebody opens the item, and only when another item
  # is opened, not with every notification about the one that is.
  defp fetch_chapters(%{assigns: %{selected: %{id: id}}} = socket, %{id: id}), do: socket

  defp fetch_chapters(socket, %{chapters: nil, chapters_url: url} = entry) when is_binary(url) do
    if connected?(socket),
      do: start_async(socket, :chapters, fn -> {entry.id, Feeds.chapters(entry)} end),
      else: socket
  end

  defp fetch_chapters(socket, _entry), do: socket

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

  # Not reached or not a file: tried again the next time the item is opened.
  def handle_async(:chapters, _result, socket), do: {:noreply, socket}

  # The tally counts every place without a query. A search is counted by the database.
  defp total(socket, %{"q" => ""} = filters),
    do:
      socket.assigns.sidebar.counts
      |> Library.tally(filters, socket.assigns.sidebar.tag_feeds)
      |> Library.total(filters)

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
    counts = Library.tally(socket.assigns.sidebar.counts, %{}, socket.assigns.sidebar.tag_feeds)

    socket
    |> assign(
      empty?: subscriptions == [],
      entries: entries,
      more?: length(entries) == limit,
      counts: counts,
      total: total(socket, filters),
      heading: heading(filters, socket.assigns.sidebar),
      filtered?: place_of(filters) != filters
    )
  end

  # The view's name: the source or the tag when one is chosen, otherwise the status.
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
      tab={@tab}
      title={if(@selected, do: @selected.title, else: @heading)}
      back={back(@selected, @tab, @heading, list_path(@filters, @sidebar.titles))}
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
          phx-mounted={JS.ignore_attributes("style")}
          class={[
            "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent",
            "min-w-0 lg:h-svh lg:overflow-y-auto lg:overscroll-none lg:border-r lg:border-line lg:bg-surface",
            @selected && "hidden lg:block"
          ]}
        >
          <%!-- Heading, search and filters stay in view while the list scrolls beneath them. --%>
          <div
            id="list-head"
            phx-hook="ListHead"
            class="lg:sticky lg:top-0 lg:z-10 lg:border-b lg:border-line lg:bg-surface"
          >
            <%!-- The heading has the head's whole width, so a long source's name wraps late. The
                 count and the actions share the line beneath it. --%>
            <div class="flex flex-col gap-0.5 px-6 pt-6 pb-4 sm:px-12 lg:px-4 lg:pt-5 lg:pb-3">
              <h1
                id="library-heading"
                data-large-title={!@selected}
                class="text-title font-semibold"
              >
                {@heading}
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
                  <%!-- An empty list or one of finished items has nothing to offer the double check. --%>
                  <button
                    :if={@total > 0 and @filters["status"] != "completed"}
                    id="mark-all"
                    type="button"
                    aria-label={gettext("Mark all as finished")}
                    title={gettext("Mark all as finished")}
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
                  <button
                    :if={@filters["source"] != ""}
                    id="edit-tags"
                    type="button"
                    aria-label={gettext("Tags")}
                    title={gettext("Tags")}
                    phx-click="edit_tags"
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
                  >
                    <Lucideicons.tag aria-hidden="true" class="size-4.5" />
                  </button>
                  <button
                    :if={@filters["source"] != ""}
                    id="unsubscribe"
                    type="button"
                    aria-label={gettext("Unsubscribe")}
                    title={gettext("Unsubscribe")}
                    phx-click="unsubscribe"
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
                  >
                    <Lucideicons.unplug aria-hidden="true" class="size-4.5" />
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
            <.confirm_dialog
              :if={@marking}
              name="mark-all"
              title={gettext("Mark all as finished?")}
              confirm_label={gettext("Mark finished")}
            >
              <p>
                {ngettext(
                  "%{count} item in this list will be marked as finished.",
                  "%{count} items in this list will be marked as finished.",
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
                <%!-- Shown by the hook only while the player holds an item. --%>
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
              :if={@tagging}
              name="edit-tags"
              title={gettext("Tags for %{title}", title: @tagging.subscription.feed.title)}
              confirm_label={gettext("Save tags")}
            >
              <form
                id="tags-form"
                phx-change="tag_options"
                phx-submit="submit_edit_tags"
                class="flex flex-col gap-2"
              >
                <input type="hidden" name="tags[]" value="" />
                <label
                  :for={tag <- @sidebar.tags}
                  class="flex items-center gap-2.5 text-label text-ink"
                >
                  <input
                    type="checkbox"
                    name="tags[]"
                    value={tag.name}
                    checked={tag.name in @tagging.chosen}
                    class="size-4 accent-accent"
                  />
                  {tag.name}
                </label>
                <input
                  type="text"
                  name="new"
                  value={@tagging.new}
                  maxlength="80"
                  placeholder={gettext("New tag, or several set apart by commas")}
                  aria-label={gettext("New tag")}
                  class="mt-1 min-h-10 rounded-control border border-line bg-surface px-3 text-label text-ink placeholder:text-muted focus-visible:outline-2 focus-visible:outline-accent"
                />
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
                  class="min-h-10 rounded-control border border-line bg-surface px-3 text-label text-ink focus-visible:outline-2 focus-visible:outline-accent"
                />
                <p :if={@renaming.error} class="text-label text-danger">{@renaming.error}</p>
              </form>
            </.confirm_dialog>
            <.confirm_dialog
              :if={@deleting}
              name="delete-tag"
              title={gettext("Delete %{name}?", name: @deleting.name)}
              confirm_label={gettext("Delete tag")}
            >
              <p>{gettext("The subscriptions stay; only the tag goes.")}</p>
            </.confirm_dialog>
            <.confirm_dialog
              :if={@unsubscribing}
              name="unsubscribe"
              title={gettext("Unsubscribe from %{title}?", title: @unsubscribing.feed.title)}
              confirm_label={gettext("Unsubscribe")}
            >
              <p>
                {gettext(
                  "Its items leave your library. Your progress stays, should you subscribe again."
                )}
              </p>
            </.confirm_dialog>
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
            <%!-- Within a source or a tag the statuses narrow the list; elsewhere they are places. --%>
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
                <.segments label={gettext("Status")}>
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
            <.list_row
              :for={row <- grouped(@entries, @filters, @time_zone_offset)}
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

  # One item: its picture, source, title and where the reader stands. The picture comes through
  # Sikio's own host and tries the item's picture, its source's artwork, then a mark for its kind,
  # so every row keeps its shape.
  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :to, :string, required: true
  attr :selected, :boolean, required: true
  attr :source_shown, :boolean, default: true, doc: "false within the source's own list"

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
          <span :if={@source_shown} data-source class="truncate text-meta font-semibold text-accent">
            {@entry.feed.title}
          </span>
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
            <span :if={@entry.published_at} class="font-mono tracking-tighter">
              {short_date(@entry.published_at)}
            </span>
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

  # The place the filters narrow: a source or a tag, or else a view by its status.
  defp place_of(%{"source" => source} = filters) when source != "",
    do: %{filters | "status" => ""}

  defp place_of(%{"tag" => tag} = filters) when tag != "",
    do: %{filters | "status" => ""}

  defp place_of(filters), do: filters

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

  defp detail(assigns) do
    entry = assigns.entry

    assigns =
      assign(assigns,
        status: status(entry),
        runtime: runtime(length_of(entry)),
        original: original(entry)
      )

    ~H"""
    <%!-- A card from lg. A phone shows the item on the page itself. A video spans either. --%>
    <article class="@container flex flex-col gap-4 lg:rounded-2xl lg:bg-surface lg:p-6 lg:shadow-sm lg:ring-1 lg:ring-line">
      <div class="flex items-start gap-3">
        <%!-- The source's picture through this host, as the sidebar shows it, or its initial. --%>
        <span
          id="item-source-mark"
          aria-hidden="true"
          class="flex size-8 shrink-0 items-center justify-center overflow-hidden rounded-full bg-accent/15 text-meta font-semibold text-accent"
        >
          <img
            :if={@entry.feed.icon_url}
            src={Pictures.path([@entry.feed.icon_url], kind_mark(@entry.feed))}
            alt=""
            class="size-full object-cover"
          />
          <span :if={!@entry.feed.icon_url}>{initial(@entry.feed.title)}</span>
        </span>
        <div class="flex min-w-0 grow flex-col">
          <p class="truncate text-label font-semibold text-accent">{@entry.feed.title}</p>
          <p
            id="playback-status"
            aria-live="polite"
            class="meta-dots flex flex-wrap items-center text-meta text-muted"
          >
            <span>{medium_label(@entry)}</span>
            <span :if={@entry.published_at} class="font-mono tracking-tighter">
              {date(@entry.published_at)}
            </span>
            <span :if={@runtime} class="font-mono tracking-tighter">{@runtime}</span>
            <span><.status_mark entry={@entry} status={@status} /></span>
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
        class={video?(@entry) && "-mx-6 sm:-mx-12 lg:-mx-6"}
      >
        <button
          :if={video?(@entry)}
          id="start-playback"
          type="button"
          phx-click={JS.dispatch("sikio:play", detail: %{id: @entry.id})}
          class="group block w-full text-left focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          <span class="relative block aspect-video w-full overflow-hidden bg-line">
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
        <h2 data-large-title class="text-[26px] leading-tight font-semibold">{@entry.title}</h2>
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
