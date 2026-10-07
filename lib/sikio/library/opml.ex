# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.OPML do
  @moduledoc """
  Imports and exports subscription lists as OPML, without credentials or playback history.

  An export contains sources and their tags only. Progress, paused polling and subscribers stay
  on this instance, because OPML files go to other applications.
  """
  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.OPML.Handler
  alias Sikio.Tags

  def parse(xml) when is_binary(xml) and byte_size(xml) > 1_000_000,
    do: {:error, :too_large}

  def parse(xml) when is_binary(xml) do
    if Parser.entity_free?(xml) do
      case Saxy.parse_string(xml, Handler, %{
             path: [],
             folders: [],
             sources: [],
             seen: MapSet.new(),
             nodes: 0,
             body?: false
           }) do
        {:ok, %{sources: [], body?: true}} -> {:error, :no_sources}
        {:ok, %{sources: sources, body?: true}} -> {:ok, Enum.reverse(sources)}
        {:ok, {:error, reason}} -> {:error, reason}
        _ -> {:error, :invalid_opml}
      end
    else
      {:error, :invalid_opml}
    end
  end

  def parse(_), do: {:error, :invalid_opml}

  # Saxy encodes the document, so titles with ampersands or quotes are escaped and round-trip.
  # Each tag becomes a folder outline. A subscription appears in every folder of its tags.
  # Untagged subscriptions sit at the top level.
  def export(account) do
    feeds = account |> Library.subscriptions() |> Map.new(&{&1.feed_id, &1.feed})
    tag_feeds = Tags.feeds(account)
    tagged = tag_feeds |> Map.values() |> List.flatten() |> MapSet.new()

    folders =
      for tag <- Tags.list(account), tag_feeds[tag.id] != [] do
        {"outline", [{"text", tag.name}, {"title", tag.name}],
         Enum.map(tag_feeds[tag.id], &outline(feeds[&1]))}
      end

    outlines =
      (feeds
       |> Map.values()
       |> Enum.reject(&MapSet.member?(tagged, &1.id))
       |> Enum.map(&outline/1)) ++
        folders

    Saxy.encode!(
      {"opml", [{"version", "2.0"}],
       [
         {"head", [], [{"title", [], ["Sikio subscriptions"]}]},
         {"body", [], outlines}
       ]},
      version: "1.0",
      encoding: "utf-8"
    )
  end

  defp outline(feed),
    do:
      {"outline",
       [{"type", "rss"}, {"text", feed.title}, {"title", feed.title}, {"xmlUrl", feed.url}], []}

  @doc """
  Subscribes to each source in order and returns one status per source.
  A source's tags are added to its new or existing subscription, keeping its current tags.

  An existing subscription is otherwise unchanged, including paused polling and progress.
  A failed fetch does not stop the remaining sources.
  """
  def import_sources(account, sources) when length(sources) <= 50 do
    known = account |> Library.subscriptions() |> Map.new(&{&1.feed.url, &1.id})

    {results, _} =
      sources
      |> fetched(known)
      |> Enum.map_reduce(known, fn {:ok, {source, fetched}}, known ->
        {result, known} =
          if Map.has_key?(known, source.url),
            do: {Map.put(source, :status, :existing), known},
            else: import_source(account, source, fetched, known)

        if id = known[source.url], do: Tags.add(account, id, Map.get(source, :tags, []))
        {result, known}
      end)

    results
  end

  # Fetches up to five sources concurrently. A slow server delays only its own source.
  # No host receives more than five concurrent requests from one import.
  # The ordered stream keeps the file's order and holds only a few fetched feeds in memory.
  defp fetched(sources, known) do
    Task.async_stream(
      sources,
      fn source ->
        if Map.has_key?(known, source.url),
          do: {source, :known},
          else: {source, Discovery.fetch(source.url)}
      end,
      max_concurrency: 5,
      timeout: :infinity
    )
  end

  # Both the URL from the file and the feed's stored URL map to the subscription.
  # A list with an alias and the canonical URL imports the feed once.
  defp import_source(account, source, fetched, known) do
    with {:ok, preview} <- fetched,
         {:ok, subscription} <- Library.subscribe(account, preview) do
      status = if subscription.id in Map.values(known), do: :existing, else: :imported
      result = Map.put(source, :status, status)

      {result,
       known
       |> Map.put(source.url, subscription.id)
       |> Map.put(subscription.feed.url, subscription.id)}
    else
      {:error, reason} -> {Map.merge(source, %{status: :failed, reason: reason}), known}
      _ -> {Map.merge(source, %{status: :failed, reason: :unavailable}), known}
    end
  end
end
