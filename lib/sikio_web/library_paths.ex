# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryPaths do
  @moduledoc """
  The library's URL grammar: filters and an item to a path, and a path back to them.

  The library filters by status, source, tag, search and the history's day. A list's path names one place.
  Sources, tags and items carry a title slug after their id, and parsing reads only the id.
  """
  alias Sikio.Library
  alias Sikio.Preferences.Preference
  alias SikioWeb.MediaComponents

  # Maps status filters to URL segments. Within a source or tag the inbox has no segment.
  # No status filter is `all`. Older segments `new`, `in-progress` and `completed` still parse.
  @statuses %{"inbox" => "inbox", "queue" => "queue", "heard" => "history"}
  # Filters in the query string rather than the path.
  @query ["day", "q"]

  @status_segments Map.new(@statuses, fn {status, segment} -> {segment, status} end)
                   |> Map.merge(%{
                     "new" => "inbox",
                     "in-progress" => "queue",
                     "completed" => "heard"
                   })

  @doc """
  Returns the filters of an account's start page, which `/` opens.
  A start tag opens on its inbox, like a tag in the sidebar.
  """
  def start_filters(%{start_tag_id: tag}) when not is_nil(tag),
    do: %{"tag" => to_string(tag), "status" => "inbox"}

  def start_filters(%{start_view: view}), do: %{"status" => view}

  @doc """
  Returns the library URL: the list's path with the selected item appended.

  Sources, tags and items appear as their id followed by a title slug. Parsing reads only the id.
  `feed_titles` maps feed ids and `{:tag, id}` to titles. `item` is an entry, an id or nil.
  The history's day and the search text stay in the query string.

      /inbox  /queue  /history  /all
      /feeds/106-metacheles-tonspur  /feeds/106-metacheles-tonspur/all
      /inbox/4056-ki-verfassung  /feeds/106-metacheles-tonspur/4056-ki-verfassung

  Built by hand rather than with `~p`. The router declares every route shape.
  This module builds and parses the library URLs.
  """
  def library_path(filters, item \\ nil, feed_titles \\ %{}) do
    path = "/" <> Enum.join(place(filters, feed_titles) ++ item_segment(item), "/")

    case filters
         |> Map.take(@query)
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
  `/` reads into `start`, the filters of the account's start page.
  """
  def read_path(path, query, start \\ start_filters(%Preference{})) do
    {place, item} =
      case String.split(path, "/", trim: true) do
        [] ->
          {start, nil}

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

    {Library.normalize_filters(Map.merge(Map.take(query, @query), place)), item}
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
end
