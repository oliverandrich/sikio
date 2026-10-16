# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.Sources do
  @moduledoc """
  Subscribes an account to a list of sources, for the OPML import and the library import.

  Sources are fetched five at a time in list order. Each is subscribed when its fetch arrives,
  so only a few fetched feeds are held at once. No host receives more than five concurrent
  requests from one call.
  """

  alias Sikio.Feeds.Discovery
  alias Sikio.Library
  alias Sikio.Library.Subscription
  alias Sikio.Tags

  @doc """
  Subscribes the account to each source in order and returns each source with its `status`.

  A source is a map with `:url` and optionally `:tags`, `:name`, `:delivery`, `:shorts` and
  `:paused`. `existing:` picks the present entries a new subscription receives, `:newest` by
  default, as `Library.subscribe/3` describes.

  `:imported` and `:existing` add the `subscription`. A source the account already follows,
  also under the feed's final address, gains the source's tags and keeps its settings.
  `:failed` adds the `reason`. A fetch that raises fails as `:unavailable`, and the other
  sources go on.
  """
  def subscribe(account, sources, opts \\ []) do
    existing = Keyword.get(opts, :existing, :newest)
    known = account |> Library.subscriptions() |> Map.new(&{&1.feed.url, &1})

    {results, _known} =
      sources
      |> fetched(known)
      |> Enum.map_reduce(known, fn {:ok, {source, result}}, known ->
        outcome = subscribe_one(account, source, known, result, existing)
        {Map.merge(source, outcome), remember(known, source, outcome)}
      end)

    results
  end

  @doc """
  Fetches each URL, five at a time, and returns `%{url => result}` as `Discovery.fetch/1` gives.
  A fetch that raises returns `{:error, :unavailable}`.
  """
  def fetch_all(urls) do
    urls
    |> Task.async_stream(&{&1, fetch(&1)}, max_concurrency: 5, timeout: :infinity)
    |> Map.new(fn {:ok, result} -> result end)
  end

  defp fetched(sources, known) do
    Task.async_stream(
      sources,
      fn source ->
        if Map.has_key?(known, source.url),
          do: {source, :known},
          else: {source, fetch(source.url)}
      end,
      max_concurrency: 5,
      timeout: :infinity
    )
  end

  # The task is linked to the caller, so a raise would end the whole import.
  defp fetch(url) do
    Discovery.fetch(url)
  rescue
    _exception -> {:error, :unavailable}
  end

  defp subscribe_one(account, source, known, result, existing) do
    case {known[source.url], result} do
      {%Subscription{} = subscription, _result} ->
        keep(account, subscription, source)

      {nil, {:ok, preview}} ->
        subscribe_new(account, source, preview, known, existing)

      {nil, {:error, reason}} ->
        %{status: :failed, reason: reason}

      {nil, _other} ->
        %{status: :failed, reason: :unavailable}
    end
  end

  # The source's address may lead to a feed the account follows under its final address.
  # Subscribing then returns that subscription, which keeps its settings.
  defp subscribe_new(account, source, preview, known, existing) do
    delivery = Map.get(source, :delivery, :inbox)

    case Library.subscribe(account, preview, existing: existing, delivery: delivery) do
      {:ok, subscription} ->
        if Enum.any?(Map.values(known), &(&1.id == subscription.id)),
          do: keep(account, subscription, source),
          else: configure(account, subscription, source)

      {:error, reason} ->
        %{status: :failed, reason: reason}
    end
  end

  defp keep(account, subscription, source) do
    tags = Map.get(source, :tags, [])
    if tags != [], do: Tags.add(account, subscription.id, tags)
    %{status: :existing, subscription: subscription}
  end

  defp configure(account, subscription, source) do
    settings = Map.take(source, [:name, :delivery, :shorts])
    tags = Map.get(source, :tags, [])

    with {:ok, _} <- Library.configure(account, subscription.id, settings, tags),
         {:ok, _} <- paused(account, subscription, Map.get(source, :paused, false)) do
      %{status: :imported, subscription: subscription}
    else
      _error -> %{status: :failed, reason: :invalid}
    end
  end

  defp paused(account, subscription, true), do: Library.pause(account, subscription.id, true)
  defp paused(_account, subscription, false), do: {:ok, subscription}

  # Both the source's URL and the feed's stored URL map to the subscription.
  # A list with an alias and the canonical URL subscribes the feed once.
  defp remember(known, source, %{subscription: subscription}),
    do: known |> Map.put(source.url, subscription) |> Map.put(subscription.feed.url, subscription)

  defp remember(known, _source, _failed), do: known
end
