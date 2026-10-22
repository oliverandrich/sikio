# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ApiController do
  @moduledoc """
  The browser extension's API v1. `SikioWeb.ExtensionAuth` has assigned the account.

  The extension detects pages locally and matches them against `subscriptions`. It calls
  `lookup` only for a page it detected, and adds with `subscribe` and `add`. Lookup and adding
  resolve the page with `Sikio.Feeds.Discovery`, as `/add` does. Errors are
  `{"error": code}`; docs/api.md lists them.
  """
  use SikioWeb, :controller

  alias Sikio.Feeds.Discovery
  alias Sikio.Feeds.Feed
  alias Sikio.Library

  # Discovery fetches pages and feeds; a lookup waits no longer than `/add` would.
  @timeout 30_000

  def subscriptions(conn, _params) do
    sources =
      for subscription <- Library.subscriptions(conn.assigns.current_account) do
        identifiers(subscription.feed)
      end

    json(conn, %{subscriptions: sources})
  end

  def lookup(conn, %{"url" => url}) when is_binary(url) do
    account = conn.assigns.current_account
    # Both run against one deadline, so a slow page holds the request no longer than `/add`.
    [sources, item] =
      [fn -> Discovery.discover(url) end, fn -> Discovery.item(url) end]
      |> Enum.map(fn fun -> Task.async(fn -> resolved(fun) end) end)
      |> Task.yield_many(timeout: @timeout, on_timeout: :kill_task)
      |> Enum.map(fn {_task, result} -> result end)

    feeds =
      case sources do
        {:ok, {:ok, feeds}} -> feeds
        _failed -> []
      end

    subscribed = Library.subscribed_urls(account, Enum.map(feeds, & &1.url))

    item =
      case item do
        {:ok, {:ok, found}} -> item(account, found)
        _failed -> nil
      end

    json(conn, %{sources: Enum.map(feeds, &source(&1, subscribed)), item: item})
  end

  def lookup(conn, _params), do: error(conn, 400, "invalid_request")

  # A page that cannot be read offers nothing. A raise or a timeout must not fail the request.
  defp resolved(fun) do
    fun.()
  rescue
    _error -> {:error, :failed}
  end

  # Only the feed the extension chose is subscribed, never another one the page offers.
  def subscribe(conn, %{"feed_url" => url}) when is_binary(url) do
    account = conn.assigns.current_account

    case offered(url) do
      nil ->
        error(conn, 404, "not_found")

      feed ->
        existed? = MapSet.member?(Library.subscribed_urls(account, [url]), url)
        account |> Library.subscribe(feed) |> subscribed(conn, existed?)
    end
  end

  def subscribe(conn, _params), do: error(conn, 400, "invalid_request")

  defp offered(url) do
    case Discovery.discover(url) do
      {:ok, feeds} -> Enum.find(feeds, &(&1.url == url))
      {:error, _reason} -> nil
    end
  end

  defp subscribed({:ok, subscription}, conn, existed?) do
    conn
    |> put_status(if existed?, do: 200, else: 201)
    |> json(%{subscription: identifiers(subscription.feed)})
  end

  defp subscribed({:error, reason}, conn, _existed?), do: failed(conn, reason)

  def add(conn, %{"url" => url, "at" => at}) when is_binary(url) and at in ["inbox", "queue"] do
    account = conn.assigns.current_account

    case Discovery.item(url) do
      {:ok, %{preview: preview, external_id: id}} ->
        case Library.save(account, preview, id, String.to_existing_atom(at)) do
          {:ok, entry} -> saved(conn, entry, Library.place(account, preview.url, id))
          {:error, reason} -> failed(conn, reason)
        end

      {:error, _reason} ->
        error(conn, 404, "not_found")
    end
  end

  def add(conn, _params), do: error(conn, 400, "invalid_request")

  # The identifiers the extension matches a page against. A YouTube feed names its channel.
  defp identifiers(feed) do
    %{
      feed_url: feed.url,
      kind: feed.kind,
      title: feed.title,
      page_url: feed.page_url,
      channel_id: Feed.channel_id(feed)
    }
  end

  defp source(feed, subscribed) do
    %{
      feed_url: feed.url,
      kind: feed.kind,
      title: feed.title,
      icon_url: feed.icon_url,
      subscribed: MapSet.member?(subscribed, feed.url)
    }
  end

  defp item(account, %{preview: preview, external_id: id}) do
    entry = Enum.find(preview.entries, &(&1.external_id == id))

    %{
      title: entry && entry.title,
      source: preview.title,
      place: Library.place(account, preview.url, id)
    }
  end

  defp saved(conn, entry, place),
    do: conn |> put_status(201) |> json(%{item: %{title: entry.title, place: place}})

  defp failed(conn, :platform_off), do: error(conn, 403, "platform_off")
  defp failed(conn, :not_found), do: error(conn, 404, "not_found")
  defp failed(conn, _reason), do: error(conn, 500, "server_error")

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
