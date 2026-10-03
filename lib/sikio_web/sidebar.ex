# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Sidebar do
  @moduledoc """
  What the reader's sidebar shows: the sources and how many items each view holds.

  Mounted for every member page, so a page that is not the library still shows where things
  stand. It listens to the library's events itself and refreshes on them.

  New episodes arrive in bursts, from an import or a poll of many feeds. The first one refreshes
  at once and opens a window of a second. Those that follow inside it share one refresh at its
  end, which opens the next window.

  A view that wants the events as well defines `handle_library_event/2`, which answers like
  `handle_info/2`. Its own `handle_info/2` never sees them.
  """
  use SikioWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]

  alias Sikio.Library
  alias Sikio.Library.Events

  @window_ms 1000

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe(socket.assigns.current_account)
      Events.subscribe_updates(socket.assigns.current_account)
    end

    {:cont,
     socket
     |> put_private(:library_window, :closed)
     |> refresh()
     |> attach_hook(:sidebar, :handle_info, &follow/2)}
  end

  @doc "Reads the counts and sources again."
  def refresh(socket) do
    account = socket.assigns.current_account

    sources =
      account
      |> Library.subscriptions()
      |> Enum.sort_by(&String.downcase(&1.feed.title || ""))

    # Addresses name a source by its title as well as its number.
    titles = Map.new(sources, &{&1.feed_id, &1.feed.title})
    assign(socket, :sidebar, %{counts: Library.counts(account), sources: sources, titles: titles})
  end

  # A status as the address spells it. What is new is the place without a status, at the
  # library's front as within a source, and every item is `all`.
  @statuses %{"new" => "new", "in_progress" => "in-progress", "completed" => "completed"}
  @status_segments Map.new(@statuses, fn {status, segment} -> {segment, status} end)

  @doc """
  The library's address: the list on screen as a path, the item shown beside it appended.

  A source is named by its number and its title, an item by its number and its title, so an
  address reads as what it shows while only the number is looked up. `feed_titles` maps a
  source's number to its title, and `item` is an entry, an id or nil. Medium and search are
  filters within a list and stay in the query.

      /new  /in-progress  /completed  /all
      /feeds/106-metacheles-tonspur  /feeds/106-metacheles-tonspur/all
      /new/4056-ki-verfassung  /feeds/106-metacheles-tonspur/4056-ki-verfassung

  Built by hand rather than with `~p`: the router declares every shape, and this module is
  where an address is spelled and read.
  """
  def library_path(filters, item \\ nil, feed_titles \\ %{}) do
    path = "/" <> Enum.join(place(filters, feed_titles) ++ item_segment(item), "/")

    case filters
         |> Map.take(["kind", "q"])
         |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) do
      [] -> path
      query -> path <> "?" <> URI.encode_query(query)
    end
  end

  defp place(filters, feed_titles) do
    status = Map.get(@statuses, filters["status"])

    case filters["source"] do
      source when source in [nil, ""] ->
        [status || "all"]

      source ->
        title = Map.get(feed_titles, String.to_integer(source))

        segment = if status == "new", do: [], else: [status || "all"]
        ["feeds", named(source, title) | segment]
    end
  end

  defp item_segment(nil), do: []
  defp item_segment(%{id: id, title: title}), do: [named(id, title)]
  defp item_segment(id), do: [to_string(id)]

  defp named(number, title) do
    case slug(title) do
      "" -> to_string(number)
      slug -> "#{number}-#{slug}"
    end
  end

  @umlauts %{"ä" => "ae", "ö" => "oe", "ü" => "ue", "ß" => "ss"}

  @doc "A title as an address spells it: lower case letters and digits joined by dashes."
  def slug(nil), do: ""

  def slug(title) do
    title
    |> String.downcase()
    |> String.replace(Map.keys(@umlauts), &Map.fetch!(@umlauts, &1))
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> String.trim_trailing("-")
  end

  @doc """
  The filters and the item an address names, read back from its path and query.

  Only the leading number of a source or an item is read. An item that names no number answers
  `:invalid`, a source that names none shows every source.
  """
  def read_path(path, query) do
    {place, item} =
      case String.split(path, "/", trim: true) do
        [] -> {%{"status" => "new"}, nil}
        ["feeds", feed] -> {feed_status(feed, "new"), nil}
        ["feeds", feed, segment] -> feed_place(feed, segment)
        ["feeds", feed, status, item] -> {feed_status(feed, status), item_id(item)}
        [status] -> {%{"status" => status(status)}, nil}
        [status, item] -> {%{"status" => status(status)}, item_id(item)}
      end

    {Library.normalize_filters(Map.merge(Map.take(query, ["kind", "q"]), place)), item}
  end

  # Below a source the next segment is a status, or else an item of what is new.
  defp feed_place(feed, segment) do
    if Map.has_key?(@status_segments, segment) or segment == "all",
      do: {feed_status(feed, segment), nil},
      else: {feed_status(feed, "new"), item_id(segment)}
  end

  defp feed_status(feed, status), do: %{"source" => number(feed), "status" => status(status)}

  defp status(segment), do: Map.get(@status_segments, segment, "")

  defp number(segment) do
    case Integer.parse(segment) do
      {number, _title} when number > 0 -> Integer.to_string(number)
      _ -> ""
    end
  end

  defp item_id(segment) do
    case number(segment) do
      "" -> :invalid
      id -> id
    end
  end

  @doc """
  The library's address for one place: a view by its status, or a source.

  The sidebar and the phone's chips are where the reader is, not filters to combine, so nothing
  chosen before comes along. A source opens on what is new in it, as the library does.
  """
  def place_path(key, value, feed_titles \\ %{})

  def place_path("source", value, feed_titles),
    do: library_path(%{"source" => value, "status" => "new"}, nil, feed_titles)

  def place_path(key, value, feed_titles), do: library_path(%{key => value}, nil, feed_titles)

  @doc """
  Whether `filters` show that place, which is what marks it as current.

  The list may narrow a place further: by medium anywhere, and by status within a source.
  """
  def place?(filters, "source", id), do: filters["source"] == id

  def place?(filters, "status", value),
    do: (filters["source"] || "") == "" and (filters["status"] || "") == value

  # The window is private, because an assign would render the page for nothing.
  defp follow(:library_changed, %{private: %{library_window: :closed}} = socket),
    do: {:halt, socket |> refresh() |> passed_on(:library_changed) |> open_window()}

  defp follow(:library_changed, socket),
    do: {:halt, put_private(socket, :library_window, :pending)}

  defp follow(:library_window_closed, %{private: %{library_window: :pending}} = socket),
    do: follow(:library_changed, put_private(socket, :library_window, :closed))

  defp follow(:library_window_closed, socket),
    do: {:halt, put_private(socket, :library_window, :closed)}

  defp follow(message, socket) do
    if library_event?(message),
      do: {:halt, socket |> refresh_for(message) |> passed_on(message)},
      else: {:cont, socket}
  end

  defp open_window(socket) do
    Process.send_after(self(), :library_window_closed, @window_ms)
    put_private(socket, :library_window, :open)
  end

  # The counts follow statuses, and a player saves its place every few seconds without changing
  # one. Only a changed status is worth reading them again.
  defp refresh_for(socket, {:playback_progressed, _state}), do: socket
  defp refresh_for(socket, _message), do: refresh(socket)

  defp library_event?({:playback_progressed, _state}), do: true
  defp library_event?({:playback_changed, _state}), do: true
  defp library_event?({:subscription_removed, _feed_id}), do: true
  defp library_event?({:playback_marked, _count}), do: true
  defp library_event?(_message), do: false

  defp passed_on(socket, message) do
    if function_exported?(socket.view, :handle_library_event, 2) do
      {:noreply, socket} = socket.view.handle_library_event(message, socket)
      socket
    else
      socket
    end
  end
end
