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
  alias Sikio.Tags
  alias SikioWeb.MediaComponents

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
      |> Enum.sort_by(&String.downcase(MediaComponents.source_name(&1) || ""))

    tags = Tags.list(account)

    # Addresses name a source or a tag by its title as well as its number.
    titles =
      Map.new(sources, &{&1.feed_id, MediaComponents.source_name(&1)})
      |> Map.merge(Map.new(tags, &{{:tag, &1.id}, &1.name}))

    assign(socket, :sidebar, %{
      counts: Library.counts(account),
      sources: sources,
      tags: tags,
      tag_feeds: Tags.feeds(account),
      titles: titles
    })
  end

  # A list as the address spells it. The inbox is the place without one within a source or a tag,
  # and every item is `all`. The segments from before the inbox still read as what they meant.
  @statuses %{"inbox" => "inbox", "queue" => "queue", "heard" => "history"}
  @status_segments Map.new(@statuses, fn {status, segment} -> {segment, status} end)
                   |> Map.merge(%{
                     "new" => "inbox",
                     "in-progress" => "queue",
                     "completed" => "heard"
                   })

  @doc """
  The library's address: the list on screen as a path, the item shown beside it appended.

  A source is named by its number and its title, an item by its number and its title, so an
  address reads as what it shows while only the number is looked up. `feed_titles` maps a
  source's number to its title, and `item` is an entry, an id or nil. A search is a filter
  within a list and stays in the query.

      /inbox  /queue  /history  /all
      /feeds/106-metacheles-tonspur  /feeds/106-metacheles-tonspur/all
      /inbox/4056-ki-verfassung  /feeds/106-metacheles-tonspur/4056-ki-verfassung

  Built by hand rather than with `~p`: the router declares every shape, and this module is
  where an address is spelled and read.
  """
  def library_path(filters, item \\ nil, feed_titles \\ %{}) do
    path = "/" <> Enum.join(place(filters, feed_titles) ++ item_segment(item), "/")

    case filters
         |> Map.take(["q"])
         |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) do
      [] -> path
      query -> path <> "?" <> URI.encode_query(query)
    end
  end

  # A source and a tag are places of their own, beneath which a status narrows the list.
  defp place(filters, titles) do
    status = Map.get(@statuses, filters["status"])
    within = if status == "inbox", do: [], else: [status || "all"]

    cond do
      (filters["source"] || "") != "" ->
        source = filters["source"]
        ["feeds", named(source, Map.get(titles, String.to_integer(source))) | within]

      (filters["tag"] || "") != "" ->
        tag = filters["tag"]
        ["tags", named(tag, Map.get(titles, {:tag, String.to_integer(tag)})) | within]

      true ->
        [status || "all"]
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
        [] ->
          {%{"status" => "inbox"}, nil}

        [place, named] when place in ["feeds", "tags"] ->
          {within(place, named, "inbox"), nil}

        [place, named, segment] when place in ["feeds", "tags"] ->
          below(place, named, segment)

        [place, named, status, item] when place in ["feeds", "tags"] ->
          {within(place, named, status), item_id(item)}

        [status] ->
          {%{"status" => status(status)}, nil}

        [status, item] ->
          {%{"status" => status(status)}, item_id(item)}
      end

    {Library.normalize_filters(Map.merge(Map.take(query, ["q"]), place)), item}
  end

  # Below a source or a tag the next segment is a list, or else an item of its inbox.
  defp below(place, named, segment) do
    if Map.has_key?(@status_segments, segment) or segment == "all",
      do: {within(place, named, segment), nil},
      else: {within(place, named, "inbox"), item_id(segment)}
  end

  defp within("feeds", feed, status), do: %{"source" => number(feed), "status" => status(status)}
  defp within("tags", tag, status), do: %{"tag" => number(tag), "status" => status(status)}

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

  @doc "A subscription's page in the library, named as its member named it."
  def source_path(subscription) do
    feed_id = subscription.feed_id

    place_path("source", to_string(feed_id), %{
      feed_id => MediaComponents.source_name(subscription)
    })
  end

  @doc """
  The library's address for one place: a view by its status, a source or a tag.

  The sidebar and the phone's chips are where the reader is, not filters to combine, so nothing
  chosen before comes along. A source or a tag opens on its inbox, as the library does.
  """
  def place_path(key, value, feed_titles \\ %{})

  def place_path(key, value, feed_titles) when key in ["source", "tag"],
    do: library_path(%{key => value, "status" => "inbox"}, nil, feed_titles)

  def place_path(key, value, feed_titles), do: library_path(%{key => value}, nil, feed_titles)

  @doc """
  Whether `filters` show that place, which is what marks it as current.

  The list may narrow a place further: by status within a source or a tag.
  """
  def place?(filters, "source", id), do: filters["source"] == id
  def place?(filters, "tag", id), do: filters["tag"] == id

  def place?(filters, "status", value),
    do:
      (filters["source"] || "") == "" and (filters["tag"] || "") == "" and
        (filters["status"] || "") == value

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
  defp library_event?({:tags_changed, _subscription_id}), do: true
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
