# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Sidebar do
  @moduledoc """
  Sidebar data: subscribed sources, tags and item counts per view.

  It is an `on_mount` hook of the `:members` live_session, so every member page has the sidebar.
  It subscribes to library PubSub events and refreshes the sidebar assign on them.

  New episodes arrive in bursts, from an import or a poll of many feeds.
  The first `:library_changed` refreshes at once and opens a one-second window.
  Further ones inside the window cause one refresh when it closes.
  That refresh opens the next window.

  A LiveView that needs the events defines `handle_library_event/2`.
  It returns the same tuples as `handle_info/2`. The view's own `handle_info/2` does not get them.
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

  @doc "Reloads the counts, sources and tags into the `:sidebar` assign."
  def refresh(socket) do
    account = socket.assigns.current_account

    sources =
      account
      |> Library.subscriptions()
      |> Enum.sort_by(&String.downcase(MediaComponents.source_name(&1) || ""))

    tags = Tags.list(account)

    # Titles for the slugs that URLs append to source and tag ids.
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

  # Maps status filters to URL segments. Within a source or tag the inbox has no segment.
  # No status filter is `all`. Older segments `new`, `in-progress` and `completed` still parse.
  @statuses %{"inbox" => "inbox", "queue" => "queue", "heard" => "history"}
  @status_segments Map.new(@statuses, fn {status, segment} -> {segment, status} end)
                   |> Map.merge(%{
                     "new" => "inbox",
                     "in-progress" => "queue",
                     "completed" => "heard"
                   })

  # The library starts on the queue, the list of items to play.
  @start "queue"

  @doc "Returns the start path. It is also the redirect target when the shown place is gone."
  def start_path, do: library_path(%{"status" => @start})

  @doc """
  Returns the library URL: the list's path with the selected item appended.

  Sources, tags and items appear as their id followed by a title slug. Parsing reads only the id.
  `feed_titles` maps feed ids and `{:tag, id}` to titles. `item` is an entry, an id or nil.
  The search text stays in the query string.

      /inbox  /queue  /history  /all
      /feeds/106-metacheles-tonspur  /feeds/106-metacheles-tonspur/all
      /inbox/4056-ki-verfassung  /feeds/106-metacheles-tonspur/4056-ki-verfassung

  Built by hand rather than with `~p`. The router declares every route shape.
  This module builds and parses the library URLs.
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

  # Source and tag paths take an optional status segment after the id.
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

  @doc "Returns a URL slug of at most 60 lowercase ASCII letters and digits joined by dashes."
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
  Parses a library path and query into `{filters, item}`.

  Only the leading number of a source, tag or item segment is read.
  An item segment without a number returns `:invalid` as the item.
  A source or tag segment without one leaves that filter empty, which lists every source.
  """
  def read_path(path, query) do
    {place, item} =
      case String.split(path, "/", trim: true) do
        [] ->
          {%{"status" => @start}, nil}

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

  # After a source or tag id, the next segment is a status, or else an item in its inbox.
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

  @doc "Returns a subscription's library path, with a slug of its display name."
  def source_path(subscription) do
    feed_id = subscription.feed_id

    place_path("source", to_string(feed_id), %{
      feed_id => MediaComponents.source_name(subscription)
    })
  end

  @doc """
  Returns the library path of one place: a status view, a source or a tag.

  Sidebar links and phone chips switch places instead of combining filters.
  So the path carries no other filter. A source or a tag opens on its inbox.
  """
  def place_path(key, value, feed_titles \\ %{})

  def place_path(key, value, feed_titles) when key in ["source", "tag"],
    do: library_path(%{key => value, "status" => "inbox"}, nil, feed_titles)

  def place_path(key, value, feed_titles), do: library_path(%{key => value}, nil, feed_titles)

  @doc """
  Returns whether `filters` show that place, which marks it as current.

  A source or a tag stays current under any status filter.
  """
  def place?(filters, "source", id), do: filters["source"] == id
  def place?(filters, "tag", id), do: filters["tag"] == id

  def place?(filters, "status", value),
    do:
      (filters["source"] || "") == "" and (filters["tag"] || "") == "" and
        (filters["status"] || "") == value

  # The window state lives in `socket.private`, because an assign change would trigger a render.
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

  # Counts depend on statuses only. The player saves progress every few seconds without a status
  # change, so `:playback_progressed` skips the refresh.
  defp refresh_for(socket, {:playback_progressed, _state}), do: socket
  defp refresh_for(socket, _message), do: refresh(socket)

  defp library_event?({:playback_progressed, _state}), do: true
  defp library_event?({:playback_changed, _state}), do: true
  defp library_event?({:subscription_removed, _feed_id}), do: true
  defp library_event?({:playback_marked, _count}), do: true
  defp library_event?({:tags_changed, _subscription_id}), do: true
  defp library_event?({:subscription_changed, _subscription_id}), do: true
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
