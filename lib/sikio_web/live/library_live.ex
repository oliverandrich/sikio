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
       editing: nil,
       renaming: nil,
       deleting: nil,
       chosen_for_width: nil,
       time_zone_offset: time_zone_offset(get_connect_params(socket)),
       tab: :inbox,
       play_on: Playback.play_on?(socket.assigns.current_account)
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
            editing: nil,
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

  # Where a source's new episodes may go, as its dialog offers it.
  defp deliveries,
    do: [
      {"inbox", gettext("The inbox")},
      {"queue", gettext("The end of the queue")},
      {"skip", gettext("The archive, unheard")}
    ]

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
  # The queue runs by its own order and has no dates to group by.
  defp grouped(entries, %{"status" => "queue"}, _offset), do: Enum.map(entries, &{:entry, &1})

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
  attr :variant, :string, default: "primary", doc: "danger when the answer cannot be undone"
  attr :wide, :boolean, default: false, doc: "room for a form rather than a question"
  slot :inner_block, required: true
  slot :aside, doc: "another way out, at the left of the buttons"

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
      class={[
        "m-auto rounded-lg border border-line bg-surface text-ink shadow-2xl outline-none backdrop:bg-black/30",
        if(@wide, do: "w-[min(34rem,calc(100vw-2rem))]", else: "w-[min(28rem,calc(100vw-2rem))]")
      ]}
    >
      <div class="p-5 sm:p-6">
        <h2 id={"#{@name}-heading"} class="text-[17px] leading-6 font-semibold">{@title}</h2>
        <div class={["text-sm text-muted", if(@wide, do: "mt-5", else: "mt-2")]}>
          {render_slot(@inner_block)}
        </div>
      </div>
      <%!-- The answers in a band of their own. On a phone they stack, the confirming one on top;
      from sm they stand in a row from the right, another way out at the far left. --%>
      <div
        id={"#{@name}-actions"}
        class="flex flex-col gap-2 rounded-b-lg border-t border-line bg-ground px-5 py-4 sm:flex-row-reverse sm:items-center sm:gap-3 sm:px-6"
      >
        <.button
          id={"confirm-#{@name}"}
          type="button"
          variant={@variant}
          phx-click={"confirm_#{@event}"}
        >
          {@confirm_label}
        </.button>
        <.button id={"cancel-#{@name}"} type="button" phx-click={"cancel_#{@event}"}>
          {gettext("Cancel")}
        </.button>
        <div :if={@aside != []} class="flex justify-center sm:mr-auto">{render_slot(@aside)}</div>
      </div>
    </dialog>
    """
  end

  # A text field inside a dialog, at a finger's height on a phone and a button's beside a mouse.
  defp dialog_field,
    do:
      "min-h-11 rounded-control border border-edge bg-surface px-3 text-sm text-ink placeholder:text-muted sm:min-h-9 focus-visible:outline-2 focus-visible:outline-accent"

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
      movable={@filters["status"] == "queue"}
    />
    """
  end

  # A phone's tab: searching is Search, the inbox and the queue are their own tabs, every other
  # place is the Library's.
  defp tab("/search", _filters), do: :search
  defp tab(_path, %{"q" => q}) when q != "", do: :search
  defp tab(_path, %{"status" => "inbox", "source" => "", "tag" => ""}), do: :inbox
  defp tab(_path, %{"status" => "queue", "source" => "", "tag" => ""}), do: :queue
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

  defp nothing(%{"status" => "inbox"}),
    do: {gettext("Nothing new."), gettext("You’re all caught up.")}

  defp nothing(%{"status" => "queue"}),
    do:
      {gettext("Nothing in the queue."),
       gettext("What you play or queue waits here, in your order.")}

  defp nothing(%{"status" => "heard"}), do: {gettext("Nothing heard yet."), nil}

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
        {:noreply, put_flash(socket, :info, gettext("Nothing here is left to archive."))}

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

  # A source's own dialog: a name of the reader's own, where its new episodes go, its tags to tick
  # and a field for new ones, and the way to leave it. What is typed and ticked is followed as it
  # changes, and saved when confirmed.
  def handle_event("edit_subscription", _params, socket) do
    case chosen_subscription(socket) do
      nil ->
        {:noreply, socket}

      subscription ->
        tags = Tags.of(socket.assigns.current_account, subscription.id)

        {:noreply,
         assign(socket,
           editing: %{
             subscription: subscription,
             name: subscription.name || "",
             delivery: Atom.to_string(subscription.delivery),
             chosen: Enum.map(tags, & &1.name),
             new: ""
           }
         )}
    end
  end

  def handle_event("subscription_options", params, socket) do
    editing = %{
      socket.assigns.editing
      | name: params["name"] || "",
        delivery: params["delivery"] || socket.assigns.editing.delivery,
        chosen: params["tags"] || [],
        new: params["new"] || ""
    }

    {:noreply, assign(socket, :editing, editing)}
  end

  # Enter in a field saves what the form holds, as the button does.
  def handle_event("submit_edit_subscription", params, socket) do
    {:noreply, socket} = handle_event("subscription_options", params, socket)
    handle_event("confirm_edit_subscription", %{}, socket)
  end

  def handle_event("cancel_edit_subscription", _params, socket),
    do:
      {:noreply,
       socket |> assign(:editing, nil) |> push_event("focus", %{id: "edit-subscription"})}

  # A second press arrives after the first has closed the dialog.
  def handle_event("confirm_edit_subscription", _params, %{assigns: %{editing: nil}} = socket),
    do: {:noreply, socket}

  # Several new tags may be typed at once, set apart by commas.
  def handle_event("confirm_edit_subscription", _params, socket) do
    %{subscription: subscription, name: name, delivery: delivery, chosen: chosen, new: new} =
      socket.assigns.editing

    account = socket.assigns.current_account

    {:ok, _} =
      Library.update_subscription(account, subscription.id, %{name: name, delivery: delivery})

    Tags.set(account, subscription.id, chosen ++ String.split(new, ","))
    {:noreply, socket |> assign(:editing, nil) |> SikioWeb.Sidebar.refresh()}
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
     |> push_patch(to: SikioWeb.Sidebar.place_path("status", "inbox"))}
  end

  # A source is left after a question that names it, from the subscription the sidebar holds.
  def handle_event("unsubscribe", _params, socket) do
    case chosen_subscription(socket) do
      nil -> {:noreply, socket}
      subscription -> {:noreply, assign(socket, unsubscribing: subscription, editing: nil)}
    end
  end

  def handle_event("cancel_unsubscribe", _params, socket),
    do:
      {:noreply,
       socket |> assign(:unsubscribing, nil) |> push_event("focus", %{id: "edit-subscription"})}

  # The source's list has nothing left to show, so the page goes to what is new.
  def handle_event("confirm_unsubscribe", _params, socket) do
    case Library.unsubscribe(socket.assigns.current_account, socket.assigns.unsubscribing.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:unsubscribing, nil)
         |> push_patch(to: SikioWeb.Sidebar.place_path("status", "inbox"))}

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

  def handle_event("play_on", _params, socket) do
    {:ok, preference} =
      Playback.play_on(socket.assigns.current_account, !socket.assigns.play_on)

    {:noreply, assign(socket, :play_on, preference.play_on)}
  end

  # A row dropped or moved by a key; the broadcast reads the queue again in its new order.
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

  # The change is broadcast, and the broadcast reloads the list along with the sidebar.
  defp changed(socket, result) do
    case result do
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

  # The Search tab searches every item and is called what it does. A search within one place keeps
  # that place's name.
  defp name(:search, %{"status" => "", "source" => "", "tag" => ""}, _heading),
    do: gettext("Search")

  defp name(_tab, _filters, heading), do: heading

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
                  <%!-- An empty list or one of finished items has nothing to offer the double check. --%>
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
                  <%!-- The source's own settings: its name, where new episodes go, its tags and
                       the way to leave it. --%>
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
                  <%!-- Whether the player goes on with the queue when an item ends, said in words
                       beside a switch. --%>
                  <button
                    :if={@filters["status"] == "queue"}
                    id="play-on"
                    type="button"
                    role="switch"
                    aria-checked={to_string(@play_on)}
                    title={gettext("Play on with the queue")}
                    phx-click="play_on"
                    class="group mr-1 flex min-h-9 shrink-0 cursor-pointer items-center gap-2 rounded-full pl-1 text-label text-muted hover:text-ink aria-checked:text-ink"
                  >
                    {gettext("Play on")}
                    <span class="relative h-5 w-9 rounded-full bg-track transition-colors group-aria-checked:bg-accent">
                      <span class="absolute top-0.5 left-0.5 size-4 rounded-full bg-surface shadow-xs transition-transform group-aria-checked:translate-x-4"></span>
                    </span>
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
              :if={@editing}
              name="edit-subscription"
              title={source_name(@editing.subscription)}
              confirm_label={gettext("Save")}
              wide
            >
              <form
                id="subscription-form"
                phx-change="subscription_options"
                phx-submit="submit_edit_subscription"
                class="flex flex-col gap-5"
              >
                <label class="flex flex-col gap-1.5 text-label font-semibold text-ink">
                  {gettext("Name")}
                  <input
                    type="text"
                    name="name"
                    value={@editing.name}
                    maxlength="200"
                    placeholder={@editing.subscription.feed.title}
                    class={[dialog_field(), "font-normal"]}
                  />
                </label>
                <fieldset class="flex flex-col gap-2">
                  <legend class="mb-1.5 text-label font-semibold text-ink">
                    {gettext("New episodes go to")}
                  </legend>
                  <label
                    :for={{value, label} <- deliveries()}
                    class="flex items-center gap-2.5 text-label text-ink"
                  >
                    <input
                      type="radio"
                      name="delivery"
                      value={value}
                      checked={@editing.delivery == value}
                      class="size-4 accent-accent"
                    />
                    {label}
                  </label>
                </fieldset>
                <fieldset class="flex flex-col gap-2">
                  <legend class="mb-1.5 text-label font-semibold text-ink">{gettext("Tags")}</legend>
                  <input type="hidden" name="tags[]" value="" />
                  <label
                    :for={tag <- @sidebar.tags}
                    class="flex items-center gap-2.5 text-label text-ink"
                  >
                    <input
                      type="checkbox"
                      name="tags[]"
                      value={tag.name}
                      checked={tag.name in @editing.chosen}
                      class="size-4 accent-accent"
                    />
                    {tag.name}
                  </label>
                  <input
                    type="text"
                    name="new"
                    value={@editing.new}
                    maxlength="80"
                    placeholder={gettext("New tag, or several set apart by commas")}
                    aria-label={gettext("New tag")}
                    class={[dialog_field(), "mt-1"]}
                  />
                </fieldset>
              </form>
              <%!-- Leaving asks once more, in a question of its own. --%>
              <:aside>
                <button
                  id="unsubscribe"
                  type="button"
                  phx-click="unsubscribe"
                  class="inline-flex min-h-11 cursor-pointer items-center gap-2 text-sm font-semibold text-danger hover:underline sm:min-h-9"
                >
                  <Lucideicons.unplug aria-hidden="true" class="size-4" />
                  {gettext("Unsubscribe")}
                </button>
              </:aside>
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
            <.confirm_dialog
              :if={@unsubscribing}
              name="unsubscribe"
              title={gettext("Unsubscribe from %{title}?", title: source_name(@unsubscribing))}
              confirm_label={gettext("Unsubscribe")}
              variant="danger"
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
            class="mx-6 rounded-xl bg-surface p-8 ring-1 ring-line sm:mx-12 lg:m-4"
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
            phx-hook="QueueSort"
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
  attr :movable, :boolean, default: false, doc: "whether the row carries a handle, in the queue"

  defp entry_row(assigns) do
    assigns =
      assign(assigns, status: status(assigns.entry), runtime: runtime(length_of(assigns.entry)))

    ~H"""
    <article
      id={@id}
      data-status={@status}
      class={[
        "border-b border-line last:border-b-0 lg:last:border-b",
        @movable && "flex items-stretch",
        @selected && "bg-selection"
      ]}
    >
      <.link
        id={"play-#{@entry.id}"}
        patch={@to}
        aria-current={@selected && "true"}
        class={[
          "flex min-w-0 grow gap-3 px-6 py-3 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent sm:px-12 lg:px-4",
          @movable && "pr-0 sm:pr-0 lg:pr-0",
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
          <span :if={@source_shown} data-source class="truncate text-meta font-semibold text-muted">
            {source_name(@entry)}
          </span>
          <span class={[
            "mb-auto line-clamp-2 text-body",
            @status in [:heard, :archived] && "text-muted",
            @status not in [:heard, :archived] && "font-semibold text-ink"
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
      <%!-- Dragged, or moved a place with the arrow keys; see assets/js/queue_sort.mjs. --%>
      <button
        :if={@movable}
        id={"move-#{@entry.id}"}
        type="button"
        data-move={@entry.id}
        aria-label={gettext("Move %{title} in the queue", title: @entry.title)}
        title={gettext("Drag, or use the arrow keys")}
        class="flex w-11 shrink-0 cursor-grab touch-none items-center justify-center text-muted hover:text-ink focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent sm:w-14"
      >
        <Lucideicons.grip_vertical aria-hidden="true" class="size-5" />
      </button>
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
      class="inline-flex min-h-8 items-center rounded-full border border-line bg-surface px-3 text-label text-ink hover:bg-ground aria-[current=true]:border-transparent aria-[current=true]:bg-accent aria-[current=true]:font-semibold aria-[current=true]:text-on-accent"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :entry, :map, required: true
  attr :again, :boolean, required: true, doc: "the item was heard and goes in once more"

  # The way into the queue, at its head or its end.
  defp queue_menu(assigns) do
    ~H"""
    <.item_menu
      id="queue-menu"
      label={if @again, do: gettext("Queue again"), else: gettext("Add to queue")}
      named
    >
      <:icon><Lucideicons.list_plus aria-hidden="true" class="size-4.5" /></:icon>
      <.menu_item id="queue-first" push={{"queue", %{id: @entry.id, at: "first"}}} menu="queue-menu">
        <:icon><Lucideicons.list_start aria-hidden="true" class="size-4" /></:icon>
        {gettext("Play next")}
      </.menu_item>
      <.menu_item id="queue-last" push={{"queue", %{id: @entry.id, at: "last"}}} menu="queue-menu">
        <:icon><Lucideicons.list_end aria-hidden="true" class="size-4" /></:icon>
        {gettext("Play last")}
      </.menu_item>
    </.item_menu>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true

  attr :named, :boolean,
    default: false,
    doc: "shows its label beside a chevron, as the actions do"

  slot :icon
  slot :inner_block, required: true

  # A menu at the card's head. The card renders again while its item plays, so the menu keeps
  # its own open state, and a click elsewhere or Escape closes it.
  defp item_menu(assigns) do
    ~H"""
    <details
      id={@id}
      class="relative"
      phx-mounted={JS.ignore_attributes(["open"])}
      phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
      phx-window-keydown={JS.remove_attribute("open", to: "##{@id}")}
      phx-key="Escape"
    >
      <summary
        aria-label={!@named && @label}
        title={!@named && @label}
        class={[
          "flex h-9 cursor-pointer list-none items-center gap-1.5 rounded-full text-label font-medium text-muted hover:bg-ground hover:text-ink focus-visible:outline-2 focus-visible:outline-accent [[open]>&]:bg-ground [[open]>&]:text-ink",
          if(@named, do: "px-3", else: "w-9 justify-center")
        ]}
      >
        <%= if @named do %>
          {render_slot(@icon)}
          <span class="@max-2xl:sr-only">{@label}</span>
          <Lucideicons.chevron_down aria-hidden="true" class="size-3.5 @max-2xl:hidden" />
        <% else %>
          <Lucideicons.ellipsis aria-hidden="true" class="size-4.5" />
        <% end %>
      </summary>
      <%!-- Above the player, which the dock lays over the card's slot at z-40. --%>
      <div class="absolute top-full right-0 z-50 mt-1 flex w-max min-w-48 flex-col rounded-control border border-line bg-surface p-1 shadow-lg">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :menu, :string, required: true, doc: "the menu it closes"
  attr :push, :any, default: nil, doc: "the event and its values"
  attr :href, :string, default: nil, doc: "an address it opens in a new tab instead"
  slot :icon, required: true
  slot :inner_block, required: true

  defp menu_item(assigns) do
    assigns =
      assign(
        assigns,
        :class,
        "flex min-h-11 w-full cursor-pointer items-center gap-2.5 rounded-control px-3 text-left text-label text-ink hover:bg-ground sm:min-h-9"
      )

    ~H"""
    <a
      :if={@href}
      id={@id}
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      phx-click={JS.remove_attribute("open", to: "##{@menu}")}
      class={@class}
    >
      {render_slot(@icon)}{render_slot(@inner_block)}
    </a>
    <button
      :if={!@href}
      id={@id}
      type="button"
      phx-click={
        JS.push(elem(@push, 0), value: elem(@push, 1)) |> JS.remove_attribute("open", to: "##{@menu}")
      }
      class={@class}
    >
      {render_slot(@icon)}{render_slot(@inner_block)}
    </button>
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
      <Lucideicons.check :if={@status == :heard} aria-hidden="true" class="size-3.5" />
      <Lucideicons.archive :if={@status == :archived} aria-hidden="true" class="size-3.5" />
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
        queued: match?(%{playback: %{queue_rank: rank}} when not is_nil(rank), entry),
        runtime: runtime(length_of(entry)),
        original: original(entry)
      )

    ~H"""
    <%!-- A card from lg. A phone shows the item on the page itself. A video spans either. --%>
    <article class="@container flex flex-col gap-4 lg:rounded-xl lg:bg-surface lg:p-6 lg:ring-1 lg:ring-line">
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
          <span :if={!@entry.feed.icon_url}>{initial(source_name(@entry))}</span>
        </span>
        <div class="flex min-w-0 grow flex-col">
          <p class="truncate text-label font-semibold text-ink">{source_name(@entry)}</p>
          <p
            id="playback-status"
            aria-live="polite"
            class="meta-dots flex flex-wrap items-center text-meta text-muted"
          >
            <%!-- The medium leads to the original, as the menu's last entry does. --%>
            <span :if={!@original}>{medium_label(@entry)}</span>
            <span :if={@original}>
              <a
                href={elem(@original, 0)}
                target="_blank"
                rel="noopener noreferrer"
                class="underline decoration-signal decoration-[1.5px] underline-offset-3 [text-decoration-skip-ink:none] hover:text-ink hover:decoration-current"
              >
                {medium_label(@entry)}
              </a>
            </span>
            <span :if={@entry.published_at} class="font-mono tracking-tighter">
              {date(@entry.published_at)}
            </span>
            <span :if={@runtime} class="font-mono tracking-tighter">{@runtime}</span>
            <span><.status_mark entry={@entry} status={@status} /></span>
            <%!-- An icon alone, so starting an item never makes the line wrap and the card jump. --%>
            <span :if={@queued} title={gettext("In the queue")}>
              <Lucideicons.list_ordered aria-hidden="true" class="size-3.5" />
              <span class="sr-only">{gettext("In the queue")}</span>
            </span>
          </p>
        </div>
        <%!-- What comes next for the item stands at the head; the menu holds the rest. --%>
        <div id="item-actions" class="-mt-1 -mr-2 flex shrink-0 items-center gap-1">
          <.queue_menu :if={!@queued} entry={@entry} again={@status == :heard} />
          <.card_action
            :if={@queued and @status != :heard}
            id="mark-completed"
            label={mark_done_label(@entry)}
            phx-click="mark"
            phx-value-id={@entry.id}
            phx-value-status="heard"
          >
            <:icon><Lucideicons.check aria-hidden="true" class="size-4.5" /></:icon>
          </.card_action>
          <.card_action
            :if={!@queued and @status in [:new, :in_progress]}
            id="archive"
            label={gettext("Archive")}
            phx-click="mark"
            phx-value-id={@entry.id}
            phx-value-status="archived"
          >
            <:icon><Lucideicons.archive aria-hidden="true" class="size-4.5" /></:icon>
          </.card_action>
          <.item_menu id="item-more" label={gettext("More actions")}>
            <.menu_item
              :if={@queued}
              id="dequeue"
              push={{"dequeue", %{id: @entry.id}}}
              menu="item-more"
            >
              <:icon><Lucideicons.list_x aria-hidden="true" class="size-4" /></:icon>
              {gettext("Remove from the queue")}
            </.menu_item>
            <.menu_item
              :if={!@queued and @status != :heard}
              id="mark-completed"
              push={{"mark", %{id: @entry.id, status: "heard"}}}
              menu="item-more"
            >
              <:icon><Lucideicons.check aria-hidden="true" class="size-4" /></:icon>
              {mark_done_label(@entry)}
            </.menu_item>
            <.menu_item
              :if={@queued and @status != :heard}
              id="archive"
              push={{"mark", %{id: @entry.id, status: "archived"}}}
              menu="item-more"
            >
              <:icon><Lucideicons.archive aria-hidden="true" class="size-4" /></:icon>
              {gettext("Archive")}
            </.menu_item>
            <.menu_item
              :if={@status in [:heard, :archived]}
              id="mark-new"
              push={{"mark", %{id: @entry.id, status: "new"}}}
              menu="item-more"
            >
              <:icon><Lucideicons.inbox aria-hidden="true" class="size-4" /></:icon>
              {if @status == :heard,
                do: mark_new_label(@entry),
                else: gettext("Back to the inbox")}
            </.menu_item>
            <.menu_item
              :if={@original}
              id="open-original"
              href={elem(@original, 0)}
              menu="item-more"
            >
              <:icon><Lucideicons.external_link aria-hidden="true" class="size-4" /></:icon>
              {elem(@original, 1)}
            </.menu_item>
          </.item_menu>
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
